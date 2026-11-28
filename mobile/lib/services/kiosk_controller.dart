// ===========================
// DOSMAN UJIAN - Kiosk Controller
// Mengatur kunci aplikasi dari login sampai keluar (Single Source of Truth)
// ===========================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'auth_service.dart';
import 'exam_service.dart';
import '../screens/blocked_screen.dart';

typedef SuspendAccountHandler = Future<SuspendAccountOutcome> Function({
  required int userId,
  required String reason,
});

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

  static const Set<String> _reviewerUsernames = {
    'playstore.review',
    'appstore.review',
    'admin.reviewer',
    'apple.review',
  };

  GlobalKey<NavigatorState>? _rootNavigatorKey;

  /// Navigator root (MaterialApp) — dipakai saat menavigasikan ke BlockedScreen.
  GlobalKey<NavigatorState>? get rootNavigatorKey => _rootNavigatorKey;

  /// Wajib dipanggil sekali dari [DosmanUjianApp] agar native event terhubung ke Flutter.
  void initKioskBridge({
    required GlobalKey<NavigatorState> rootNavigatorKey,
  }) {
    _rootNavigatorKey = rootNavigatorKey;
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'onLockTaskLost':
        await handleFatalViolation(
          reason: 'Siswa memaksa melepas pinned screen (alarm aktif)',
          uiMessage:
              'Akun Anda ditangguhkan karena Anda melepas kuncian layar saat ujian berlangsung. Harap segera melapor ke pengawas ujian.',
        );
      case 'onSplitScreenDetected':
        await handleFatalViolation(
          reason: 'Pelanggaran keamanan ujian: split_screen',
          uiMessage:
              'Akun Anda ditangguhkan karena terdeteksi split-screen / jendela mengambang saat ujian berlangsung.',
        );
      case 'onVirtualEnvironmentDetected':
        final args = call.arguments;
        final detail = (args is Map && args['detail'] != null) ? ' [${args['detail']}]' : '';
        await handleFatalViolation(
          reason: 'Pelanggaran keamanan ujian: virtual_environment$detail',
          uiMessage:
              'Akun Anda ditangguhkan karena aplikasi terdeteksi berjalan di Virtual Machine / Emulator.',
        );
      case 'onClonedAppDetected':
        await handleFatalViolation(
          reason: 'Pelanggaran keamanan ujian: cloned_app',
          uiMessage:
              'Akun Anda ditangguhkan karena aplikasi terdeteksi berjalan di Ruang Ganda / Aplikasi Kloning.',
        );
      case 'onBluetoothAudioConnected':
        await handleFatalViolation(
          reason: 'Pelanggaran keamanan ujian: bluetooth_audio',
          uiMessage:
              'Akun Anda ditangguhkan karena perangkat terhubung ke audio Bluetooth saat ujian berlangsung.',
        );
      case 'onScreenshotDetected':
        _notifyViolation('screenshot_attempt');
      case 'onOverlayDetected':
      case 'onScreenCastDetected':
        // Dinonaktifkan dari kebijakan 4 aturan resmi (banyak false-positive OEM/APK lama)
        break;
    }
    return null;
  }

  bool _isReviewer = false;
  bool get isReviewer => _isReviewer;

  /// Helper terpusat untuk mendeteksi apakah username merupakan akun uji coba / reviewer resmi.
  static bool isReviewerUsername(String? username) {
    if (username == null) return false;
    return _reviewerUsernames.contains(username.toLowerCase().trim());
  }

  final List<void Function(String reason)> _violationListeners = [];

  /// Daftarkan callback yang dipanggil saat native/kiosk memicu pelanggaran.
  void addViolationListener(void Function(String reason) cb) =>
      _violationListeners.add(cb);

  void removeViolationListener(void Function(String reason) cb) =>
      _violationListeners.remove(cb);

  void _notifyViolation(String reason) {
    if (_isReviewer) return;
    for (final cb in List.of(_violationListeners)) {
      cb(reason);
    }
  }

  bool _active = false;
  bool _inExamMode = false;
  bool _allowUnpinnedForSubmit = false;
  bool _handlingFatalViolation = false;
  DateTime? _sessionStartedAt;
  DateTime? _lockedAt;
  SuspendAccountHandler? _suspendHandlerOverride;

  bool get active => _active;
  bool get inExamMode => _inExamMode;
  bool get allowUnpinnedForSubmit => _allowUnpinnedForSubmit;
  bool get isHandlingFatalViolation => _handlingFatalViolation;

  /// Izinkan aplikasi dilepas pinnya sementara khusus saat menunggu pengiriman
  /// jawaban ujian yang sudah dikunci (soal sudah dihapus).
  void setAllowUnpinnedForSubmit(bool allow) {
    if (_allowUnpinnedForSubmit == allow) return;
    _allowUnpinnedForSubmit = allow;
    _notify();
  }

  /// Atur handler suspend tiruan khusus untuk unit test deterministik.
  @visibleForTesting
  void setSuspendHandlerForTesting(SuspendAccountHandler? handler) {
    _suspendHandlerOverride = handler;
  }

  /// True jika masih dalam 15 detik pertama sejak kiosk diaktifkan.
  bool get isInGracePeriod {
    if (_sessionStartedAt == null) return false;
    return DateTime.now().difference(_sessionStartedAt!).inSeconds < 15;
  }

  /// True selama 3 detik pertama sesudah lock() dipanggil agar dialog sistem "App pinned"
  /// sempat muncul sebelum PinReminderLayer menampilkan banner pemblokir.
  bool get isInPinStartupGrace {
    if (_lockedAt == null) return false;
    return DateTime.now().difference(_lockedAt!).inSeconds < 3;
  }

  final List<void Function()> _listeners = [];

  void addListener(void Function() cb) => _listeners.add(cb);
  void removeListener(void Function() cb) => _listeners.remove(cb);

  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// Reset seluruh state singleton khusus untuk unit test.
  @visibleForTesting
  void resetForTesting() {
    _active = false;
    _inExamMode = false;
    _allowUnpinnedForSubmit = false;
    _isReviewer = false;
    _handlingFatalViolation = false;
    _sessionStartedAt = null;
    _lockedAt = null;
    _rootNavigatorKey = null;
    _suspendHandlerOverride = null;
    _listeners.clear();
    _violationListeners.clear();
  }

  /// Lewatkan masa startup grace 3 detik khusus untuk widget test deterministik.
  @visibleForTesting
  void expirePinStartupGraceForTesting() {
    _lockedAt = DateTime.now().subtract(const Duration(seconds: 5));
  }

  /// True jika screen pin / lock task Android atau Guided Access iOS aktif.
  Future<bool> isLockTaskPinned() async {
    if (_isReviewer) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isLockTaskActive');
      return res ?? false;
    } catch (_) {
      return defaultTargetPlatform != TargetPlatform.android;
    }
  }

  /// Khusus iOS: Cek apakah fitur Akses Terpandu (Guided Access) aktif.
  Future<bool> isGuidedAccessActive() async {
    if (_isReviewer) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isGuidedAccessActive');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Cek apakah Screen Pinning diaktifkan di Pengaturan Android.
  Future<bool> isScreenPinningEnabled() async {
    try {
      final res = await _channel.invokeMethod<bool>('isScreenPinningEnabled');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Buka halaman Pengaturan Semat Layar (Screen Pinning) Android.
  Future<bool> openScreenPinningSettings() async {
    try {
      final res = await _channel.invokeMethod<bool>('openScreenPinningSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Cek apakah ada perangkat audio Bluetooth (TWS / Headset) yang tersambung.
  Future<bool> checkBluetoothAudio() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkBluetoothAudio');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Panggil native agar siswa melihat dialog Sematkan / Pin lagi (hanya saat kiosk aktif).
  Future<bool> requestScreenPinAgain() async {
    try {
      final res = await _channel.invokeMethod<bool>('requestScreenPin');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Buka panel pengaturan Wi-Fi perangkat.
  /// Jika [releaseLockTask] true, hanya diizinkan saat [_inExamMode] == false
  /// (misalnya di layar "Menunggu Sinyal" setelah jawaban dikunci & soal dihapus).
  Future<bool> openWifiSettings({bool releaseLockTask = false}) async {
    if (releaseLockTask && _inExamMode) return false;
    try {
      final res = await _channel.invokeMethod<bool>(
        'openWifiSettings',
        {'releaseLockTask': releaseLockTask},
      );
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Pintu tunggal penanganan pelanggaran fatal selama ujian aktif.
  /// Mencegah double/triple suspend akibat race kondisi native + Flutter listener.
  Future<bool> handleFatalViolation({
    required String reason,
    String? uiMessage,
    int? userId,
  }) async {
    if (_isReviewer || _handlingFatalViolation || !_inExamMode) return false;
    final username = (await AuthService.getUsername()).toLowerCase().trim();
    if (isReviewerUsername(username)) {
      _isReviewer = true;
      return false;
    }
    _handlingFatalViolation = true;

    final effectiveUid = (userId != null && userId > 0)
        ? userId
        : await AuthService.getUserId();

    var outcome = SuspendAccountOutcome.suspended;
    if (effectiveUid > 0) {
      try {
        final handler =
            _suspendHandlerOverride ?? ExamService.suspendStudentWithOutcome;
        outcome = await handler(
          userId: effectiveUid,
          reason: reason,
        );
      } catch (_) {
        outcome = SuspendAccountOutcome.networkOrServerError;
      }

      if (outcome == SuspendAccountOutcome.ignoredByServer) {
        _handlingFatalViolation = false;
        await ExamService.clearPendingSuspend();
        return false;
      }

      if (outcome == SuspendAccountOutcome.suspended) {
        await ExamService.clearPendingSuspend();
      } else {
        await ExamService.savePendingSuspend(effectiveUid);
      }
    }

    _notifyViolation(reason);
    await AuthService.saveBlockedStatus(true);
    await AuthService.saveSuspendedByAdmin(true);
    await unlock(preserveAlarm: true);

    final navState = _rootNavigatorKey?.currentState;
    if (navState != null && navState.mounted) {
      navState.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => BlockedScreen(
            userId: effectiveUid,
            reason: uiMessage ??
                'Akun Anda ditangguhkan karena pelanggaran keamanan saat ujian berlangsung. Harap segera melapor ke pengawas ujian.',
          ),
        ),
        (route) => false,
      );
    }
    return true;
  }

  /// Daftarkan userId siswa ke native layer agar tersimpan saat terjadi pelanggaran mendadak.
  Future<void> setUserId(int userId) async {
    try {
      await _channel.invokeMethod('setUserId', {'userId': userId});
    } catch (_) {}
  }

  /// Beritahu native apakah pengguna saat ini adalah akun reviewer.
  Future<void> setReviewerMode(bool isReviewer) async {
    _isReviewer = isReviewer;
    try {
      await _channel.invokeMethod('setReviewerMode', {'isReviewer': isReviewer});
    } catch (_) {}
  }

  /// Cek apakah aplikasi berjalan di Virtual Machine (VMOS, VPhone, dll.)
  Future<bool> checkVirtualEnvironment() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkVirtualEnvironment');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Detail sinyal deteksi VM (merek/model HP + kode sinyal) untuk ditampilkan
  /// ke siswa/pengawas agar false-positive bisa dilaporkan & dianalisis.
  Future<String> getVirtualEnvironmentDetail() async {
    try {
      final res = await _channel.invokeMethod<Map>('getVirtualEnvironmentDetail');
      return (res?['detail'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Cek apakah aplikasi berjalan di Ruang Ganda / Kloning (Dual App, Parallel Space, dll.)
  Future<bool> checkClonedApp() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkClonedApp');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Cek apakah tampilan saat ini dalam split-screen atau floating window
  Future<bool> isSplitScreenActive() async {
    try {
      final res = await _channel.invokeMethod<bool>('isSplitScreenActive');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Aktifkan kunci penuh (idempoten — aman dipanggil berulang tanpa mereset state ujian).
  Future<void> lock({int? userId}) async {
    try {
      final username = (await AuthService.getUsername()).toLowerCase().trim();
      final reviewer = isReviewerUsername(username);
      await setReviewerMode(reviewer);
    } catch (_) {}

    if (_active) {
      if (userId != null && userId > 0) {
        await setUserId(userId);
      }
      try { await _channel.invokeMethod('keepScreenOn'); } catch (_) {}
      return;
    }

    try { await _channel.invokeMethod('enableLockdown'); } catch (_) {}
    try {
      final effectiveId = (userId != null && userId > 0) ? userId : await AuthService.getUserId();
      await _channel.invokeMethod('enterLockTask', {'userId': effectiveId});
    } catch (_) {}
    try { await _channel.invokeMethod('lockBackButton'); } catch (_) {}
    try { await _channel.invokeMethod('keepScreenOn'); } catch (_) {}

    _active = true;
    _inExamMode = false;
    _handlingFatalViolation = false;
    _sessionStartedAt = DateTime.now(); // mulai hitung grace period 15 detik
    _lockedAt = _sessionStartedAt;
    _notify();
  }

  /// Pastikan kiosk aktif lalu tandai mode ujian aktif secara atomik.
  Future<void> ensureLockedAndEnterExam({required int userId}) async {
    await lock(userId: userId);
    enterExam();
  }

  /// Lepas semua kunci — dipanggil saat keluar aplikasi atau saat suspend.
  /// Saat dipanggil dari [handleFatalViolation], [preserveAlarm] true agar
  /// suara alarm 10x (~10 detik) tidak langsung terpotong oleh `exitLockTask`.
  Future<void> unlock({bool preserveAlarm = false}) async {
    try { await _channel.invokeMethod('setExamMode', {'active': false}); } catch (_) {}
    try { await _channel.invokeMethod('exitLockTask', {'preserveAlarm': preserveAlarm}); } catch (_) {}
    try { await _channel.invokeMethod('disableLockdown'); } catch (_) {}
    try { await _channel.invokeMethod('unlockBackButton'); } catch (_) {}
    try { await _channel.invokeMethod('clearScreenOn'); } catch (_) {}
    _active = false;
    _inExamMode = false;
    _allowUnpinnedForSubmit = false;
    _handlingFatalViolation = false;
    _sessionStartedAt = null;
    _lockedAt = null;
    _notify();
  }

  /// Tandai sedang di dalam layar kuis aktif.
  void enterExam() {
    _inExamMode = true;
    _allowUnpinnedForSubmit = false;
    _handlingFatalViolation = false;
    _channel.invokeMethod('setExamMode', {'active': true}).catchError((_) {});
    _channel.invokeMethod('keepScreenOn').catchError((_) {});
    _notify();
  }

  /// Kembali dari layar kuis aktif.
  void exitExam() {
    _inExamMode = false;
    _channel.invokeMethod('setExamMode', {'active': false}).catchError((_) {});
    _notify();
  }

  /// Cek apakah koneksi VPN aktif saat ini.
  Future<bool?> checkVpn() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkVpn');
      return res ?? false;
    } catch (_) {
      return null;
    }
  }

  /// Cek apakah perangkat kemungkinan di-root.
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
  Future<bool?> checkScreenCast() async {
    try {
      final res = await _channel.invokeMethod<bool>('checkScreenCast');
      return res ?? false;
    } catch (_) {
      return null;
    }
  }

  /// Kembalikan daftar nama accessibility service pihak ketiga yang aktif.
  Future<List<String>?> checkAccessibilityServices() async {
    try {
      final res = await _channel.invokeListMethod<String>('checkAccessibilityServices');
      return res ?? [];
    } catch (_) {
      return null;
    }
  }

  /// Cek apakah USB Debugging atau Developer Mode aktif di perangkat.
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
  Future<bool> isDndPermissionGranted() async {
    try {
      final res = await _channel.invokeMethod<bool>('isDndPermissionGranted');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Buka halaman pengaturan DND agar siswa/admin bisa memberikan izin.
  Future<bool> openDndSettings() async {
    try {
      final res = await _channel.invokeMethod<bool>('openDndSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ambil password keluar dari endpoint Moodle (API key statis).
  /// Jika gagal terhubung ke server (mis. Wi-Fi terputus), gunakan cache aman lokal jika ada.
  ///
  /// Jika [success] false (belum ada cache & gagal fetch), jangan anggap password kosong —
  /// tetap tolak demi keamanan.
  Future<ExitPasswordFetchResult> fetchExitPassword() async {
    try {
      final username = (await AuthService.getUsername()).toLowerCase().trim();
      final reviewer = _isReviewer || isReviewerUsername(username);
      if (reviewer) {
        return const ExitPasswordFetchResult(success: true, password: '123456');
      }

      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/exitpwd.php?apikey=${Uri.encodeComponent(AppConfig.exitPwdApiKey)}&username=${Uri.encodeComponent(username)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) {
          final p = decoded['password'];
          if (p is String) {
            await AuthService.saveCachedExitPassword(p);
            return ExitPasswordFetchResult(success: true, password: p);
          }
        }
      }
    } catch (_) {
      // Fallback ke cache lokal di bawah bila tersedia.
    }

    final cached = await AuthService.getCachedExitPassword();
    if (cached != null && cached.isNotEmpty) {
      return ExitPasswordFetchResult(success: true, password: cached);
    }
    return const ExitPasswordFetchResult(success: false);
  }
}
