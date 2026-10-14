// ===========================
// DOSMAN UJIAN - Kiosk Controller
// Mengatur kunci aplikasi dari login sampai keluar
// ===========================

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Respons [fetchExitPassword]. Hanya saat [success] == true nilai [password]
/// boleh diartikan sebagai kebijakan server (kosong = admin tidak memakai password).
class ExitPasswordFetchResult {
  final bool success;
  final String password;

  const ExitPasswordFetchResult({
    required this.success,
    this.password = '',
  });
}

class KioskController {
  static final KioskController instance = KioskController._();
  KioskController._();

  static const _channel = MethodChannel(AppConfig.lockdownChannel);

  GlobalKey<NavigatorState>? _rootNavigatorKey;
  Future<void> Function()? _onUnpinPasswordRequest;
  bool _unpinFlowBusy = false;

  /// Navigator root (MaterialApp) — dipakai dialog lepas semat dari native.
  GlobalKey<NavigatorState>? get rootNavigatorKey => _rootNavigatorKey;

  /// Wajib dipanggil sekali dari [DosmanUjianApp] agar native bisa memicu dialog password.
  void initKioskBridge({
    required GlobalKey<NavigatorState> rootNavigatorKey,
    required Future<void> Function() onUnpinPasswordRequest,
  }) {
    _rootNavigatorKey = rootNavigatorKey;
    _onUnpinPasswordRequest = onUnpinPasswordRequest;
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'requestUnpinPassword':
        if (_unpinFlowBusy) return null;
        _unpinFlowBusy = true;
        try {
          await _onUnpinPasswordRequest?.call();
        } finally {
          _unpinFlowBusy = false;
        }
      case 'onLockTaskLost':
        _notifyViolation('lock_task_lost');
      case 'onSplitScreenDetected':
        _notifyViolation('split_screen');
      case 'onOverlayDetected':
        _notifyViolation('overlay');
      case 'onScreenCastDetected':
        _notifyViolation('screen_cast');
      case 'onScreenshotDetected':
        _notifyViolation('screenshot_attempt');
    }
    return null;
  }

  // ─── Violation listeners (split-screen, dll.) ─────────────────────────────

  final List<void Function(String reason)> _violationListeners = [];

  /// Daftarkan callback yang dipanggil saat native mendeteksi pelanggaran.
  void addViolationListener(void Function(String reason) cb) =>
      _violationListeners.add(cb);

  void removeViolationListener(void Function(String reason) cb) =>
      _violationListeners.remove(cb);

  void _notifyViolation(String reason) {
    for (final cb in List.of(_violationListeners)) {
      cb(reason);
    }
  }

  /// Jawaban native setelah dialog lepas semat selesai (pin ulang vs lepas kiosk).
  Future<void> ackUnpinPassword({required bool ok}) async {
    try {
      await _channel.invokeMethod('unpinPasswordAck', {'ok': ok});
    } catch (_) {}
  }

  bool _active     = false;
  bool _inExamMode = false;

  bool get active     => _active;
  bool get inExamMode => _inExamMode;

  /// Waktu login (lock dipanggil). Dipakai untuk grace period 10 menit
  /// agar siswa tidak tersuspend akibat notif/dialog sistem saat baru masuk.
  DateTime? _sessionStartedAt;

  /// True jika masih dalam 10 menit pertama sejak login.
  bool get isInGracePeriod {
    if (_sessionStartedAt == null) return false;
    return DateTime.now().difference(_sessionStartedAt!).inMinutes < 10;
  }

  final List<void Function()> _listeners = [];

  void addListener(void Function() cb)    => _listeners.add(cb);
  void removeListener(void Function() cb) => _listeners.remove(cb);

  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// True jika screen pin / lock task Android atau Guided Access iOS aktif.
  Future<bool> isLockTaskPinned() async {
    try {
      final res = await _channel.invokeMethod<bool>('isLockTaskActive');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Khusus iOS: Cek apakah fitur Akses Terpandu (Guided Access) sedang aktif.
  Future<bool> isGuidedAccessActive() async {
    try {
      final res = await _channel.invokeMethod<bool>('isGuidedAccessActive');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Panggil native agar siswa melihat dialog Sematkan / Pin lagi (hanya saat kiosk aktif).
  Future<void> requestScreenPinAgain() async {
    try {
      await _channel.invokeMethod('requestScreenPin');
    } catch (_) {}
  }

  /// Aktifkan kunci penuh — dipanggil tepat setelah login berhasil.
  Future<void> lock() async {
    try { await _channel.invokeMethod('enableLockdown'); }   catch (_) {}
    try { await _channel.invokeMethod('enterLockTask'); }    catch (_) {}
    try { await _channel.invokeMethod('lockBackButton'); }   catch (_) {}
    try { await _channel.invokeMethod('keepScreenOn'); }     catch (_) {}
    _active           = true;
    _inExamMode       = false;
    _sessionStartedAt = DateTime.now(); // mulai hitung grace period 10 menit
    _notify();
  }

  /// Lepas semua kunci — dipanggil saat keluar aplikasi dengan password.
  Future<void> unlock() async {
    try { await _channel.invokeMethod('exitLockTask'); }      catch (_) {}
    try { await _channel.invokeMethod('disableLockdown'); }   catch (_) {}
    try { await _channel.invokeMethod('unlockBackButton'); }  catch (_) {}
    try { await _channel.invokeMethod('clearScreenOn'); }     catch (_) {}
    _active           = false;
    _inExamMode       = false;
    _sessionStartedAt = null;
    _notify();
  }

  /// Tandai sedang di dalam ExamScreen — sembunyikan tombol Keluar overlay.
  void enterExam() {
    _inExamMode = true;
    _notify();
  }

  /// Kembali dari ExamScreen — tampilkan kembali tombol Keluar overlay.
  void exitExam() {
    _inExamMode = false;
    _notify();
  }

  /// Cek apakah koneksi VPN aktif saat ini.
  /// Return true = VPN aktif. Null = platform tidak support / error.
  Future<bool?> checkVpn() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkVpn');
      return res ?? false;
    } catch (_) {
      return null;
    }
  }

  /// Cek apakah perangkat kemungkinan di-root.
  /// [isRooted] true jika salah satu sinyal (su binary, test-keys, root app) positif.
  /// Null = platform tidak support / error.
  Future<({bool isRooted, bool suBinaryFound, bool testKeys, bool rootAppFound})?> checkRootStatus() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('checkRootStatus');
      if (res == null) return null;
      return (
        isRooted:      res['isRooted']      as bool? ?? false,
        suBinaryFound: res['suBinaryFound'] as bool? ?? false,
        testKeys:      res['testKeys']      as bool? ?? false,
        rootAppFound:  res['rootAppFound']  as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// Cek apakah ada display tambahan yang aktif (screen cast / Chromecast / mirroring).
  /// Return true = casting aktif. Null = platform tidak support / error.
  Future<bool?> checkScreenCast() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkScreenCast');
      return res ?? false;
    } catch (_) {
      return null;
    }
  }

  /// Kembalikan daftar nama accessibility service pihak ketiga yang aktif.
  /// List kosong = aman. Null = platform tidak support / error.
  Future<List<String>?> checkAccessibilityServices() async {
    try {
      final res = await _channel.invokeListMethod<String>('checkAccessibilityServices');
      return res ?? [];
    } catch (_) {
      return null;
    }
  }

  /// Cek apakah USB Debugging atau Developer Mode aktif di perangkat.
  /// Return null jika platform tidak support (iOS / error).
  Future<({bool usbDebugging, bool developerMode})?> checkDeviceSecurityFlags() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('checkSecurityFlags');
      if (res == null) return null;
      return (
        usbDebugging:  res['usbDebugging']  as bool? ?? false,
        developerMode: res['developerMode'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// Cek apakah izin Do Not Disturb (Notification Policy Access) sudah diberikan.
  /// Return false jika belum — UI harus meminta siswa memberikan izin sebelum ujian.
  /// Non-Android selalu mengembalikan true (tidak relevan).
  Future<bool> isDndPermissionGranted() async {
    try {
      final res = await _channel.invokeMethod<bool>('isDndPermissionGranted');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Buka halaman pengaturan DND agar siswa/admin bisa memberikan izin.
  /// Return true jika berhasil membuka Settings, false jika semua intent gagal.
  Future<bool> openDndSettings() async {
    try {
      final res = await _channel.invokeMethod<bool>('openDndSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ambil password keluar dari endpoint Moodle (API key statis).
  ///
  /// Jika [success] false, jangan anggap password kosong — berarti gagal fetch
  /// (jaringan, 401, 500, body bukan JSON). UI wajib menolak keluar tanpa
  /// verifikasi atau menampilkan dialog setelah retry.
  Future<ExitPasswordFetchResult> fetchExitPassword() async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/exitpwd.php?apikey=${Uri.encodeComponent(AppConfig.exitPwdApiKey)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return const ExitPasswordFetchResult(success: false);
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const ExitPasswordFetchResult(success: false);
      }
      final p = decoded['password'];
      if (p is! String) {
        return const ExitPasswordFetchResult(success: false);
      }
      return ExitPasswordFetchResult(success: true, password: p);
    } catch (_) {
      return const ExitPasswordFetchResult(success: false);
    }
  }
}
