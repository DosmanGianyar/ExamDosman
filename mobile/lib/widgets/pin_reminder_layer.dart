// ===========================
// Overlay penuh: kiosk aktif tetapi aplikasi belum dalam mode screen pin / assessment session.
// Memblokir seluruh layar agar siswa tidak bisa mengerjakan kuis sebelum disematkan/dikunci.
// Juga menampilkan overlay bawah sementara khusus Android untuk menutup toast pin.
// ===========================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kiosk_controller.dart';

/// Bungkus konten app; menampel banner jika kiosk aktif dan pin/assessment belum aktif.
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
  bool _showBottomMask = false;
  bool _wasActive = false;

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
    // Khusus Android: setiap kali Home ditekan saat pinned → Android tampilkan toast → tutup dengan mask
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_kiosk.active &&
        (state == AppLifecycleState.inactive ||
         state == AppLifecycleState.paused)) {
      _triggerBottomMask();
    }
  }

  void _onKioskChanged() {
    // Akun reviewer tidak pernah menampilkan mask atau reminder
    if (_kiosk.isReviewer) {
      if (mounted && !_pinned) setState(() => _pinned = true);
      return;
    }

    // Tampilkan mask saat kiosk baru aktif di Android (login berhasil → enterLockTask)
    if (_kiosk.active && !_wasActive && defaultTargetPlatform == TargetPlatform.android) {
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
    if (_kiosk.isReviewer || !_kiosk.active) {
      if (mounted && !_pinned) setState(() => _pinned = true);
      return;
    }
    _pollPinned();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _pollPinned();
    });
  }

  Future<void> _pollPinned() async {
    if (_kiosk.isReviewer) {
      if (mounted && !_pinned) setState(() => _pinned = true);
      return;
    }
    final ok = await _kiosk.isLockTaskPinned();
    if (!mounted) return;
    if (ok != _pinned) setState(() => _pinned = ok);
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
          child: Text(num,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13,
                  height: 1.4)),
        ),
      ],
    );
  }

  Future<void> _onTapPinAgain() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      _triggerBottomMask(); // tutup toast re-pin di Android
    }
    await _kiosk.requestScreenPinAgain();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) await _pollPinned();
  }

  @override
  Widget build(BuildContext context) {
    // Reviewer bypass secara absolut: tidak pernah menampilkan overlay penahan
    if (_kiosk.isReviewer) {
      return widget.child;
    }

    final showBanner = _kiosk.active && !_pinned;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        widget.child,

        // Overlay penuh: blokir seluruh layar jika kiosk aktif tapi belum disematkan/dikunci
        if (showBanner)
          Positioned.fill(
            child: Material(
              color: const Color(0xFF1E3A8A),
              child: Stack(
                children: [
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 0, 28, 80),
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
                                ? 'Aplikasi harus dalam mode Akses Terpandu (Guided Access) atau Sesi Penilaian resmi agar ujian dapat berjalan dengan aman.'
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
                                  color: Colors.white.withValues(alpha: 0.15)),
                            ),
                            child: Column(
                              children: isIOS
                                  ? [
                                      _stepRow('1', 'Ketuk "Kunci Mode Ujian" di bawah'),
                                      const SizedBox(height: 10),
                                      _stepRow('2', 'Izinkan sesi ujian saat konfirmasi sistem muncul'),
                                      const SizedBox(height: 10),
                                      _stepRow('3', 'Atau aktifkan Akses Terpandu dengan menekan tombol samping/atas 3 kali'),
                                    ]
                                  : [
                                      _stepRow('1', 'Ketuk "Sematkan Ulang" di bawah'),
                                      const SizedBox(height: 10),
                                      _stepRow('2', 'Ikuti petunjuk sematan yang muncul di layar perangkat'),
                                      const SizedBox(height: 10),
                                      _stepRow('3', 'Jika gagal, tutup aplikasi lalu buka kembali'),
                                    ],
                            ),
                          ),
                          const SizedBox(height: 28),
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
                                isIOS ? 'Kunci Mode Ujian' : 'Sematkan Ulang',
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Tombol Tutup Aplikasi — pojok kiri bawah (floating)
                  Positioned(
                    bottom: bottomPadding + 16,
                    left: 16,
                    child: FloatingActionButton.extended(
                      heroTag: 'pin_exit_btn',
                      onPressed: () => SystemNavigator.pop(),
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
                        style:
                            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
