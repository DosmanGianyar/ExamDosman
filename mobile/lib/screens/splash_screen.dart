import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'blocked_screen.dart';
import 'dnd_permission_screen.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';


class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double>   _fadeAnim;
  late Animation<double>   _scaleAnim;

  @override
  void initState() {
    super.initState();

    // Animasi fade + scale logo
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeIn,
    );
    _scaleAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutBack),
    );

    _animController.forward();

    // Cek auth setelah animasi selesai
    Future.delayed(const Duration(milliseconds: 1400), _checkAuth);
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  // ─── Cek apakah user sudah login ────────────────────────────────────────────

  Future<void> _checkAuth() async {
    if (!mounted) return;

    try {
      // Restore token ke ApiService dari secure storage
      final hasSession = await AuthService.restoreSession();

      if (!hasSession) {
        // Belum login → ke halaman login
        _navigate('/login');
        return;
      }

      // Verifikasi token masih valid dengan call get_site_info
      try {
        await ApiService.getSiteInfo();
        // Token valid → lanjutkan
        ExamService.pingAppLogin();
        _navigate(defaultTargetPlatform == TargetPlatform.android ? '/courses' : '/home');
      } on TokenExpiredException {
        // Token kedaluwarsa
        await AuthService.logout();
        _navigate('/login');
      }
    } catch (_) {
      // getSiteInfo bisa gagal saat akun di-suspend (ApiException, bukan TokenExpiredException).
      // Cek status blokir terlebih dahulu agar siswa ter-suspend+terblokir
      // diarahkan ke BlockedScreen, bukan terjebak di halaman login.
      final userId = await AuthService.getUserId();
      if (userId > 0) {
        try {
          final blocked = await ExamService.checkBlocked(userId: userId);
          if (blocked.reachable && blocked.blocked && mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => BlockedScreen(
                  userId: userId,
                  reason: blocked.reason,
                ),
              ),
            );
            return;
          }
        } catch (_) {}
      }
      _navigate('/login');
    }
  }

  Future<void> _navigate(String route) async {
    if (!mounted) return;
    // Cek izin DND di Android sebelum masuk ke login/home.
    // DndPermissionScreen akan navigate ke [route] setelah izin diberikan.
    if (defaultTargetPlatform == TargetPlatform.android) {
      final granted = await KioskController.instance.isDndPermissionGranted();
      if (!granted && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DndPermissionScreen(nextRoute: route),
          ),
        );
        return;
      }
    }
    if (mounted) Navigator.of(context).pushReplacementNamed(route);
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end:   Alignment.bottomRight,
            colors: [
              Color(0xFF1E3A5F),
              Color(0xFF2563EB),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Logo & Judul ──────────────────────────────────────────────
              Expanded(
                child: Center(
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: ScaleTransition(
                      scale: _scaleAnim,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Logo sekolah
                          Container(
                            width:  140,
                            height: 140,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 20,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.all(10),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.asset(
                                'assets/logo_sekolah.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Nama aplikasi
                          const Text(
                            'Dosman Ujian',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),

                          const SizedBox(height: 8),

                          // Subtitle
                          Text(
                            'Sistem Ujian Anti-Kecurangan',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.75),
                              fontWeight: FontWeight.w400,
                            ),
                          ),

                          const SizedBox(height: 6),

                          // Nama sekolah
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              'SMAN 1 GIANYAR',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.9),
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Loading indicator + versi ─────────────────────────────────
              Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: Column(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'v1.0.0',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
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
