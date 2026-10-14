// ===========================
// DOSMAN UJIAN - Exam Screen
// Lockdown WebView untuk ujian siswa
// ===========================

import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../config/app_config.dart';
import '../models/quiz.dart';
import '../models/session.dart';
import '../screens/blocked_screen.dart';
import '../services/api_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';
import '../services/auth_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ─── Enum state layar ujian ──────────────────────────────────────────────────

enum ExamState {
  loading,    // sedang registrasi sesi + load WebView
  active,     // ujian berjalan normal
  paused,     // dijeda oleh guru
  blocked,    // diblokir (pelanggaran / force close)
  completed,  // ujian selesai
  error,      // error tak terduga
}

// ─── ExamScreen ──────────────────────────────────────────────────────────────

class ExamScreen extends StatefulWidget {
  final Quiz   quiz;
  final int    courseId;
  final int    userId;
  final String username;
  final String password;

  const ExamScreen({
    super.key,
    required this.quiz,
    required this.courseId,
    required this.userId,
    required this.username,
    required this.password,
  });

  // ─── Pending suspend persistence (offline recovery) ──────────────────────
  static const _kPendingSuspendKey = 'dosman_pending_suspend_userid';
  static const _storage = FlutterSecureStorage();

  static Future<void> _savePendingSuspend(int userId) async {
    await _storage.write(key: _kPendingSuspendKey, value: userId.toString());
  }

  static Future<void> clearPendingSuspend() async {
    await _storage.delete(key: _kPendingSuspendKey);
  }

  static Future<void> flushPendingSuspend() async {
    final val = await _storage.read(key: _kPendingSuspendKey);
    if (val == null) return;
    final uid = int.tryParse(val) ?? 0;
    if (uid <= 0) { await _storage.delete(key: _kPendingSuspendKey); return; }
    final ok = await ExamService.suspendStudent(userId: uid);
    if (ok) await _storage.delete(key: _kPendingSuspendKey);
  }

  @override
  State<ExamScreen> createState() => _ExamScreenState();
}

class _ExamScreenState extends State<ExamScreen> with WidgetsBindingObserver {

  // ─── State ────────────────────────────────────────────────────────────────

  ExamState _examState    = ExamState.loading;
  String    _statusMessage = '';
  int       _sessionId    = 0;
  bool      _examStartLogged = false;

  // WebView state machine
  // 'init' -> 'login' -> 'quiz' -> 'done'
  String _webPhase = 'init';

  // ─── WebView ─────────────────────────────────────────────────────────────

  InAppWebViewController? _webCtrl;
  final _webKey = GlobalKey();

  // ─── Timer ────────────────────────────────────────────────────────────────

  Timer? _heartbeatTimer;

  /// Timer background 45 detik: jika app tidak kembali, suspend akun langsung.
  Timer? _blockTimer;

  /// True jika suspendStudent() sudah dipanggil (timer sempat tembak).
  bool _serverBlockSent = false;

  /// Waktu app terakhir masuk background saat ujian aktif.
  DateTime? _backgroundedAt;

  /// Jumlah heartbeat gagal berturut-turut (network error). Setelah 3x, paksa cek status.
  int _consecutiveHeartbeatErrors = 0;

  /// Timer bersih clipboard — hapus setiap 60 detik selama ujian aktif.
  Timer? _clipboardClearTimer;

  /// True jika [startLockTask] Android berhasil (screen pinning).
  bool _androidLockTaskActive = false;

  /// True jika native [enterLockTask] sudah jalan (immersive + upaya pinning) — wajib [exitLockTask].
  bool _androidExamKioskNative = false;

  /// True jika lockBackButton native sudah dipanggil — wajib unlockBackButton saat keluar.
  bool _backButtonLocked = false;

  /// Agar tidak spam log bila `enterLockTask` ditolak perangkat.
  bool _lockTaskFailureLogged = false;

  /// Mode layar penuh (immersive) aktif saat sedang mengerjakan soal (iOS / non-Android).
  bool _immersiveUiActive = false;

  /// Pesan khusus bila perangkat menolak Lock Task / Screen Pinning.
  String _kioskHint = '';

  /// Jika app sempat ke background saat sesi ujian berlangsung, perlakukan sebagai pelanggaran fatal.
  bool _backgroundedDuringActiveExam = false;

  /// Jumlah percobaan auto-login WebView. Jika > 1 berarti credentials ditolak Moodle.
  int _webLoginAttempts = 0;

  /// Waktu saat enterLockTask dipanggil. Digunakan untuk grace period 30 detik
  /// agar siswa tidak tersuspend hanya karena lambat menyetujui dialog "App pinned".
  DateTime? _kioskActivatingAt;

  // ─── MethodChannel untuk FLAG_SECURE + Lock Task (Android) ─────────────────

