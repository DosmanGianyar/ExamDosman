// ===========================
// DOSMAN UJIAN - Login Screen
// ===========================

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';
import '../services/device_service.dart';
import '../config/app_config.dart';
import '../utils/app_version.dart';

import 'device_blocked_screen.dart';
import '../widgets/qr_login_scanner_dialog.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
  with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _formKey   = GlobalKey<FormState>();
  final _userCtrl  = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _userFocus = FocusNode();
  final _passFocus = FocusNode();

  bool   _isLoading    = false;
  bool   _obscurePass  = true;
  String _errorMsg     = '';
  bool   _isSuspended  = false;

  late AnimationController _animCtrl;
  late Animation<double>   _fadeAnim;
  late Animation<Offset>   _slideAnim;

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();
    _checkSuspendedByAdminFlag();
  }

  Future<void> _checkSuspendedByAdminFlag() async {
    final wasSuspended = await AuthService.getSuspendedByAdmin();
    if (wasSuspended && mounted) {
      await AuthService.saveSuspendedByAdmin(false);
      setState(() => _isSuspended = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  // Deteksi lifecycle keluar aplikasi
  DateTime? _backgroundTime;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      // App masuk background
      _backgroundTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _backgroundTime != null) {
      // App kembali dari background
      final diff = DateTime.now().difference(_backgroundTime!);
      if (diff.inSeconds > 15) {
        // Kirim request ke backend untuk catat logout
        final username = await AuthService.getUsername();
        await ApiService.logoutActivity(username);
      }
      _backgroundTime = null;
    }
  }

  // ─── Login Logic ──────────────────────────────────────────────────────────

  Future<void> _doLogin() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() { _isLoading = true; _errorMsg = ''; });

    try {
      await AuthService.login(_userCtrl.text.trim(), _passCtrl.text);
      if (!mounted) return;

      // Device Binding: daftarkan perangkat ke server.
      // Dibungkus try-catch tersendiri — kegagalan registrasi (timeout / server error)
      // TIDAK boleh memblokir login karena token Moodle sudah berhasil didapat.
      // Hanya redirect ke blocked screen jika server secara eksplisit mengembalikan deviceBlocked=true.
      try {
        final deviceId = await DeviceService.getDeviceId();
        final token = await AuthService.getToken() ?? '';
        if (token.isNotEmpty) {
          final model = await DeviceService.getDeviceModel();
          final regResult = await ExamService.registerDevice(
            deviceId: deviceId,
            token: token,
            platform: DeviceService.platform,
            model: model,
          );
          if (regResult.deviceBlocked && mounted) {
            await AuthService.logout();
            KioskController.instance.unlock();
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (_) => DeviceBlockedScreen(reason: regResult.reason, blockedAt: regResult.blockedAt),
              ),
              (route) => false,
            );
            return;
          }
        }
      } catch (_) {
        // Gagal registrasi perangkat (jaringan lambat, server error) →
        // abaikan dan lanjut login. Siswa tetap bisa masuk.
      }

      ExamService.pingAppLogin(); // daftarkan ke dashboard segera
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } on TokenExpiredException catch (e) {
      _showError(e.message);
    } on ApiException catch (e) {
      _showError(e.message);
      // Cek apakah akun di-suspend (menyebabkan "Invalid login")
      await _checkSuspendStatus(_userCtrl.text.trim());
    } on NetworkException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Terjadi kesalahan: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Buka modal scanner kamera untuk memindai kartu login siswa.
  Future<void> _scanQrCard() async {
    FocusScope.of(context).unfocus();
    final creds = await QrLoginScannerDialog.show(context);
    if (creds == null || !mounted) return;

    final u = creds['username'] ?? '';
    final p = creds['password'] ?? '';
    if (u.isNotEmpty && p.isNotEmpty) {
      _userCtrl.text = u;
      _passCtrl.text = p;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kartu peserta terdeteksi! Memulai login otomatis...'),
          duration: Duration(seconds: 2),
          backgroundColor: Color(0xFF16A34A),
        ),
      );
      _doLogin();
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() { _errorMsg = msg; _isSuspended = false; });
  }

  Future<void> _checkSuspendStatus(String username) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/check_suspend_status.php'
      ).replace(queryParameters: {'username': username});
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        if (data['suspended'] == true && mounted) {
          setState(() => _isSuspended = true);
        }
      }
    } catch (_) {}
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── Background gradient ────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end:   Alignment.bottomRight,
                stops: [0.0, 0.45, 1.0],
                colors: [
                  Color(0xFF0A1628),
                  Color(0xFF0F2044),
                  Color(0xFF1A3565),
                ],
              ),
            ),
          ),

          // ── Decorative circles ─────────────────────────────────────────
          const Positioned(top: -80, right: -60, child: _DecorCircle(size: 260, opacity: 0.06)),
          const Positioned(top: 100, left: -90,  child: _DecorCircle(size: 200, opacity: 0.05)),
          const Positioned(bottom: -60, right: -40, child: _DecorCircle(size: 220, opacity: 0.07)),
          const Positioned(bottom: 120, left: -60,  child: _DecorCircle(size: 160, opacity: 0.04)),

          // ── Dot grid pattern ───────────────────────────────────────────
          const Positioned.fill(child: _DotGrid()),

          // ── Content ────────────────────────────────────────────────────
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: SlideTransition(
                    position: _slideAnim,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 18),
                          _buildVisi(),
                          const SizedBox(height: 18),
                          _buildLoginCard(),
                          const SizedBox(height: 20),
                          _buildFooter(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Column(
      children: [
        // Logo dengan ring emas
        Stack(
          alignment: Alignment.center,
          children: [
            // Ring luar
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const SweepGradient(
                  colors: [
                    Color(0xFFD4A017),
                    Color(0xFFF5C842),
                    Color(0xFFD4A017),
                    Color(0xFF8B6508),
                    Color(0xFFD4A017),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color:      const Color(0xFFD4A017).withValues(alpha: 0.35),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            // Background putih logo
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: ClipOval(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Image.asset(
                    'assets/logo_sekolah.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.school_rounded,
                      size: 40,
                      color: Color(0xFF1E3A5F),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // Nama sekolah
        const Text(
          'SMA NEGERI 1 GIANYAR',
          style: TextStyle(
            color:         Colors.white,
            fontSize:      18,
            fontWeight:    FontWeight.w900,
            letterSpacing: 2.0,
          ),
        ),

        const SizedBox(height: 4),

        // Garis aksen emas
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 28, height: 1.5, color: const Color(0xFFD4A017)),
            const SizedBox(width: 8),
            Text(
              'Gianyar, Bali',
              style: TextStyle(
                color:         Colors.white.withValues(alpha: 0.65),
                fontSize:      12,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            Container(width: 28, height: 1.5, color: const Color(0xFFD4A017)),
          ],
        ),

        const SizedBox(height: 12),

        // Badge Dosman Exam
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1D4ED8), Color(0xFF2563EB)],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color:      const Color(0xFF2563EB).withValues(alpha: 0.40),
                blurRadius: 12,
                offset:     const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, color: Colors.white, size: 13),
              SizedBox(width: 6),
              Text(
                'Dosman Exam',
                style: TextStyle(
                  color:         Colors.white,
                  fontSize:      12,
                  fontWeight:    FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 4),

        Text(
          'Sistem Pengawasan Ujian Online',
          style: TextStyle(
            color:    Colors.white.withValues(alpha: 0.50),
            fontSize: 11,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  // ─── Visi ─────────────────────────────────────────────────────────────────

  Widget _buildVisi() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color:        Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: Colors.white.withValues(alpha: 0.14), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label VISI
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color:        const Color(0xFFD4A017),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'V I S I',
                style: TextStyle(
                  color:         Colors.white.withValues(alpha: 0.85),
                  fontSize:      10,
                  fontWeight:    FontWeight.w800,
                  letterSpacing: 3.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Tanda kutip besar
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '“',
                style: TextStyle(
                  color:    const Color(0xFFD4A017).withValues(alpha: 0.80),
                  fontSize: 36,
                  height:   0.7,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 4),
              const Expanded(
                child: Text(
                  'Insan Cerdas, Sarat Prestasi, Berkarakter, Berbudaya, '
                  'Peduli Lingkungan, dan Berwawasan Global',
                  style: TextStyle(
                    color:     Colors.white,
                    fontSize:  12,
                    fontStyle: FontStyle.italic,
                    height:    1.6,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '”',
              style: TextStyle(
                color:    const Color(0xFFD4A017).withValues(alpha: 0.80),
                fontSize: 36,
                height:   0.7,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Login Card ───────────────────────────────────────────────────────────

  Widget _buildLoginCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(26, 26, 26, 24),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.28),
            blurRadius: 48,
            offset:     const Offset(0, 20),
          ),
          BoxShadow(
            color:      const Color(0xFF2563EB).withValues(alpha: 0.08),
            blurRadius: 20,
            offset:     const Offset(0, 6),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Judul card
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color:        const Color(0xFF2563EB).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.login_rounded,
                    color: Color(0xFF2563EB),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Login Siswa',
                      style: TextStyle(
                        fontSize:   17,
                        fontWeight: FontWeight.w800,
                        color:      Color(0xFF0F172A),
                      ),
                    ),
                    Text(
                      'Masukkan akun Moodle Anda',
                      style: TextStyle(
                        fontSize: 11,
                        color:    Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Divider
            Container(height: 1, color: const Color(0xFFF1F5F9)),

            const SizedBox(height: 20),

            // Error alert
            if (_errorMsg.isNotEmpty) ...[
              _buildErrorAlert(),
              const SizedBox(height: 16),
            ],

            // Username
            _buildFieldLabel('Username', Icons.person_outline_rounded),
            const SizedBox(height: 7),
            _buildUsernameField(),

            const SizedBox(height: 16),

            // Password
            _buildFieldLabel('Password', Icons.lock_outline_rounded),
            const SizedBox(height: 7),
            _buildPasswordField(),

            const SizedBox(height: 24),

            // Tombol Login
            _buildLoginButton(),

            const SizedBox(height: 12),

            // Tombol Scan Kartu Ujian (QR Code)
            _buildScanQrButton(),
          ],
        ),
      ),
    );
  }

  // ─── Sub-widgets ──────────────────────────────────────────────────────────

  Widget _buildFieldLabel(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 13, color: const Color(0xFF64748B)),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            fontSize:   12,
            fontWeight: FontWeight.w700,
            color:      Color(0xFF374151),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorAlert() {
    if (_isSuspended) return _buildSuspendedBanner();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color:        const Color(0xFFFEF2F2),
        border:       Border.all(color: const Color(0xFFFECACA)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMsg,
              style: const TextStyle(
                fontSize: 12,
                color:    Color(0xFFDC2626),
                height:   1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuspendedBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF7F1D1D), Color(0xFFB91C1C)],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color:   const Color(0xFFB91C1C).withValues(alpha: 0.40),
            blurRadius:  12,
            offset:  const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          const Icon(Icons.block_rounded, color: Colors.white, size: 38),
          const SizedBox(height: 10),
          const Text(
            'AKUN ANDA DI-SUSPEND',
            textAlign: TextAlign.center,
            style: TextStyle(
              color:       Colors.white,
              fontSize:    16,
              fontWeight:  FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Akun Anda sedang dinonaktifkan oleh sistem pengawas ujian.\nAnda tidak dapat login sementara akun masih di-suspend.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color:   Color(0xFFFECACA),
              fontSize: 12,
              height:  1.6,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color:         Colors.white.withValues(alpha: 0.15),
              borderRadius:  BorderRadius.circular(10),
              border:        Border.all(color: Colors.white.withValues(alpha: 0.30)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.support_agent_rounded, color: Colors.white, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Hubungi pengawas ruangan atau tim IT kelas untuk membuka akun Anda.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color:      Colors.white,
                      fontSize:   12,
                      fontWeight: FontWeight.w600,
                      height:     1.5,
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

  Widget _buildUsernameField() {
    return TextFormField(
      controller:           _userCtrl,
      focusNode:            _userFocus,
      keyboardType:         TextInputType.text,
      textInputAction:      TextInputAction.next,
      // emailAddress di-nonaktifkan: banyak keyboard Android auto-capitalize
      // atau auto-correct username sehingga login gagal meski password benar.
      autocorrect:          false,
      enableSuggestions:    false,
      textCapitalization:   TextCapitalization.none,
      autofillHints:        const [AutofillHints.username],
      enabled:              !_isLoading,
      style:                const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
      decoration:           _inputDeco(hint: 'username atau email Moodle', icon: Icons.person_outline_rounded),
      onFieldSubmitted:     (_) => _passFocus.requestFocus(),
      validator: (v) => (v == null || v.trim().isEmpty) ? 'Username wajib diisi' : null,
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller:      _passCtrl,
      focusNode:       _passFocus,
      obscureText:     _obscurePass,
      textInputAction: TextInputAction.done,
      autofillHints:   const [AutofillHints.password],
      enabled:         !_isLoading,
      style:           const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
      decoration:      _inputDeco(hint: 'password akun Moodle', icon: Icons.lock_outline_rounded).copyWith(
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePass ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: const Color(0xFF94A3B8),
            size: 18,
          ),
          onPressed: () => setState(() => _obscurePass = !_obscurePass),
        ),
      ),
      onFieldSubmitted: (_) => _doLogin(),
      validator: (v) => (v == null || v.isEmpty) ? 'Password wajib diisi' : null,
    );
  }

  InputDecoration _inputDeco({required String hint, required IconData icon}) {
    return InputDecoration(
      hintText:   hint,
      hintStyle:  const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
      prefixIcon: Icon(icon, color: const Color(0xFF94A3B8), size: 18),
      filled:     true,
      fillColor:  const Color(0xFFF8FAFC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide:   const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide:   const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide:   const BorderSide(color: Color(0xFF2563EB), width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide:   const BorderSide(color: Color(0xFFDC2626), width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide:   const BorderSide(color: Color(0xFFDC2626), width: 2),
      ),
      errorStyle: const TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: _isLoading
              ? null
              : const LinearGradient(
                  colors: [Color(0xFF1D4ED8), Color(0xFF2563EB), Color(0xFF3B82F6)],
                ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: _isLoading
              ? null
              : [
                  BoxShadow(
                    color:      const Color(0xFF2563EB).withValues(alpha: 0.40),
                    blurRadius: 16,
                    offset:     const Offset(0, 6),
                  ),
                ],
        ),
        child: ElevatedButton(
          onPressed: _isLoading ? null : _doLogin,
          style: ElevatedButton.styleFrom(
            backgroundColor:         Colors.transparent,
            disabledBackgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.55),
            foregroundColor:         Colors.white,
            elevation:               0,
            shadowColor:             Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: _isLoading
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Memproses...',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ],
                )
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.login_rounded, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Masuk ke Ujian',
                      style: TextStyle(
                        fontSize:   15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildScanQrButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: _isLoading ? null : _scanQrCard,
        icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
        label: const Text(
          'Pindai Kartu Ujian (QR Code)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF2563EB),
          side: const BorderSide(color: Color(0xFF93C5FD), width: 1.5),
          backgroundColor: const Color(0xFFEFF6FF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  // ─── Footer ───────────────────────────────────────────────────────────────

  Widget _buildFooter() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(width: 40, height: 1, color: Colors.white12),
            const SizedBox(width: 10),
            Text(
              'Dosman Exam © SMAN 1 Gianyar',
              style: TextStyle(
                fontSize: 10,
                color:    Colors.white.withValues(alpha: 0.35),
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(width: 10),
            Container(width: 40, height: 1, color: Colors.white12),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '$kAppVersionFull — Sistem Ujian Terkelola',
          style: TextStyle(
            fontSize: 9,
            color:    Colors.white.withValues(alpha: 0.22),
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// ─── Decorative Widgets ───────────────────────────────────────────────────────

class _DecorCircle extends StatelessWidget {
  const _DecorCircle({required this.size, required this.opacity});
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: opacity),
          width: 1.5,
        ),
      ),
    );
  }
}

class _DotGrid extends StatelessWidget {
  const _DotGrid();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DotGridPainter());
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 28.0;
    const dotR    = 1.0;
    final paint   = Paint()..color = Colors.white.withValues(alpha: 0.06);

    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        // Pola bintang pada setiap 4 titik
        final offset = (x / spacing + y / spacing).toInt().isEven ? 0.0 : spacing / 2;
        canvas.drawCircle(Offset(x + offset, y), dotR, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
