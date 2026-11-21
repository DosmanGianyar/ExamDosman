// ===========================
// Overlay penuh: kiosk aktif tetapi aplikasi belum dalam mode screen pin / Guided Access.
// Memblokir seluruh layar agar siswa tidak bisa mengerjakan kuis sebelum disematkan/dikunci.
// Juga menampilkan overlay bawah sementara khusus Android untuk menutup toast pin.
// ===========================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/kiosk_controller.dart';
import 'exit_password_dialog.dart';

/// Bungkus konten app; tampilkan banner jika kiosk aktif dan pin/Guided Access belum aktif.
class PinReminderLayer extends StatefulWidget {
  final Widget child;

  const PinReminderLayer({required this.child, super.key});

  @override
  State<PinReminderLayer> createState() => _PinReminderLayerState();
}

class _PinReminderLayerState extends State<PinReminderLayer>
    with WidgetsBindingObserver {
  final _kiosk = KioskController.instance;
  Timer? _pollTimer;
  Timer? _maskTimer;
  bool _pinned = true;
  bool _inStartupGrace = false;
  bool _showBottomMask = false;
  bool _wasActive = false;
  bool _screenPinningEnabled = true;
  bool _showingExitDialog = false;
  bool _exitBusy = false;
  String _exitError = '';
  int _pinRetryCount = 0;

  @override
  void initState() {
    super.initState();
    _wasActive = _kiosk.active;
    _kiosk.addListener(_onKioskChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPolling());
  }

  @override
  void dispose() {
    _kiosk.removeListener(_onKioskChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _maskTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_kiosk.active &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused)) {
      _triggerBottomMask();
    }
  }

  void _onKioskChanged() {
    if (_kiosk.isReviewer || !_kiosk.active) {
      _maskTimer?.cancel();
      if (mounted && _showBottomMask) {
        setState(() => _showBottomMask = false);
      }
    } else if (!_wasActive && defaultTargetPlatform == TargetPlatform.android) {
      _triggerBottomMask();
    }
    _wasActive = _kiosk.active;
    _syncPolling();
  }

  /// Tampilkan overlay bawah selama 5 detik untuk menutup toast Android (khusus Android).
  void _triggerBottomMask() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _maskTimer?.cancel();
    if (mounted) setState(() => _showBottomMask = true);
    _maskTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showBottomMask = false);
    });
  }

  void _syncPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (kIsWeb || !isMobile || _kiosk.isReviewer || !_kiosk.active) {
      if (mounted &&
          (!_pinned ||
              _inStartupGrace ||
              _pinRetryCount != 0 ||
              _exitError.isNotEmpty)) {
        setState(() {
          _pinned = true;
          _inStartupGrace = false;
          _pinRetryCount = 0;
          _exitError = '';
        });
      }
      return;
    }
    _pollPinned();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _pollPinned();
    });
  }

  Future<void> _pollPinned() async {
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (kIsWeb || !isMobile || _kiosk.isReviewer) {
      if (mounted && !_pinned) setState(() => _pinned = true);
      return;
    }
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final ok = defaultTargetPlatform == TargetPlatform.iOS
        ? await _kiosk.isGuidedAccessActive()
        : await _kiosk.isLockTaskPinned();
    bool pinningEnabled = _screenPinningEnabled;
    if (isAndroid && !ok) {
      pinningEnabled = await _kiosk.isScreenPinningEnabled();
    }
    if (!mounted) return;
    final inGrace = _kiosk.isInPinStartupGrace;
    if (ok != _pinned ||
        inGrace != _inStartupGrace ||
        pinningEnabled != _screenPinningEnabled ||
        (ok && (_pinRetryCount != 0 || _exitError.isNotEmpty))) {
      setState(() {
        _pinned = ok;
        _inStartupGrace = inGrace;
        _screenPinningEnabled = pinningEnabled;
        if (ok) {
          _pinRetryCount = 0;
          _exitError = '';
        }
      });
    }
  }

  Widget _stepRow(String num, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: Text(
            num,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onTapPinAgain() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _pollPinned();
      if (!_pinned && mounted) {
        try {
          await const MethodChannel(AppConfig.lockdownChannel)
              .invokeMethod('openAppSettings');
        } catch (_) {}
      }
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      _triggerBottomMask();
    }
    if (mounted) {
      setState(() {
        _pinRetryCount++;
        _exitError = '';
      });
    }
    await _kiosk.requestScreenPinAgain();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) await _pollPinned();
  }

  Future<void> _handleExitWithPassword() async {
    if (_exitBusy) return;
    setState(() {
      _exitBusy = true;
      _exitError = '';
    });

    try {
      final fetch = await _kiosk.fetchExitPassword();
      if (!mounted) return;

      if (!fetch.success) {
        setState(() {
          _exitError = 'Tidak dapat memverifikasi password keluar. Periksa koneksi Wi-Fi.';
        });
        return;
      }

      if (fetch.password.isNotEmpty) {
        final navCtx = _kiosk.rootNavigatorKey?.currentContext;
        if (navCtx == null || !navCtx.mounted) {
          setState(() {
            _exitError = 'Gagal membuka dialog kata sandi. Coba lagi.';
          });
          return;
        }
        setState(() => _showingExitDialog = true);
        bool? pwdOk;
        try {
          pwdOk = await showDialog<bool>(
            context: navCtx,
            barrierDismissible: false,
            barrierColor: const Color(0xFF0F172A),
            builder: (_) => const ExitPasswordDialog(),
          );
        } finally {
          if (mounted) setState(() => _showingExitDialog = false);
        }
        if (pwdOk != true) {
          if (pwdOk == false && mounted) {
            setState(() => _exitError = 'Kata sandi salah. Coba lagi.');
          }
          return;
        }
      }

      await _kiosk.unlock();
      await AuthService.logout();
      _kiosk.rootNavigatorKey?.currentState?.pushNamedAndRemoveUntil(
        '/login',
        (route) => false,
      );
    } finally {
      if (mounted) setState(() => _exitBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (kIsWeb || !isMobile || _kiosk.isReviewer) {
      return widget.child;
    }

    final showBanner = _kiosk.active &&
        !_pinned &&
        !_inStartupGrace &&
        !_showingExitDialog;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final showPinSettingsBtn =
        !isIOS && (!_screenPinningEnabled || _pinRetryCount >= 1);

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        widget.child,

        if (showBanner)
          Positioned.fill(
            child: Material(
              color: const Color(0xFF1E3A8A),
              child: Stack(
                children: [
                  SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 24, 28, 88),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Icon(
                                isIOS ? Icons.lock_clock_rounded : Icons.push_pin_rounded,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              isIOS ? 'Mode Ujian Belum Terkunci' : 'Aplikasi Belum Disematkan',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              isIOS
                                  ? 'Aplikasi harus dalam mode Akses Terpandu (Guided Access) agar ujian dapat berjalan dengan aman.'
                                  : 'Aplikasi harus dalam mode sematan layar agar ujian dapat berjalan dengan aman. '
                                      'Konten kuis tidak bisa diakses sebelum aplikasi disematkan.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 13,
                                height: 1.6,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              ),
                              child: Column(
                                children: isIOS
                                    ? [
                                        _stepRow('1', 'Aktifkan Pengaturan > Aksesibilitas > Akses Terpandu (Guided Access)'),
                                        const SizedBox(height: 10),
                                        _stepRow('2', 'Tekan tombol Samping (Power) / Home 3 kali dengan cepat'),
                                        const SizedBox(height: 10),
                                        _stepRow('3', 'Ketuk "Mulai" di pojok kanan atas untuk mengunci layar ujian'),
                                      ]
                                    : [
                                        _stepRow('1', 'Ketuk "Sematkan Ulang" di bawah'),
                                        const SizedBox(height: 10),
                                        _stepRow('2', 'Ikuti petunjuk sematan yang muncul di layar perangkat'),
                                        const SizedBox(height: 10),
                                        _stepRow('3', 'Jika fitur Semat Layar nonaktif di HP, buka Pengaturan Semat Layar lalu aktifkan'),
                                      ],
                              ),
                            ),
                            if (_exitError.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDC2626).withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFFCA5A5)),
                                ),
                                child: Text(
                                  _exitError,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton.icon(
                                onPressed: _onTapPinAgain,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: const Color(0xFF1E3A8A),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                icon: Icon(
                                  isIOS ? Icons.lock_outline_rounded : Icons.push_pin_rounded,
                                  size: 20,
                                ),
                                label: Text(
                                  isIOS ? 'Buka Pengaturan iPhone' : 'Sematkan Ulang',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            if (showPinSettingsBtn) ...[
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                height: 48,
                                child: OutlinedButton.icon(
                                  onPressed: () => _kiosk.openScreenPinningSettings(),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: BorderSide(
                                      color: Colors.white.withValues(alpha: 0.55),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  icon: const Icon(Icons.settings_rounded, size: 18),
                                  label: const Text(
                                    'Buka Pengaturan Semat Layar',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Tombol Keluar — wajib verifikasi password keluar
                  Positioned(
                    bottom: bottomPadding + 16,
                    left: 16,
                    child: FloatingActionButton.extended(
                      heroTag: 'pin_exit_btn',
                      onPressed: _exitBusy ? null : _handleExitWithPassword,
                      backgroundColor: Colors.red.withValues(alpha: 0.18),
                      foregroundColor: Colors.red.shade100,
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: Colors.red.withValues(alpha: 0.4),
                        ),
                      ),
                      icon: const Icon(Icons.exit_to_app_rounded, size: 16),
                      label: Text(
                        _exitBusy ? 'Memverifikasi...' : 'Keluar',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Overlay bawah: tutup toast Android "To unpin this app..." selama 5 detik (khusus Android)
        if (_showBottomMask && defaultTargetPlatform == TargetPlatform.android)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 100 + bottomPadding,
              color: const Color(0xFF0F172A),
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFFBBF24), size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Siswa tidak diperkenankan keluar dari aplikasi selama ujian berlangsung. '
                      'Keluar dari aplikasi akan menyebabkan perangkat Anda diblokir secara otomatis.',
                      style: TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 12,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
