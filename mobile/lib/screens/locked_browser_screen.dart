// ===========================
// DOSMAN UJIAN - Locked Browser Screen
// Browser terkunci — hanya bisa akses lms.sman1-gianyar.sch.id
// ===========================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';
import '../services/device_service.dart';
import '../widgets/exit_password_dialog.dart';
import 'blocked_screen.dart';
import 'device_blocked_screen.dart';

class LockedBrowserScreen extends StatefulWidget {
  const LockedBrowserScreen({super.key});

  @override
  State<LockedBrowserScreen> createState() => _LockedBrowserScreenState();
}

class _LockedBrowserScreenState extends State<LockedBrowserScreen>
    with WidgetsBindingObserver {

  bool _isLoading       = true;
  bool _blockCheckDone  = false; // WebView tidak tampil sampai cek blokir selesai
  InAppWebViewController? _webController;

  // ─── Background / violation detection ────────────────────────────────────
  DateTime? _backgroundedAt;
  bool      _blockSent          = false;
  bool      _wifiSettingsActive = false; // true saat WiFi settings terbuka
  bool      _screenWasOff       = false; // true saat paused karena layar mati (bukan minimize)
  Timer?    _blockTimer;
  int       _cachedUserId = 0;
  String    _autoUsername  = '';
  String    _autoPassword  = '';

  // ─── Browser heartbeat (server-side detection) ───────────────────────────
  Timer? _pingTimer;
  Timer? _startupNoticeRetryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    KioskController.instance.addViolationListener(_onNativeViolation);
    _loadCachedUserId();
    _clearClipboard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await KioskController.instance.lock();
      if (!mounted) return;
      await _checkBlockedOnStart();
      if (!mounted) return;
      await _checkDeviceSecurity();
      await _checkRootStatus();
      await _checkAccessibilityServices();
      await _checkScreenCast();
      await _checkVpn();
    });
  }

  void _clearClipboard() {
    Clipboard.setData(const ClipboardData(text: ''));
  }

  Future<void> _loadCachedUserId() async {
    final id       = await AuthService.getUserId();
    final username = await AuthService.getUsername();
    final password = await AuthService.getPassword();
    if (mounted) {
      _cachedUserId = id;
      _autoUsername = username;
      _autoPassword = password ?? '';
    }
  }

  /// Saat app dibuka: cek status blokir (flag lokal → cek server;
  /// tidak ada flag → cek server). WebView tidak tampil sampai selesai.
  Future<void> _checkBlockedOnStart() async {
    // ── Prioritas 0: Device Binding — cek sebelum cek akun ──────────────────
    try {
      final deviceId = await DeviceService.getDeviceId();
      final deviceResult = await ExamService.checkDevice(deviceId);
      if (!mounted) return;
      if (deviceResult.blocked) {
        KioskController.instance.unlock();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DeviceBlockedScreen(
              reason: deviceResult.reason,
              blockedAt: deviceResult.blockedAt,
            ),
          ),
        );
        return;
      }
    } catch (_) {
      if (!mounted) return;
      // Network error saat cek device — lanjut tanpa memblokir berdasarkan asumsi
    }

    final locallyBlocked = await AuthService.getBlockedStatus();
    final userId = await AuthService.getUserId();
    if (!mounted) return;

    if (userId > 0) {
      // ── Prioritas 1: flag lokal → bersihkan, lanjut ke cek server ──────────
      // Flag true berarti siswa force-close saat di browser (bukan saat kuis).
      // Token masih valid — cukup bersihkan flag, tidak perlu login ulang.
      // Cek server tetap dijalankan untuk mendeteksi blokir admin.
      if (locallyBlocked) {
        await AuthService.saveBlockedStatus(false);
        if (!mounted) return;
      }

      // ── Prioritas 2: cek server (zombie session / blokir admin) ──────────
      try {
        final result = await ExamService.checkBlocked(userId: userId);
        if (!mounted) return;
        if (result.blocked) {
          await AuthService.saveBlockedStatus(true);
          if (!mounted) return;
          KioskController.instance.unlock();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => BlockedScreen(userId: userId, reason: result.reason),
            ),
          );
          return;
        }
      } catch (_) {
        if (!mounted) return;
        // Network error saat cek blokir — lanjut tanpa memblokir berdasarkan asumsi
      }
    }

    // Tidak diblokir → tandai "sedang dalam sesi browser terkunci".
    // Jika app di-force close sebelum _handleExit(), flag tetap true saat dibuka
    // ulang. _checkBlockedOnStart() membersihkan flag lalu menjalankan cek server.
    //
    // Cek _blockSent: jika native violation mengirim blokir bersamaan dengan
    // _checkBlockedOnStart() (race condition), jangan set flag atau mulai ping.
    if (_blockSent) return;
    if (userId > 0) {
      await AuthService.saveBlockedStatus(true);
      if (!mounted) return;
    }
    if (mounted && !_blockSent) {
      setState(() => _blockCheckDone = true);
      if (userId > 0) _startBrowserPing(userId);
    }
  }

  /// Mulai kirim ping ke server secara berkala.
  /// - browser_heartbeat setiap 20 detik (bukti app masih aktif)
  /// - app_ping (update lastping di appstatus) setiap 30 detik
  ///   agar server tidak menyuspensi siswa saat layar mati
  void _startBrowserPing(int userId) {
    _pingTimer?.cancel();
    ExamService.sendBrowserHeartbeat(userId: userId);
    ExamService.pingAppLogin();
    var tick = 0;
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      tick++;
      ExamService.sendBrowserHeartbeat(userId: userId);
      if (tick % 3 == 0) ExamService.pingAppLogin(); // setiap 30 detik
    });
  }

  /// Cek USB Debugging / Developer Mode saat screen pertama kali aktif.
  Future<void> _checkDeviceSecurity() async {
    final flags = await KioskController.instance.checkDeviceSecurityFlags();
    if (flags == null || !mounted) return;
    if (!flags.usbDebugging && !flags.developerMode) return;

    final issues = <String>[];
    if (flags.usbDebugging)  issues.add('• USB Debugging aktif');
    if (flags.developerMode) issues.add('• Mode Developer aktif');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.security, color: Color(0xFFF97316), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Peringatan Keamanan',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              issues.join('\n'),
              style: const TextStyle(
                color: Color(0xFFFBBF24),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Perangkat kamu memiliki pengaturan yang dapat '
              'membahayakan keamanan ujian.\n\n'
              'Aktivitas kamu tetap dipantau secara penuh. '
              'Segera matikan pengaturan tersebut di menu '
              'Pengaturan → Opsi Pengembang.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF97316),
            ),
            child: const Text(
              'Saya Mengerti',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Cek apakah VPN aktif saat screen pertama kali dibuka.
  Future<void> _checkVpn() async {
    final vpn = await KioskController.instance.checkVpn();
    if (vpn == null || !vpn || !mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.vpn_lock, color: Color(0xFFF97316), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'VPN Aktif Terdeteksi',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Perangkat kamu terhubung melalui VPN.\n\n'
          'VPN dapat menyembunyikan aktivitas jaringan dan '
          'mengganggu pemantauan ujian.\n\n'
          'Matikan VPN sebelum memulai ujian.',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 12,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF97316),
            ),
            child: const Text(
              'Saya Mengerti',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Cek apakah perangkat di-root saat screen pertama kali dibuka.
  Future<void> _checkRootStatus() async {
    final root = await KioskController.instance.checkRootStatus();
    if (root == null || !root.isRooted || !mounted) return;

    final signals = <String>[];
    if (root.suBinaryFound) signals.add('• Binary su terdeteksi di sistem');
    if (root.testKeys)      signals.add('• ROM ditandai test-keys (bukan release)');
    if (root.rootAppFound)  signals.add('• Aplikasi root management terinstall');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.gpp_bad, color: Color(0xFFF97316), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Perangkat Terindikasi Root',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              signals.join('\n'),
              style: const TextStyle(
                color: Color(0xFFFBBF24),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Perangkat yang di-root dapat memanipulasi aplikasi ujian '
              'dan membahayakan integritas ujian.\n\n'
              'Aktivitas kamu tetap dipantau secara penuh. '
              'Laporkan ke guru pengawas jika ini bukan perangkatmu.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF97316),
            ),
            child: const Text(
              'Saya Mengerti',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Cek apakah screen cast / mirroring sedang aktif saat screen pertama kali dibuka.
  Future<void> _checkScreenCast() async {
    final casting = await KioskController.instance.checkScreenCast();
    if (casting == null || !casting || !mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.cast, color: Color(0xFFF97316), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Screen Cast Terdeteksi',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Perangkat kamu sedang melakukan screen cast atau mirroring '
          'ke layar lain.\n\n'
          'Matikan screen cast sebelum memulai ujian. '
          'Aktivitas kamu tetap dipantau secara penuh.',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 12,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF97316),
            ),
            child: const Text(
              'Saya Mengerti',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Cek accessibility service pihak ketiga yang aktif saat screen pertama kali aktif.
  Future<void> _checkAccessibilityServices() async {
    final services = await KioskController.instance.checkAccessibilityServices();
    if (services == null || services.isEmpty || !mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.accessibility_new, color: Color(0xFFF97316), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Layanan Aksesibilitas Aktif',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Layanan berikut terdeteksi aktif di perangkat kamu:',
              style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            ...services.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.circle, color: Color(0xFFF97316), size: 6),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s,
                        style: const TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Layanan aksesibilitas dapat membaca isi layar dan '
              'mengganggu integritas ujian.\n\n'
              'Matikan layanan tersebut melalui Pengaturan → '
              'Aksesibilitas sebelum memulai ujian.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF97316),
            ),
            child: const Text(
              'Saya Mengerti',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Dipanggil oleh KioskController saat native mendeteksi pelanggaran (split-screen, dll.)
  void _onNativeViolation(String reason) {
    if (_blockSent || !mounted) return;
    if (_wifiSettingsActive) return;
    _blockSent = true;
    _doBlockStudent(violationReason: reason);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KioskController.instance.removeViolationListener(_onNativeViolation);
    _blockTimer?.cancel();
    _pingTimer?.cancel();
    _startupNoticeRetryTimer?.cancel();
    super.dispose();
  }

  // ─── App Lifecycle: deteksi minimize / background ─────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
    // inactive (notification bar, incoming call, dll.) → tidak ada aksi
  }

  /// Dipanggil saat app benar-benar hilang dari layar (paused).
  /// Membedakan dua kasus:
  ///   - Layar MATI (screen timeout / power button): siswa meletakkan HP → tidak blokir
  ///   - Layar HIDUP tapi app diminimize: siswa pindah app → mulai timer blokir
  Future<void> _onAppPaused() async {
    if (_blockSent) return;
    if (_wifiSettingsActive) return;
    if (_blockTimer != null && _blockTimer!.isActive) return;
    _backgroundedAt = DateTime.now();

    final screenOn = await _isScreenInteractive();
    if (!screenOn) {
      // Layar mati — siswa kemungkinan sedang mengerjakan soal (tidak minimize)
      _screenWasOff = true;
      return;
    }

    // Layar menyala tapi app diminimize → siswa pindah ke app lain
    _screenWasOff = false;

    // Dalam grace period 10 menit: jangan mulai timer suspend.
    if (KioskController.instance.isInGracePeriod) return;

    _blockTimer = Timer(
      const Duration(seconds: AppConfig.backgroundBlockTimeout),
      () async {
        // Cek ulang grace period saat timer fired — bisa saja masih dalam 10 menit.
        if (KioskController.instance.isInGracePeriod) {
          _blockSent = false;
          return;
        }
        _blockSent = true;
        await _doBlockStudent();
      },
    );
  }

  /// Cek apakah layar sedang menyala dan interaktif via native Android.
  Future<bool> _isScreenInteractive() async {
    try {
      final result = await const MethodChannel(AppConfig.lockdownChannel)
          .invokeMethod<bool>('isScreenInteractive');
      return result ?? true; // default aman: anggap layar hidup
    } catch (_) {
      return true;
    }
  }

  Future<void> _onAppResumed() async {
    _blockTimer?.cancel();
    _clearClipboard();
    final wasScreenOff = _screenWasOff;
    _screenWasOff = false;

    if (_blockSent) return;

    // Kembali dari WiFi settings — reset flag, tidak ada penalti
    if (_wifiSettingsActive) {
      _wifiSettingsActive = false;
      _backgroundedAt = null;
      return;
    }

    // Layar mati tadi → siswa meletakkan HP
    // Tidak ada penalti kecuali durasi melebihi batas (45 menit)
    if (wasScreenOff) {
      if (_backgroundedAt != null) {
        final offSec = DateTime.now().difference(_backgroundedAt!).inSeconds;
        _backgroundedAt = null;
        if (offSec >= AppConfig.screenOffAutoBlockSec) {
          _blockSent = true;
          await _doBlockStudent(violationReason: 'screen_off_timeout');
          return;
        }
      } else {
        _backgroundedAt = null;
      }
      return;
    }

    if (_backgroundedAt == null) return;

    // Cek apakah siswa masih login di Moodle saat kembali
    final loggedIn = await _isMoodleLoggedIn();
    if (!loggedIn) {
      _backgroundedAt = null;
      return;
    }

    final elapsed = DateTime.now().difference(_backgroundedAt!).inSeconds;
    _backgroundedAt = null;

    if (elapsed <= 0) return;

    if (_blockSent || elapsed >= AppConfig.backgroundBlockTimeout) {
      // Dalam grace period 10 menit: log saja, jangan blokir.
      if (KioskController.instance.isInGracePeriod) {
        _blockSent = false;
        return;
      }
      // Timer sudah tembak atau durasi melewati batas — blokir
      if (!_blockSent) {
        _blockSent = true;
        await _doBlockStudent();
      }
    } else if (mounted) {
      // Kembali sebelum batas — peringatan saja
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Peringatan: Aplikasi tidak aktif selama $elapsed detik. '
            'Keluar lebih dari ${AppConfig.backgroundBlockTimeout} detik '
            'akan memblokir akun Anda.',
          ),
          backgroundColor: const Color(0xFFB45309),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ─── Block & Overlay logic ────────────────────────────────────────────────

  Future<void> _doBlockStudent({String violationReason = 'exit_during_browser'}) async {
    final userId = await _getEffectiveUserId();

    // Browser mode: cukup logout, TIDAK suspend akun.
    // Suspend hanya dilakukan oleh ExamScreen saat siswa keluar di tengah kuis aktif.
    _pingTimer?.cancel();

    if (userId > 0) {
      try {
        ExamService.sendBrowserHeartbeat(userId: userId, active: false).ignore();
      } catch (_) {}
    }

    await AuthService.saveBlockedStatus(false);
    await AuthService.logout();

    if (!mounted) return;
    KioskController.instance.unlock();
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  /// Coba dapatkan userId: dari native cache, lalu dari AuthService, lalu dari WebView M.cfg.
  Future<int> _getEffectiveUserId() async {
    if (_cachedUserId > 0) return _cachedUserId;
    final nativeId = await AuthService.getUserId();
    if (nativeId > 0) {
      _cachedUserId = nativeId;
      return nativeId;
    }
    // Fallback: ambil dari session Moodle di WebView
    if (_webController != null) {
      try {
        final result = await _webController!.evaluateJavascript(
          source:
              r'(typeof M !== "undefined" && M.cfg && M.cfg.userid) ? M.cfg.userid : 0',
        );
        if (result is int && result > 0) {
          _cachedUserId = result;
          return result;
        }
        if (result is double && result > 0) {
          _cachedUserId = result.toInt();
          return _cachedUserId;
        }
      } catch (_) {}
    }
    return 0;
  }

  // ─── Cek login Moodle via WebView ─────────────────────────────────────────

  /// Cek apakah siswa masih login di Moodle.
  /// Metode 1 (URL): jika URL bukan halaman login → dianggap login.
  /// Metode 2 (DOM): fallback cek class 'loggedin' di body (tergantung tema).
  Future<bool> _isMoodleLoggedIn() async {
    if (_webController == null) return false;
    try {
      // Cek URL terlebih dahulu — paling andal
      final uri = await _webController!.getUrl();
      final url = uri?.toString() ?? '';
      if (url.isNotEmpty) {
        // Halaman login = belum login
        if (url.contains('/login/index.php') || url.contains('/login/logout.php')) {
          return false;
        }
        // URL Moodle selain login = sudah login
        if (url.startsWith(AppConfig.moodleUrl)) return true;
      }
      // Fallback: cek DOM class (beberapa tema tidak punya class ini)
      final result = await _webController!.evaluateJavascript(source: r'''
        (function() {
          var body = document.body;
          if (!body) return false;
          return body.classList.contains('loggedin') &&
                 !body.classList.contains('notloggedin');
        })();
      ''');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  // ─── Logout Moodle dulu sebelum keluar ────────────────────────────────────

  Future<void> _handleExit() async {
    final fetch = await KioskController.instance.fetchExitPassword();

    if (!fetch.success) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tidak dapat memuat pengaturan password keluar. '
            'Periksa koneksi internet atau pastikan plugin Moodle sudah diperbarui, lalu coba lagi.',
          ),
          backgroundColor: Color(0xFFD97706),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    if (fetch.password.isEmpty) {
      await KioskController.instance.unlock();
      await SystemNavigator.pop();
      return;
    }

    if (!mounted) return;
    final pwdOk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ExitPasswordDialog(),
    );

    if (pwdOk == null) return;

    if (!pwdOk) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Kata sandi salah. Coba lagi.',
                  style: TextStyle(fontSize: 13)),
            ],
          ),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // Keluar normal: hapus flag blokir lokal, hentikan ping, logout sesi
    await AuthService.saveBlockedStatus(false);
    _pingTimer?.cancel();
    if (_cachedUserId > 0) {
      ExamService.sendBrowserHeartbeat(userId: _cachedUserId, active: false).ignore();
    }
    await AuthService.logout();
    _autoUsername = '';
    _autoPassword = '';
    await KioskController.instance.unlock();
    await SystemNavigator.pop();
  }

  Future<void> _openWifiSettings() async {
    _wifiSettingsActive = true;
    try {
      await const MethodChannel('com.dosman.ujian/lockdown')
          .invokeMethod('openWifiSettings');
    } catch (_) {}
  }

  void _showPetunjuk() {
    final items = <List<String>>[
      ['🔒', 'Aplikasi terkunci — kamu tidak dapat keluar tanpa izin guru'],
      ['📵', 'Dilarang membuka atau beralih ke aplikasi lain'],
      ['📋', 'Dilarang menyalin atau memotong teks'],
      ['👁️', 'Aktivitas dipantau guru secara real-time'],
      ['⏸️', 'Guru dapat menjeda atau memblokir sesi kapan saja'],
      ['🚪', 'Keluar aplikasi hanya dengan password dari guru'],
      ['🤚', 'Jika ada kendala teknis, angkat tangan dan beritahu guru'],
    ];

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: const Color(0xFF1E293B),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.info_outline,
                        color: Color(0xFF60A5FA), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Petunjuk Ujian',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: const Icon(Icons.close,
                        color: Colors.white38, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(color: Colors.white12),
              const SizedBox(height: 12),
              ...items.map((item) => Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item[0],
                            style: const TextStyle(fontSize: 15)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(item[1],
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white70,
                                  height: 1.45)),
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
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Mengerti',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavbar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0A1628), Color(0xFF0F2044), Color(0xFF1A3560)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2563EB), width: 2),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // ── Baris 1: Logo + Nama App + Tombol ────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Logo bulat dengan bayangan
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2563EB).withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(2),
                  child: Image.asset('assets/logo_sekolah.png', fit: BoxFit.contain),
                ),
                const SizedBox(width: 9),

                // Nama aplikasi
                const Text(
                  'Dosman Exam',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),

                const Spacer(),

                // Tombol Petunjuk
                _navBtn(
                  icon: Icons.help_outline_rounded,
                  label: 'Petunjuk',
                  onTap: _showPetunjuk,
                ),
                const SizedBox(width: 6),

                // Tombol WiFi
                _navBtn(
                  icon: Icons.wifi_rounded,
                  label: 'WiFi',
                  onTap: _openWifiSettings,
                ),
              ],
            ),
          ),

          // ── Baris 2: Nama sekolah rata tengah ────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 5, bottom: 6),
            child: Row(
              children: [
                // Garis kiri
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(left: 12, right: 8),
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, const Color(0xFF3B82F6).withValues(alpha: 0.4)],
                      ),
                    ),
                  ),
                ),
                // Teks sekolah
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.school_rounded,
                      size: 11,
                      color: const Color(0xFF60A5FA).withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'SMAN 1 GIANYAR',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF93C5FD),
                        letterSpacing: 2.2,
                      ),
                    ),
                  ],
                ),
                // Garis kanan
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(left: 8, right: 12),
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [const Color(0xFF3B82F6).withValues(alpha: 0.4), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        ],
      ),
    );
  }

  Widget _navBtn({
    required IconData icon,
    required String    label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: danger
              ? const Color(0x22DC2626)
              : Colors.white.withValues(alpha: 0.07),
          border: Border.all(
            color: danger
                ? const Color(0xFFDC2626).withValues(alpha: 0.8)
                : Colors.white.withValues(alpha: 0.2),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: danger ? const Color(0xFFFCA5A5) : Colors.white70,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: danger ? const Color(0xFFFCA5A5) : Colors.white70,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

// ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        // Sembunyikan seluruh UI (termasuk navbar) sampai cek blokir selesai.
        // Ini mencegah siswa menekan tombol navbar saat status blokir belum diketahui.
        body: !_blockCheckDone
            ? const Center(
                child: CircularProgressIndicator(
                  color: Colors.white24,
                  strokeWidth: 2,
                ),
              )
            : Stack(
                children: [
                  // ── Konten utama (navbar + WebView) ────────────────────
                  SafeArea(
                    child: Column(
                      children: [
                        _buildNavbar(),
                        Expanded(
                          child: Stack(children: [
                            InAppWebView(
                              initialUrlRequest: URLRequest(
                                url: WebUri(
                                    '${AppConfig.moodleUrl}/login/index.php'),
                              ),
                              initialSettings: InAppWebViewSettings(
                                userAgent: AppConfig.examBrowserUserAgent,
                                javaScriptEnabled: true,
                                domStorageEnabled: true,
                                useShouldOverrideUrlLoading: true,
                                mediaPlaybackRequiresUserGesture: false,
                                allowsInlineMediaPlayback: true,
                                transparentBackground: false,
                                disableContextMenu: true,
                                disableLongPressContextMenuOnLinks: true,
                              ),
                              onReceivedServerTrustAuthRequest: (controller, challenge) async {
                                final host = challenge.protectionSpace.host;
                                if (host == '36.93.15.146' || host == 'lms.sman1-gianyar.sch.id') {
                                  return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
                                }
                                return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL);
                              },
                              onWebViewCreated: (ctrl) {
                                _webController = ctrl;
                              },
                              onLoadStart: (ctrl, url) {
                                if (mounted) setState(() => _isLoading = true);
                              },
                              onLoadStop: (ctrl, url) async {
                                if (mounted) setState(() => _isLoading = false);

                                // Auto-login: isi form Moodle otomatis jika halaman login muncul
                                final urlStr = url?.toString() ?? '';
                                if (urlStr.contains('/login/index.php') &&
                                    _autoUsername.isNotEmpty &&
                                    _autoPassword.isNotEmpty) {
                                  await ctrl.evaluateJavascript(source: '''
(function() {
  var u   = document.getElementById('username');
  var p   = document.getElementById('password');
  var btn = document.getElementById('loginbtn');
  if (u && p && btn) {
    u.value = ${jsonEncode(_autoUsername)};
    p.value = ${jsonEncode(_autoPassword)};
    btn.click();
  }
})();
''');
                                }

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
    document.body.style.webkitUserSelect  = 'none';
    document.body.style.userSelect        = 'none';
    document.body.style.webkitTouchCallout = 'none';
  }

  // Auto-klik "Log out" jika muncul konfirmasi "already logged in"
  var bodyText = document.body ? document.body.innerText : '';
  if (bodyText.indexOf('already logged in') !== -1 ||
      bodyText.indexOf('sudah masuk') !== -1) {
    var btns = document.querySelectorAll('input[type="submit"], button[type="submit"], button');
    for (var i = 0; i < btns.length; i++) {
      var label = (btns[i].value || btns[i].textContent || '').toLowerCase().trim();
      if (label.indexOf('log out') !== -1 || label === 'logout' || label === 'keluar') {
        btns[i].click();
        break;
      }
    }
  }
})();
''');
                              },
                              shouldOverrideUrlLoading: (ctrl, action) async {
                                final host =
                                    action.request.url?.host ?? '';
                                if (host.isEmpty) {
                                  return NavigationActionPolicy.ALLOW;
                                }
                                if (AppConfig.allowedHosts
                                    .any((h) => host.contains(h))) {
                                  return NavigationActionPolicy.ALLOW;
                                }
                                return NavigationActionPolicy.CANCEL;
                              },
                            ),
                            if (_isLoading)
                              const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFF2563EB),
                                  strokeWidth: 2.5,
                                ),
                              ),
                          ]),
                        ),
                      ],
                    ),
                  ),

                  // Tombol Keluar — pojok kiri bawah (floating)
                  Positioned(
                    bottom: MediaQuery.of(context).padding.bottom + 16,
                    left: 16,
                    child: FloatingActionButton.extended(
                      heroTag: 'locked_exit_btn',
                      onPressed: _handleExit,
                      backgroundColor: Colors.red.withValues(alpha: 0.15),
                      foregroundColor: Colors.red.withValues(alpha: 0.85),
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                            color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      icon: const Icon(Icons.exit_to_app_rounded, size: 16),
                      label: const Text(
                        'Keluar',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