  static const _lockdownChannel = MethodChannel(AppConfig.lockdownChannel);

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    KioskController.instance.enterExam();
    KioskController.instance.addViolationListener(_onNativeViolation);
    _clearClipboard();
    _clipboardClearTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _clearClipboard(),
    );
    _enableLockdown();
    _registerAndStart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KioskController.instance.removeViolationListener(_onNativeViolation);
    _heartbeatTimer?.cancel();
    _blockTimer?.cancel();
    _clipboardClearTimer?.cancel();
    _exitExamKioskMode();
    KioskController.instance.exitExam();
    super.dispose();
  }

  void _clearClipboard() {
    Clipboard.setData(const ClipboardData(text: ''));
  }

  /// Dipanggil KioskController saat native mendeteksi pelanggaran (split-screen, unpin, dll.).
  void _onNativeViolation(String reason) {
    _logViolation(reason, data: {'phase': _webPhase});

    // Jika lock task / pinned screen dilepas (alarm aktif) → langsung suspend akun siswa
    if (reason == 'lock_task_lost' || reason.contains('unpin')) {
      _handleUnpinSuspension();
    }
  }

  Future<void> _handleUnpinSuspension() async {
    final userId = widget.userId;
    if (userId > 0) {
      try {
        await ExamService.suspendStudent(
          userId: userId,
          reason: 'Siswa memaksa melepas pinned screen saat kuis aktif (alarm aktif)',
        );
      } catch (_) {}
    }
    await AuthService.saveBlockedStatus(true);
    await AuthService.saveSuspendedByAdmin(true);
    if (!mounted) return;
    await _goToBlockedScreen(
      'Akun Anda ditangguhkan karena memaksa melepas kuncian layar (pinned screen) saat kuis berlangsung.',
    );
  }

  // ─── App Lifecycle: deteksi minimize / background ────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Hanya paused (app benar-benar di-background) yang memicu pengecekan.
    // inactive = keyboard muncul / dialog sistem / transisi — bukan pelanggaran siswa,
    // sehingga tidak boleh memulai timer suspend.
    if (state == AppLifecycleState.paused) {
      _onAppBackground();
    } else if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  void _onAppBackground() {
    if (_examState != ExamState.active && _examState != ExamState.paused) return;

    // Grace period 30 detik setelah enterLockTask dipanggil: sistem Android
    // sempat mengambil fokus untuk menampilkan dialog "App pinned", sehingga
    // app masuk background sementara — bukan pelanggaran siswa.
    if (_kioskActivatingAt != null) {
      final sinceKiosk = DateTime.now().difference(_kioskActivatingAt!).inSeconds;
      if (sinceKiosk < 30) {
        debugPrint('[Kiosk] Background diabaikan: pinning baru dimulai ($sinceKiosk dtk lalu)');
        return;
      }
      _kioskActivatingAt = null; // grace period selesai
    }

    _backgroundedDuringActiveExam = true;
    _backgroundedAt = DateTime.now();
    _serverBlockSent = false;
    _heartbeatTimer?.cancel();

    _logViolation('app_background', data: {
      'phase': _webPhase,
      'time':  DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });

    // Jika siswa tidak kembali dalam 45 detik, suspend akun langsung.
    // Retry 3x dengan jeda 5 detik; jika semua gagal (offline),
    // pending disimpan ke storage untuk dikirim saat app restart.
    _blockTimer?.cancel();
    _blockTimer = Timer(
      const Duration(seconds: AppConfig.backgroundBlockTimeout),
      () async {
        bool suspended = false;
        for (int attempt = 0; attempt < 3 && !suspended; attempt++) {
          if (attempt > 0) await Future.delayed(const Duration(seconds: 5));
          suspended = await ExamService.suspendStudent(userId: widget.userId);
        }
        _serverBlockSent = true;
        if (!suspended) await ExamScreen._savePendingSuspend(widget.userId);
      },
    );
  }

  Future<void> _onAppResumed() async {
    _blockTimer?.cancel();

    if (_backgroundedDuringActiveExam &&
        (_examState == ExamState.active || _examState == ExamState.paused)) {
      _backgroundedDuringActiveExam = false;
      final elapsed = _backgroundedAt != null
          ? DateTime.now().difference(_backgroundedAt!).inSeconds
          : 999;

      if (_serverBlockSent || elapsed >= AppConfig.backgroundBlockTimeout) {
        // Pelanggaran fatal: siswa kembali setelah timeout 45 detik → suspend akun.
        if (!_serverBlockSent) {
          _serverBlockSent = true;
          bool suspended = false;
          for (int attempt = 0; attempt < 2 && !suspended; attempt++) {
            if (attempt > 0) await Future.delayed(const Duration(seconds: 3));
            suspended = await ExamService.suspendStudent(userId: widget.userId);
          }
          if (!suspended) await ExamScreen._savePendingSuspend(widget.userId);
        }
        await _logViolation('manually_blocked', data: {
          'reason': 'background_timeout_auto_suspend',
          'elapsed_seconds': elapsed,
          'timeout_seconds': AppConfig.backgroundBlockTimeout,
          'phase': _webPhase,
        });
        await _goToSuspendedLogin();
        return;
      }

      // Kembali sebelum 45 detik — tampilkan peringatan, cek status sesi
      if (elapsed > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Peringatan: Anda keluar aplikasi selama $elapsed detik. '
              'Keluar lebih dari ${AppConfig.backgroundBlockTimeout} detik akan mensuspend akun Anda.',
            ),
            backgroundColor: const Color(0xFFB45309),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      await _checkSessionStatus();
      if (!mounted) return;
      if (_examState == ExamState.active || _examState == ExamState.paused) _startHeartbeat();
      return;
    }

    if (_examState == ExamState.active || _examState == ExamState.paused) {
      await _checkSessionStatus();
      if (!mounted) return;
      if (_examState == ExamState.active || _examState == ExamState.paused) _startHeartbeat();
    }
  }

  // ─── FLAG_SECURE (mencegah screenshot di Android) ─────────────────────────

  Future<void> _enableLockdown() async {
    try {
      await _lockdownChannel.invokeMethod('enableLockdown');
    } catch (e) {
      // Abaikan di platform yang tidak mendukung (iOS / emulator)
      debugPrint('[Lockdown] enableLockdown tidak didukung: $e');
    }
  }

  /// Immersive + Lock Task: di Android dari native Activity; di iOS pakai SystemChrome.
  /// Dipanggil sedini mungkin saat layar ujian (WebView) tampil, tidak hanya di halaman /mod/quiz/.
  Future<void> _enterExamKioskMode() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (_androidExamKioskNative) return;

      // Tandai waktu masuk kiosk — memberi grace period 30 detik di _onAppBackground()
      // agar event sistem saat inisialisasi WebView (keyboard, dialog) tidak memicu suspend.
      _kioskActivatingAt ??= DateTime.now();

      // Jika sudah disematkan (mis. KioskController.lock() saat login), hanya
      // perbarui flag — jangan panggil enterLockTask lagi supaya notifikasi
      // "App pinned" tidak muncul dua kali di awal ujian.
      final alreadyPinned = await KioskController.instance.isLockTaskPinned();
      if (alreadyPinned) {
        _androidLockTaskActive  = true;
        _androidExamKioskNative = true;
        _immersiveUiActive      = true;
        if (!_backButtonLocked) {
          try {
            await _lockdownChannel.invokeMethod('lockBackButton');
            _backButtonLocked = true;
          } catch (_) {}
        }
        debugPrint('[Kiosk] Lock Task sudah aktif (skip enterLockTask)');
        return;
      }

      // Timpa waktu pinning agar 30 detik dihitung sejak enterLockTask dipanggil.
      _kioskActivatingAt = DateTime.now();

      bool lockTaskRejected = false;
      try {
        final ok = await _lockdownChannel.invokeMethod<bool>('enterLockTask');
        _androidLockTaskActive  = ok == true;
        _androidExamKioskNative = true;   // selalu true agar guard mencegah concurrent call
        _immersiveUiActive = true;
        if (_androidLockTaskActive) {
          debugPrint('[Kiosk] Lock Task aktif (screen pinning)');
        } else {
          debugPrint('[Kiosk] Immersive native aktif; screen pinning ditolak perangkat');
        }

        // Log agar teacher bisa cek penyebab Home/Overview masih bisa dipakai.
        if (!_androidLockTaskActive &&
            !_lockTaskFailureLogged &&
            _sessionId > 0 &&
            (_examState == ExamState.active || _examState == ExamState.paused)) {
          _lockTaskFailureLogged = true;
          await _logViolation('lock_task_failed', data: {
            'phase': _webPhase,
            'enterLockTask_result': ok == null ? 'null' : ok.toString(),
          });
        }

        lockTaskRejected = !_androidLockTaskActive && _examState == ExamState.active;
      } catch (e) {
        debugPrint('[Kiosk] enterLockTask: $e');
      }

      // Kunci tombol Back native — selalu, terlepas dari hasil lockTask
      if (!_backButtonLocked) {
        try {
          await _lockdownChannel.invokeMethod('lockBackButton');
          _backButtonLocked = true;
        } catch (_) {}
      }

      if (lockTaskRejected) await _handleLockTaskRejected();
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (!_immersiveUiActive) {
        try {
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
          _immersiveUiActive = true;
        } catch (e) {
          debugPrint('[Kiosk] iOS immersive: $e');
        }
      }

      final isGuided = await KioskController.instance.isGuidedAccessActive();
      if (!isGuided && mounted) {
        await _showGuidedAccessPrompt();
      }
      return;
    }

    if (_immersiveUiActive) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _immersiveUiActive = true;
    } catch (e) {
      debugPrint('[Kiosk] immersive: $e');
    }
  }

  /// Dialog panduan aktivasi Akses Terpandu (Guided Access) resmi Apple untuk siswa iOS.
  Future<void> _showGuidedAccessPrompt() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.lock_person_rounded, color: Color(0xFF38BDF8), size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Aktifkan Akses Terpandu',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Demi keamanan ujian, perangkat iOS (iPhone/iPad) wajib mengaktifkan Akses Terpandu (Guided Access):',
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                '1. Tekan tombol samping (Power) 3 kali cepat.\n'
                '2. Ketuk "Mulai" di sudut kanan atas.\n'
                '3. Masukkan kode sandi ujian dari pengawas.',
                style: TextStyle(
                  color: Color(0xFFBAE6FD),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.6,
                ),
              ),
              SizedBox(height: 12),
              Text(
                'Catatan: Jika belum diaktifkan di sistem, buka Pengaturan iPhone → Aksesibilitas → Akses Terpandu.',
                style: TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            ElevatedButton.icon(
              onPressed: () async {
                final active = await KioskController.instance.isGuidedAccessActive();
                if (active) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                } else {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Akses Terpandu belum aktif. Silakan tekan tombol samping 3 kali.'),
                        backgroundColor: Color(0xFFDC2626),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text('Cek Status & Lanjutkan'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exitExamKioskMode() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (_androidExamKioskNative) {
        try {
          await _lockdownChannel.invokeMethod('exitLockTask');
        } catch (e) {
          debugPrint('[Kiosk] exitLockTask: $e');
        }
        _androidExamKioskNative = false;
        _androidLockTaskActive  = false;
        _immersiveUiActive      = false;
      }
      // Buka kunci Back native
      if (_backButtonLocked) {
        try {
          await _lockdownChannel.invokeMethod('unlockBackButton');
        } catch (_) {}
        _backButtonLocked = false;
      }
      return;
    }

    if (_immersiveUiActive) {
      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (e) {
        debugPrint('[Kiosk] restore system UI: $e');
      }
      _immersiveUiActive = false;
    }
  }

  /// Keluar dari immersive + Lock Task (mis. ujian selesai / diblokir / tutup layar).
  Future<void> _handleLockTaskRejected() async {
    if (!mounted) return;
    // Perangkat menolak Screen Pinning → blokir sesi; siswa harus minta guru reset.
    _heartbeatTimer?.cancel();
    await _exitExamKioskMode();
    await _logViolation('lock_task_rejected', data: {
      'phase': _webPhase,
      'reason': 'screen_pinning_not_accepted',
    });
    if (!mounted) return;
    await _goToBlockedScreen(
      'Mode penguncian layar (Screen Pinning) tidak diaktifkan.\n\n'
      'Aktifkan "Sematkan layar" di Pengaturan Android, lalu hubungi '
      'guru untuk mereset sesi sebelum mencoba kembali.',
    );
  }

  bool _isAllowedUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'http' && uri.scheme != 'https') return false;
      final host = uri.host.toLowerCase();
      return AppConfig.allowedHosts.any(
        (h) => host == h.toLowerCase() || host.endsWith('.${h.toLowerCase()}'),
      );
    } catch (_) {
      return false;
    }
  }

  bool _isBlockedScheme(String url) {
    // Skema yang biasanya keluar dari app atau membuka aplikasi lain.
    final lower = url.toLowerCase();
    return lower.startsWith('intent:') ||
        lower.startsWith('market:') ||
        lower.startsWith('tel:') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('sms:') ||
        lower.startsWith('whatsapp:') ||
        lower.startsWith('tg:');
  }

  // ─── Register Session + Mulai ─────────────────────────────────────────────

  Future<void> _registerAndStart() async {
    if (!mounted) return;
    setState(() {
      _examState     = ExamState.loading;
      _statusMessage = 'Mendaftarkan sesi ujian...';
    });

    final result = await ExamService.registerSession(
      userId:   widget.userId,
      quizId:   widget.quiz.id,
      courseId: widget.courseId,
    );

    if (!mounted) return;

    if (result.isBlocked) {
      _sessionId = result.sessionId;
      await _goToBlockedScreen(result.message);
      return;
    }

    if (result.isPaused) {
      setState(() {
        _examState     = ExamState.paused;
        _statusMessage = result.message;
        _sessionId     = result.sessionId;
      });
      // Tetap mulai heartbeat agar bisa deteksi saat guru resume
      _sessionId = result.sessionId;
      _startHeartbeat();
      return;
    }

    if (!result.success) {
      await _logViolation('session_register_failed', data: {
        'status': result.status,
        'message': result.message,
      });
      setState(() {
        _examState     = ExamState.error;
        _statusMessage = result.message.isNotEmpty
            ? result.message
            : 'Gagal mendaftarkan sesi ujian.';
      });
      return;
    }

    // Sesi aktif berhasil
    _sessionId = result.sessionId;

    setState(() {
      _examState     = ExamState.active;
      _statusMessage = '';
      _webPhase      = 'init';
    });

    _startHeartbeat();
  }

  // ─── Heartbeat Timer ──────────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: AppConfig.heartbeatInterval),
      (_) => _sendHeartbeat(),
    );
  }

  /// Navigasi ke BlockedScreen — keluar kiosk, bersihkan stack, tampilkan peringatan.
  Future<void> _goToBlockedScreen(String reason) async {
    _heartbeatTimer?.cancel();
    _blockTimer?.cancel();
    setState(() => _examState = ExamState.blocked);
    await _exitExamKioskMode();
    if (!mounted) return;
    KioskController.instance.exitExam();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => BlockedScreen(
          userId: widget.userId,
          reason: reason,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _goToSuspendedLogin() async {
    _heartbeatTimer?.cancel();
    _blockTimer?.cancel();
    await _exitExamKioskMode();
    await AuthService.saveSuspendedByAdmin(true);
    await AuthService.saveBlockedStatus(false);
    await AuthService.logout();
    if (!mounted) return;
    KioskController.instance.exitExam();
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Future<void> _sendHeartbeat() async {
    if (_sessionId == 0) return;
    // Hentikan heartbeat jika ujian sudah selesai/error/blocked
    if (_examState == ExamState.completed ||
        _examState == ExamState.error ||
        _examState == ExamState.blocked) {
      _heartbeatTimer?.cancel();
      return;
    }

    HeartbeatResult result;
    try {
      result = await ExamService.sendHeartbeat(
        sessionId: _sessionId,
        userId:    widget.userId,
      );
    } on TokenExpiredException {
      // Token dihapus oleh admin saat suspend — paksa keluar
      await _goToSuspendedLogin();
      return;
    }

    if (!mounted) return;

    if (result.isSuspended) {
      await _goToSuspendedLogin();
      return;
    }

    if (result.isBlocked && _examState != ExamState.blocked) {
      _consecutiveHeartbeatErrors = 0;
      await _goToBlockedScreen(result.message);
      return;
    }

    // Heartbeat gagal karena network — setelah 3x berturut-turut, paksa cek status server
    if (result.status == 'error') {
      _consecutiveHeartbeatErrors++;
      if (_consecutiveHeartbeatErrors >= 3) {
        _consecutiveHeartbeatErrors = 0;
        await _checkSessionStatus();
      }
      return;
    }

    _consecutiveHeartbeatErrors = 0;

    if (result.isPaused && _examState == ExamState.active) {
      setState(() {
        _examState     = ExamState.paused;
        _statusMessage = result.message;
      });
    } else if (result.isActive && _examState == ExamState.paused) {
      // Guru resume — kembali aktif
      setState(() {
        _examState     = ExamState.active;
        _statusMessage = '';
      });
    }
  }

  Future<void> _onRequestExitPressed() async {
    if (_sessionId == 0 || _examState != ExamState.active) return;

    final ctrl = TextEditingController();
    final pwdOk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar Kuis'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Masukkan password keluar untuk menutup aplikasi ujian.',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Password keluar',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () async {
              final result = await _validateAdminExitPassword(ctrl.text);
              if (!mounted || !ctx.mounted) return;
              if (result.networkError) {
                Navigator.of(ctx).pop(null);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Tidak dapat verifikasi — periksa koneksi internet.',
                    ),
                    backgroundColor: Color(0xFFD97706),
                  ),
                );
                return;
              }
              Navigator.of(ctx).pop(result.success);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (!mounted) return;

    if (pwdOk == null) return; // Batal

    if (pwdOk == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password salah. Tidak bisa keluar.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    // Password benar — keluar dari kuis, kembali ke daftar course
    _heartbeatTimer?.cancel();
    await _exitExamKioskMode();
    if (!mounted) return;
    await _logViolation('exam_end', data: {
      'quizid':   widget.quiz.id,
      'courseid': widget.courseId,
      'reason':   'exit_password_ok',
    });
    KioskController.instance.exitExam();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Mengembalikan (success, networkError).
  Future<({bool success, bool networkError})> _validateAdminExitPassword(
      String entered) async {
    try {
      final r = await ExamService.verifyExitPassword(
        sessionId: _sessionId,
        userId: widget.userId,
        password: entered,
      );
      return (success: r.success, networkError: false);
    } catch (_) {
      // Server tidak terjangkau — tolak keluar untuk keamanan.
      return (success: false, networkError: true);
    }
  }

  // ─── Cek status sesi (setelah resume dari background) ────────────────────

  Future<void> _checkSessionStatus() async {
    if (_sessionId == 0) return;
    RegisterSessionResult result;
    try {
      result = await ExamService.registerSession(
        userId:   widget.userId,
        quizId:   widget.quiz.id,
        courseId: widget.courseId,
      );
    } on TokenExpiredException {
      await _goToSuspendedLogin();
      return;
    }
    if (!mounted) return;

    if (result.isSuspended) {
      await _goToSuspendedLogin();
    } else if (result.isBlocked && _examState != ExamState.blocked) {
      await _goToBlockedScreen(result.message);
    } else if (result.isPaused && _examState == ExamState.active) {
      setState(() {
        _examState     = ExamState.paused;
        _statusMessage = result.message;
      });
    }
  }

  // ─── Log Violation ────────────────────────────────────────────────────────

  Future<void> _logViolation(
    String eventType, {
    Map<String, dynamic>? data,
  }) async {
    final eventData = data != null
        ? ExamService.buildEventData(data)
        : '{}';

    await ExamService.logActivity(
      userId:    widget.userId,
      quizId:    widget.quiz.id,
      courseId:  widget.courseId,
      eventType: eventType,
      eventData: eventData,
    );
  }

  // ─── JavaScript da injeksi ke WebView ─────────────────────────────────────

  /// Login auto-fill — dipanggil saat WebView di halaman login Moodle
  Future<void> _injectLoginScript() async {
    if (_webCtrl == null) return;
    final safeUser = widget.username.replaceAll("'", "\\'");
    final safePass = widget.password.replaceAll("'", "\\'");

    await _webCtrl!.evaluateJavascript(source: '''
      (function() {
        var u = document.getElementById('username');
        var p = document.getElementById('password');
        var b = document.getElementById('loginbtn');
        if (u && p) {
          u.value = '$safeUser';
          p.value = '$safePass';
          if (b) {
            setTimeout(function(){ b.click(); }, 300);
          } else {
            var form = u.closest('form');
            if (form) setTimeout(function(){ form.submit(); }, 300);
          }
        }
      })();
    ''');
  }

  /// Auto-fill password akses kuis Moodle (field #id_quizpassword).
  /// Dipanggil setiap kali halaman /mod/quiz/ selesai dimuat.
  /// Jika field tidak ditemukan (halaman tidak meminta password), script ini tidak melakukan apa-apa.
  Future<void> _injectQuizPasswordScript() async {
    if (_webCtrl == null) return;
    final safePass = AppConfig.quizAccessPassword.replaceAll("'", "\\'");
    await _webCtrl!.evaluateJavascript(source: '''
      (function() {
        var inp = document.getElementById('id_quizpassword');
        if (!inp) return;
        inp.value = '$safePass';
        var form = inp.closest('form');
        if (form) setTimeout(function() { form.submit(); }, 400);
      })();
    ''');
  }

  /// Injeksi monitoring violations — dipanggil saat WebView masuk halaman quiz
  Future<void> _injectLockdownScript() async {
    if (_webCtrl == null) return;

        await _webCtrl!.evaluateJavascript(source: r'''
      (function() {

        // ── Paksa window.open ke tab yang sama (tanpa tab baru) ───────────
        try {
          window.open = function(url) {
            if (typeof url === 'string' && url.length) {
              window.location.href = url;
            }
            return null;
          };
        } catch (e) {}

        // ── Cegah copy/paste ──────────────────────────────────────────────
        document.addEventListener('copy', function(e) {
          e.preventDefault();
          window.flutter_inappwebview.callHandler('onViolation', 'copy_attempt',
            JSON.stringify({ method: 'copy_event' }));
        }, true);

        document.addEventListener('cut', function(e) {
          e.preventDefault();
          window.flutter_inappwebview.callHandler('onViolation', 'copy_attempt',
            JSON.stringify({ method: 'cut_event' }));
        }, true);

        // ── Cegah context menu (klik kanan / long-press) ──────────────────
        document.addEventListener('contextmenu', function(e) {
          e.preventDefault();
        }, true);

        // ── Cegah teks dipilih ────────────────────────────────────────────
        document.body.style.webkitUserSelect = 'none';
        document.body.style.userSelect = 'none';
        document.body.style.webkitTouchCallout = 'none';

        // ── Deteksi tab / dokumen tidak terlihat ──────────────────────────
        document.addEventListener('visibilitychange', function() {
          if (document.hidden) {
            window.flutter_inappwebview.callHandler('onViolation', 'focus_lost',
              JSON.stringify({ trigger: 'visibilitychange' }));
          }
        });

        // ── Deteksi multi-finger gesture (3+ jari) ────────────────────────
        document.addEventListener('touchstart', function(e) {
          if (e.touches.length >= 3) {
            window.flutter_inappwebview.callHandler('onViolation', 'multi_finger_gesture',
              JSON.stringify({ fingers: e.touches.length }));
          }
        }, { passive: true });

        // ── Cegah keyboard shortcut copy / paste di desktop ───────────────
        document.addEventListener('keydown', function(e) {
          if ((e.ctrlKey || e.metaKey) &&
              (e.key === 'c' || e.key === 'v' || e.key === 'x' || e.key === 'a')) {
            e.preventDefault();
            window.flutter_inappwebview.callHandler('onViolation', 'copy_attempt',
              JSON.stringify({ method: 'keyboard_shortcut', key: e.key }));
          }
        }, true);

        console.log('[Dosman] Lockdown script aktif');
      })();
    ''');
  }

  /// Injeksi heartbeat dashboard: panggil web_heartbeat.php setiap 15 detik
  /// dari dalam WebView agar admin bisa melihat siswa aktif + nama kuis di monitor.php.
  /// Menggunakan flag window._dosmanHbActive agar tidak double-inject saat navigasi antar halaman.
  Future<void> _injectWebHeartbeat() async {
    if (_webCtrl == null) return;
    final quizId         = widget.quiz.id;
    const baseUrl        = AppConfig.moodleUrl;
    await _webCtrl!.evaluateJavascript(source: '''
      (function() {
        if (window._dosmanHbActive) return;
        window._dosmanHbActive = true;
        function sendHb() {
          try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET',
              '$baseUrl/local/dosman_ujian/web_heartbeat.php?quizid=$quizId',
              true);
            xhr.send();
          } catch(e) {}
        }
        sendHb();
        window._dosmanHbTimer = setInterval(sendHb, 15000);
      })();
    ''');
  }

  /// Mode fokus kuis:
  /// - Tampilkan judul kuis, kartu nomor soal (quiz navigation), soal & jawaban,
  ///   tombol Next/Previous.
  /// - Sembunyikan elemen navigasi Moodle lain (navbar, drawer, breadcrumb, footer, dll).
  ///
  /// Catatan: selector Moodle bisa sedikit berbeda antar tema/versi,
  /// jadi styling ini dibuat generik.
  Future<void> _injectQuizFocusStyles() async {
    if (_webCtrl == null) return;

    await _webCtrl!.evaluateJavascript(source: r'''
      (function() {
        try {
          var id = 'dosman-quiz-focus-style';
          var old = document.getElementById(id);
          if (old) old.remove();

          var css = [
            /* Cegah konten meluber ke samping di layar sempit */
            'body, #page { max-width: 100% !important; overflow-x: hidden !important; box-sizing: border-box; }',

            /* Gambar & media responsif */
            'img, video, iframe { max-width: 100% !important; height: auto !important; }',
          ].join('\\n');

          var style = document.createElement('style');
          style.id = id;
          style.type = 'text/css';
          style.appendChild(document.createTextNode(css));
          document.head.appendChild(style);
        } catch (e) {
          console.log('[Dosman] _injectQuizFocusStyles error:', e);
        }
      })();
    ''');
  }

  // ─── WebView URL handler ──────────────────────────────────────────────────

  Future<void> _handlePageLoaded(Uri? url) async {
    if (url == null) return;
    final urlStr = url.toString();

    debugPrint('[WebView] Loaded: $urlStr | phase: $_webPhase');

    if (_webPhase == 'init' || _webPhase == 'login') {
      if (urlStr.contains('/login/index.php') ||
          urlStr.contains('/login/') && !urlStr.contains('/mod/')) {
        _webPhase = 'login';
        _webLoginAttempts++;

        // Jika halaman login muncul lebih dari 1x, credentials ditolak Moodle web.
        // Kembali ke login Flutter agar siswa masukkan ulang credentials yang benar.
        if (_webLoginAttempts > 1) {
          await _exitExamKioskMode();
          await AuthService.logout();
          if (!mounted) return;
          KioskController.instance.exitExam();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Username atau password salah. Silakan login kembali.',
              ),
              backgroundColor: Color(0xFFDC2626),
              duration: Duration(seconds: 4),
            ),
          );
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
          return;
        }

        // Percobaan pertama → inject auto-fill
        await Future.delayed(const Duration(milliseconds: 400));
        await _injectLoginScript();
      } else if (!urlStr.contains('/login/')) {
        // Berhasil login → reset counter dan arahkan ke quiz
        _webPhase = 'quiz_nav';
        _webLoginAttempts = 0;
        final quizUrl = widget.quiz.quizUrl(AppConfig.moodleUrl);
        await _webCtrl?.loadUrl(urlRequest: URLRequest(url: WebUri(quizUrl)));
      }
    } else if (_webPhase == 'quiz_nav' || _webPhase == 'quiz') {
      if (urlStr.contains('/mod/quiz/')) {
        _webPhase = 'quiz';
        await _injectQuizFocusStyles();
        await _injectQuizPasswordScript();
        await _injectLockdownScript();
        await _injectWebHeartbeat();
        await _enterExamKioskMode();

        // Log exam_start hanya sekali
        if (!_examStartLogged) {
          _examStartLogged = true;
          await _logViolation('exam_start', data: {
            'quizid':   widget.quiz.id,
            'courseid': widget.courseId,
          });
        }
      }

      // Deteksi quiz selesai (URL review / summary)
      if ((urlStr.contains('/mod/quiz/review.php') ||
           urlStr.contains('/mod/quiz/summary.php')) &&
           _examState != ExamState.completed) {
        await _onExamCompleted();
      }
    }
  }

  Future<void> _onExamCompleted() async {
    _heartbeatTimer?.cancel();
    await _exitExamKioskMode();

    await _logViolation('exam_end', data: {
      'quizid':   widget.quiz.id,
      'courseid': widget.courseId,
    });

    // Hentikan heartbeat JS — lastping tidak diperbarui lagi.
    // Dashboard otomatis menampilkan "Keluar" dalam <5 menit saat lastping kadaluarsa.
    try {
      await _webCtrl?.evaluateJavascript(source: r'''
        (function() {
          if (window._dosmanHbTimer) {
            clearInterval(window._dosmanHbTimer);
            window._dosmanHbTimer  = null;
            window._dosmanHbActive = false;
          }
        })();
      ''');
    } catch (_) {}

    if (!mounted) return;
    setState(() => _examState = ExamState.completed);
  }

  // ─── Pop (Tombol Kembali) ─────────────────────────────────────────────────

  Future<bool> _onWillPop() async {
    // blocked = layar terkunci total, siswa tidak bisa keluar sendiri
    if (_examState == ExamState.completed ||
        _examState == ExamState.error) {
      return true;
    }
    return false;
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final canPopExam = _examState == ExamState.completed ||
        _examState == ExamState.error;
    // blocked sengaja dikecualikan — layar tidak bisa di-dismiss

    return PopScope(
      canPop: canPopExam,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        final allow = await _onWillPop();
        if (allow && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: Stack(
          children: [
            // ── WebView (selalu ada di background) ───────────────────────
            if (_examState == ExamState.active ||
                _examState == ExamState.paused ||
                _examState == ExamState.loading && _sessionId > 0)
              _buildWebView(),

            // ── Loading Overlay ──────────────────────────────────────────
            if (_examState == ExamState.loading)
              _buildLoadingOverlay(),

            // ── Paused Overlay ───────────────────────────────────────────
            if (_examState == ExamState.paused)
              _buildPausedOverlay(),

            // ── Completed Overlay ────────────────────────────────────────
            if (_examState == ExamState.completed)
              _buildCompletedOverlay(),

            // ── Error Overlay ────────────────────────────────────────────
            if (_examState == ExamState.error)
              _buildErrorOverlay(),
          ],
        ),
      ),
    );
  }

  // ─── WebView ──────────────────────────────────────────────────────────────

  Widget _buildWebView() {
    // URL awal: selalu login page dulu, Moodle akan redirect ke quiz
    // setelah user berhasil login
    const initialUrl = '${AppConfig.moodleUrl}/login/index.php';

    return SafeArea(
      child: Column(
        children: [
          // ── Status Bar atas ──────────────────────────────────────────
          _buildExamTopBar(),

          // ── WebView ──────────────────────────────────────────────────
          Expanded(
            child: InAppWebView(
              key: _webKey,
              initialUrlRequest: URLRequest(
                url: WebUri(initialUrl),
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: r'''
(function() {
  try {
    window.open = function(url) {
      if (typeof url === 'string' && url.length) { window.location.href = url; }
      return null;
    };
  } catch (e) {}
})();
''',
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: true,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled:              true,
                domStorageEnabled:              true,
                databaseEnabled:                true,
                supportZoom:                    false,
                builtInZoomControls:            false,
                displayZoomControls:            false,
                allowsLinkPreview:              false,
                disableContextMenu:             true,
                disableLongPressContextMenuOnLinks: true,
                mediaPlaybackRequiresUserGesture: false,
                useHybridComposition:           true,
                clearCache:                     true,
                // Satu window — hindari perilaku mirip tab baru di WebView
                supportMultipleWindows:         false,
                // Paksa user-agent mobile; mengandung ExamDosmanAndroid
                // agar skrip server dapat mengenali request dari aplikasi ini.
                userAgent: AppConfig.examBrowserUserAgent,
              ),
              onReceivedServerTrustAuthRequest: (controller, challenge) async {
                final host = challenge.protectionSpace.host;
                if (host == '36.93.15.146' || host == 'lms.sman1-gianyar.sch.id') {
                  return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
                }
                return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL);
              },
              onWebViewCreated: (ctrl) {
                _webCtrl = ctrl;

                // Kiosk sedini mungkin (login + quiz), bukan hanya setelah /mod/quiz/
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_examState == ExamState.active ||
                      _examState == ExamState.paused ||
                      (_examState == ExamState.loading && _sessionId > 0)) {
                    _enterExamKioskMode();
                  }
                });

                // Daftarkan JavaScript handler untuk menerima laporan violation
                ctrl.addJavaScriptHandler(
                  handlerName: 'onViolation',
                  callback: (args) {
                    if (args.isEmpty) return;
                    final eventType = args[0] as String? ?? 'unknown';
                    final rawData   = args.length > 1
                        ? args[1] as String? ?? '{}'
                        : '{}';

                    debugPrint('[Violation] $eventType | $rawData');

                    // Hanya log saat ujian aktif
                    if (_examState == ExamState.active) {
                      ExamService.logActivity(
                        userId:    widget.userId,
                        quizId:    widget.quiz.id,
                        courseId:  widget.courseId,
                        eventType: eventType,
                        eventData: rawData,
                      );
                    }
                  },
                );
              },

              onLoadStop: (ctrl, url) async {
                // Blokir copy/paste di setiap halaman, bukan hanya halaman quiz
                await ctrl.evaluateJavascript(source: r'''
(function() {
  document.addEventListener('copy',        function(e){ e.preventDefault(); }, true);
  document.addEventListener('cut',         function(e){ e.preventDefault(); }, true);
  document.addEventListener('contextmenu', function(e){ e.preventDefault(); }, true);
  document.addEventListener('keydown', function(e) {
    if ((e.ctrlKey || e.metaKey) &&
        (e.key === 'c' || e.key === 'v' || e.key === 'x' || e.key === 'a')) {
      e.preventDefault();
    }
  }, true);
  if (document.body) {
    document.body.style.webkitUserSelect   = 'none';
    document.body.style.userSelect         = 'none';
    document.body.style.webkitTouchCallout = 'none';
  }
})();
''');
                await _handlePageLoaded(url?.uriValue);
              },

              onReceivedError: (ctrl, request, error) {
                debugPrint(
                  '[WebView] Load error: ${error.type} ${error.description} '
                  'url=${request.url}',
                );
              },

              onConsoleMessage: (ctrl, msg) {
                debugPrint('[WebView Console] ${msg.message}');
              },

              // Blokir navigasi keluar dari domain Moodle
              shouldOverrideUrlLoading: (ctrl, action) async {
                final url = action.request.url?.toString() ?? '';
                if (url.isEmpty) {
                  return NavigationActionPolicy.CANCEL;
                }

                if (_isBlockedScheme(url)) {
                  debugPrint('[WebView] Blokir scheme external: $url');
                  if (_examState == ExamState.active) {
                    await _logViolation('external_scheme_blocked', data: {
                      'url': url,
                      'phase': _webPhase,
                    });
                  }
                  return NavigationActionPolicy.CANCEL;
                }

                if (_isAllowedUrl(url)) {
                  return NavigationActionPolicy.ALLOW;
                }
                // Blokir URL external
                debugPrint('[WebView] Blokir navigasi ke: $url');
                if (_examState == ExamState.active) {
                  await _logViolation('external_navigation_blocked', data: {
                    'url': url,
                    'phase': _webPhase,
                  });
                }
                return NavigationActionPolicy.CANCEL;
              },

              onDownloadStartRequest: (ctrl, request) async {
                final url = request.url.toString();
                debugPrint('[WebView] Blokir download: $url');
                if (_examState == ExamState.active) {
                  await _logViolation('download_blocked', data: {
                    'url': url,
                    'phase': _webPhase,
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─── Top Bar saat Ujian Aktif ─────────────────────────────────────────────

  Widget _buildExamTopBar() {
    final showExitBtn = _examState == ExamState.active &&
        (_webPhase == 'quiz' || _webPhase == 'quiz_nav');

    return Container(
      height: 52,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0F2044), Color(0xFF1E3A5F)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2563EB), width: 2),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Logo + nama app
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.all(2),
            child: Image.asset(
              'assets/logo_sekolah.png',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(width: 7),
          const Text(
            'Dosman Exam',
            style: TextStyle(
              fontSize:   13,
              fontWeight: FontWeight.w800,
              color:      Colors.white,
              letterSpacing: 0.2,
            ),
          ),
          // Pemisah vertikal
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            width: 1, height: 20,
            color: Colors.white24,
          ),
          // Nama quiz (mengisi sisa ruang)
          Expanded(
            child: Text(
              '🔒 ${widget.quiz.name}',
              style: const TextStyle(
                fontSize:   11,
                color:      Colors.white60,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Live indicator
          if (_examState == ExamState.active) ...[
            const SizedBox(width: 6),
            Container(
              width: 7, height: 7,
              decoration: const BoxDecoration(
                color: Color(0xFF22C55E),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            const Text(
              'Live',
              style: TextStyle(
                fontSize:  10,
                color:     Color(0xFF22C55E),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(width: 6),
          // Tombol Petunjuk
          _NavBtn(
            label: 'Petunjuk',
            icon:  Icons.help_outline,
            onTap: _showPetunjukModal,
          ),
          // Tombol Keluar (hanya saat quiz aktif)
          if (showExitBtn) ...[
            const SizedBox(width: 6),
            _NavBtn(
              label:     'Keluar',
              icon:      Icons.logout,
              danger:    true,
              onTap:     _onRequestExitPressed,
            ),
          ],
        ],
      ),
    );
  }

  // ─── Modal Petunjuk ───────────────────────────────────────────────────────

  void _showPetunjukModal() {
    final items = <List<String>>[
      ['🔒', 'Aplikasi terkunci selama ujian berlangsung'],
      ['📵', 'Dilarang membuka atau beralih ke aplikasi lain'],
      ['📋', 'Dilarang menyalin atau memotong teks'],
      ['👁️', 'Aktivitas layar dipantau guru secara real-time'],
      ['⏸️', 'Guru dapat menjeda atau memblokir sesi kapan saja'],
      ['🚪', 'Keluar aplikasi hanya diizinkan dengan password guru'],
      ['🤚', 'Jika ada kendala teknis, angkat tangan dan beritahu guru'],
    ];

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        backgroundColor: const Color(0xFF1E293B),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize:      MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color:        const Color(0xFF2563EB).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.info_outline,
                      color: Color(0xFF60A5FA),
                      size:  20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Petunjuk Ujian',
                      style: TextStyle(
                        fontSize:   16,
                        fontWeight: FontWeight.w800,
                        color:      Colors.white,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white38,
                      size:  20,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(color: Colors.white12),
              const SizedBox(height: 12),
              // Daftar petunjuk
              ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item[0], style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item[1],
                        style: const TextStyle(
                          fontSize: 13,
                          color:    Colors.white70,
                          height:   1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation:       0,
                    padding:         const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'Mengerti',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Loading Overlay ──────────────────────────────────────────────────────

  Widget _buildLoadingOverlay() {
    return Container(
      color: const Color(0xFF0F172A),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width:  80,
                height: 80,
                decoration: BoxDecoration(
                  color:        const Color(0xFF1E3A5F),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Center(
                  child: Text('📋', style: TextStyle(fontSize: 40)),
                ),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width:  36,
                height: 36,
                child:  CircularProgressIndicator(
                  color:       Color(0xFF2563EB),
                  strokeWidth: 3,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _statusMessage.isEmpty ? 'Menyiapkan ujian...' : _statusMessage,
                style: const TextStyle(
                  fontSize:  14,
                  color:     Colors.white70,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.quiz.name,
                style: const TextStyle(
                  fontSize:  12,
                  color:     Colors.white38,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Paused Overlay ───────────────────────────────────────────────────────

  Widget _buildPausedOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Ikon
                Container(
                  width:  90,
                  height: 90,
                  decoration: BoxDecoration(
                    color:        const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Center(
                    child: Text('⏸️', style: TextStyle(fontSize: 44)),
                  ),
                ),

                const SizedBox(height: 24),

                const Text(
                  'Ujian Dijeda',
                  style: TextStyle(
                    fontSize:   26,
                    fontWeight: FontWeight.w800,
                    color:      Colors.white,
                  ),
                ),

                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical:   12,
                  ),
                  decoration: BoxDecoration(
                    color:        const Color(0xFFFEF3C7).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border:       Border.all(
                      color: const Color(0xFFFDE68A).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    _kioskHint.isNotEmpty
                        ? _kioskHint
                        : (_statusMessage.isEmpty
                            ? 'Guru telah menjeda sesi ujian kamu.\n'
                              'Tunggu guru mengaktifkan kembali.'
                            : _statusMessage),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color:    Color(0xFFFDE68A),
                      height:   1.6,
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                if (_kioskHint.isNotEmpty) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        setState(() => _kioskHint = '');
                        await _enterExamKioskMode();
                      },
                      icon: const Icon(Icons.lock_outline, size: 18),
                      label: const Text(
                        'Coba aktifkan mode ujian',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // Indikator menunggu
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width:  14,
                      height: 14,
                      child:  CircularProgressIndicator(
                        color:       Color(0xFFFDE68A),
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Menunggu guru mengaktifkan kembali...',
                      style: TextStyle(
                        fontSize: 12,
                        color:    Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Completed Overlay ────────────────────────────────────────────────────

  Widget _buildCompletedOverlay() {
    return Container(
      color: const Color(0xFF0F172A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Ikon
              Container(
                width:  100,
                height: 100,
                decoration: BoxDecoration(
                  color:        const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Center(
                  child: Text('✅', style: TextStyle(fontSize: 52)),
                ),
              ),

              const SizedBox(height: 28),

              const Text(
                'Ujian Selesai!',
                style: TextStyle(
                  fontSize:   30,
                  fontWeight: FontWeight.w800,
                  color:      Colors.white,
                ),
              ),

              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical:   14,
                ),
                decoration: BoxDecoration(
                  color:        const Color(0xFFDCFCE7).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border:       Border.all(
                    color: const Color(0xFF86EFAC).withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  'Kamu berhasil menyelesaikan ujian\n"${widget.quiz.name}".\n\n'
                  'Hasil ujian dapat dilihat di Moodle.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color:    Color(0xFF86EFAC),
                    height:   1.7,
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // Tombol Kembali
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon:  const Icon(Icons.check_circle_outline, size: 20),
                  label: const Text(
                    'Selesai — Kembali ke Menu',
                    style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    elevation:       0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape:   RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Error Overlay ────────────────────────────────────────────────────────

  Widget _buildErrorOverlay() {
    return Container(
      color: const Color(0xFF0F172A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Ikon
              Container(
                width:  90,
                height: 90,
                decoration: BoxDecoration(
                  color:        const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Center(
                  child: Text('⚠️', style: TextStyle(fontSize: 44)),
                ),
              ),

              const SizedBox(height: 24),

              const Text(
                'Terjadi Kesalahan',
                style: TextStyle(
                  fontSize:   24,
                  fontWeight: FontWeight.w800,
                  color:      Colors.white,
                ),
              ),

              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _statusMessage.isEmpty
                      ? 'Tidak dapat memulai sesi ujian.\nPeriksa koneksi internet dan coba lagi.'
                      : _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color:    Colors.white60,
                    height:   1.6,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Tombol Coba Lagi
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _registerAndStart,
                  icon:  const Icon(Icons.refresh, size: 20),
                  label: const Text(
                    'Coba Lagi',
                    style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation:       0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:   RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Tombol Kembali
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon:  const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Kembali'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side:    const BorderSide(color: Colors.white12),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:   RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Widget tombol kecil di navbar ──────────────────────────────────────────

class _NavBtn extends StatelessWidget {
  const _NavBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final String   label;
  final IconData icon;
  final VoidCallback onTap;
  final bool     danger;

  @override
  Widget build(BuildContext context) {
    final fg     = danger ? const Color(0xFFFCA5A5) : Colors.white70;
    final border = danger
        ? const Color(0xFFDC2626)
        : Colors.white24;
    final bg     = danger
        ? const Color(0x26DC2626)   // red 15%
        : Colors.transparent;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color:        bg,
          border:       Border.all(color: border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize:   10,
                color:      fg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
