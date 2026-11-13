import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';

class DeviceBlockedScreen extends StatefulWidget {
  const DeviceBlockedScreen({
    super.key,
    required this.reason,
    this.blockedAt = 0,
  });
  final String reason;
  final int blockedAt;

  @override
  State<DeviceBlockedScreen> createState() => _DeviceBlockedScreenState();
}

class _DeviceBlockedScreenState extends State<DeviceBlockedScreen> {
  Timer? _pollTimer;
  String _deviceId = '';
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _deviceId = await DeviceService.getDeviceId();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _poll());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    _pollTimer?.cancel();
    _pollTimer = null;
    _deviceId = '';
    await _init();
    if (!mounted) return;
    // Cek langsung tanpa menunggu interval berikutnya
    await _poll();
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_deviceId.isEmpty || !mounted) return;
    final result = await ExamService.checkDevice(_deviceId);
    if (!mounted) return;
    if (!result.blocked) {
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 48, 32, 88),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ── Ikon ───────────────────────────────────────────────────
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: const Color(0xFF7F1D1D).withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.phonelink_lock_rounded,
                          color: Color(0xFFEF4444),
                          size: 52,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Judul ──────────────────────────────────────────────────
                    const Text(
                      'AKSES DIBLOKIR',
                      style: TextStyle(
                        color: Color(0xFFEF4444),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Alasan ─────────────────────────────────────────────────
                    Text(
                      widget.reason.isNotEmpty
                          ? widget.reason
                          : 'Perangkat ini telah diblokir karena terdeteksi pelanggaran ujian.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Info box ───────────────────────────────────────────────
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.support_agent_rounded,
                              color: Color(0xFF64748B), size: 22),
                          SizedBox(height: 10),
                          Text(
                            'Hubungi pengawas ujian untuk informasi lebih lanjut.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Jika blokir sudah dibuka oleh pengawas, '
                            'aplikasi akan otomatis diarahkan ke halaman utama.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 11,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Status polling ─────────────────────────────────────────
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Color(0xFF475569),
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Memantau status dari server...',
                          style: TextStyle(
                              color: Color(0xFF475569), fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
          ),
          // ── Tombol Keluar — pojok kiri bawah ─────────────────────────────
          Positioned(
            bottom: bottomPad + 16,
            left: 16,
            child: FloatingActionButton.extended(
              heroTag: 'btn_keluar',
              onPressed: () async {
                if (defaultTargetPlatform == TargetPlatform.iOS) {
                  await AuthService.logout();
                  await KioskController.instance.unlock();
                  if (!context.mounted) return;
                  Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
                } else {
                  await SystemNavigator.pop();
                }
              },
              backgroundColor: Colors.red.withValues(alpha: 0.15),
              foregroundColor: Colors.red.withValues(alpha: 0.85),
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
              ),
              icon: const Icon(Icons.exit_to_app_rounded, size: 16),
              label: const Text(
                'Keluar',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // ── Tombol Muat Ulang — pojok kanan bawah ────────────────────────
          Positioned(
            bottom: bottomPad + 16,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'btn_refresh',
              onPressed: _refreshing ? null : _refresh,
              backgroundColor: const Color(0xFF1E293B),
              foregroundColor: const Color(0xFF94A3B8),
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF94A3B8),
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: Text(
                _refreshing ? 'Memuat...' : 'Muat Ulang',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
