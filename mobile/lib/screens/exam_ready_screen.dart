// ===========================
// DOSMAN UJIAN - Exam Ready Screen
// Informasi ujian + aturan lockdown sebelum mulai
// ===========================

import 'package:flutter/material.dart';
import '../models/quiz.dart';
import '../services/auth_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';
import 'exam_screen.dart';

class ExamReadyScreen extends StatefulWidget {
  final Quiz quiz;
  final int  courseId;

  const ExamReadyScreen({
    super.key,
    required this.quiz,
    required this.courseId,
  });

  @override
  State<ExamReadyScreen> createState() => _ExamReadyScreenState();
}

class _ExamReadyScreenState extends State<ExamReadyScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<double>   _fadeAnim;
  late Animation<Offset>   _slideAnim;

  bool   _rulesAccepted = false;
  bool   _isStarting    = false;
  String _username      = '';
  int    _userId        = 0;

  @override
  void initState() {
    super.initState();

    _animCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut));

    _animCtrl.forward();
    _loadUserInfo();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUserInfo() async {
    final fullname = await AuthService.getFullname();
    final userId   = await AuthService.getUserId();
    if (mounted) {
      setState(() {
        _username = fullname;
        _userId   = userId;
      });
    }
  }

  // ─── Mulai Ujian ─────────────────────────────────────────────────────────────

  Future<void> _startExam() async {
    if (!_rulesAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Centang persetujuan aturan ujian terlebih dahulu.',
          ),
          backgroundColor: const Color(0xFFDC2626),
          behavior:        SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
      return;
    }

    final confirmed = await _showStartConfirmDialog();
    if (confirmed != true || !mounted) return;

    final securityOk = await _verifyPreExamSecurity();
    if (!securityOk || !mounted) return;

    setState(() => _isStarting = true);

    final userId = _userId > 0 ? _userId : await AuthService.getUserId();
    if (userId == 0) {
      if (!mounted) return;
      setState(() => _isStarting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gagal memulai ujian: data pengguna tidak tersedia.')),
      );
      return;
    }

    // Cek status sesi — apakah siswa masih terblokir dari sesi sebelumnya
    try {
      final sessionInfo = await ExamService.registerSession(
        userId:   userId,
        quizId:   widget.quiz.id,
        courseId: widget.courseId,
      );
      if (sessionInfo.isBlocked) {
        if (!mounted) return;
        setState(() => _isStarting = false);
        _showBlockedDialog(sessionInfo.message);
        return;
      }
    } catch (_) {
      // Jika gagal cek, biarkan lanjut (jangan blokir tanpa sebab)
    }

    // Ambil password untuk auto-login WebView
    final password = await AuthService.getPassword();
    final username = await AuthService.getUsername();

    if (!mounted) return;

    setState(() => _isStarting = false);

    // Navigasi ke ExamScreen
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamScreen(
          quiz:     widget.quiz,
          courseId: widget.courseId,
          userId:   _userId,
          username: username,
          password: password ?? '',
        ),
      ),
    );
  }

  Future<bool> _verifyPreExamSecurity() async {
    final username = (await AuthService.getUsername()).toLowerCase().trim();
    final isReviewer = username == 'playstore.review' || username == 'appstore.review';

    if (!isReviewer) {
      // 1. Virtual Machine (VMOS, VPhone, dll.)
      final isVm = await KioskController.instance.checkVirtualEnvironment();
      if (isVm && mounted) {
        _showSecurityWarningDialog(
          title: 'Virtual Machine Terdeteksi',
          message: 'Aplikasi terdeteksi berjalan di dalam Virtual Machine / Emulator (VMOS, VPhone, dll).\n\n'
              'Ujian WAJIB dikerjakan langsung di sistem HP fisik utama Anda.',
          icon: Icons.warning_amber_rounded,
        );
        return false;
      }

      // 2. Ruang Ganda / Aplikasi Kloning (Dual Apps, Parallel Space, dll.)
      final isCloned = await KioskController.instance.checkClonedApp();
      if (isCloned && mounted) {
        _showSecurityWarningDialog(
          title: 'Aplikasi Kloning Terdeteksi',
          message: 'Aplikasi terdeteksi berjalan di Ruang Ganda / Aplikasi Kloning (Dual App, Parallel Space, Island, dll).\n\n'
              'Buka aplikasi di profil/ruang utama HP Anda.',
          icon: Icons.content_copy,
        );
        return false;
      }

      // 3. USB Debugging
      final flags = await KioskController.instance.checkDeviceSecurityFlags();
      if (flags?.usbDebugging == true && mounted) {
        _showSecurityWarningDialog(
          title: 'USB Debugging Aktif',
          message: 'USB Debugging aktif di HP Anda. Matikan USB Debugging di menu Pengaturan HP → Opsi Pengembang sebelum memulai ujian.',
          icon: Icons.usb,
        );
        return false;
      }
    }

    // 4. Split Screen / Floating Window
    final isSplit = await KioskController.instance.isSplitScreenActive();
    if (isSplit && mounted) {
      _showSecurityWarningDialog(
        title: 'Layar Terbagi Terdeteksi',
        message: 'Tampilan layar belah (Split Screen) atau jendela mengambang aktif. Ubah ke layar penuh (Full Screen) sebelum memulai ujian.',
        icon: Icons.splitscreen,
      );
      return false;
    }

    // 5. Bluetooth Audio
    final hasBtAudio = await KioskController.instance.checkBluetoothAudio();
    if (hasBtAudio && mounted) {
      _showSecurityWarningDialog(
        title: 'Audio Bluetooth Terdeteksi',
        message: 'Perangkat kamu terhubung ke earphone / headset Bluetooth. Harap lepaskan dan matikan koneksi Bluetooth sebelum memulai ujian.',
        icon: Icons.headset_off,
      );
      return false;
    }

    // 6. Screen Cast
    final casting = await KioskController.instance.checkScreenCast();
    if (casting == true && mounted) {
      _showSecurityWarningDialog(
        title: 'Screen Cast Terdeteksi',
        message: 'Perangkat kamu sedang melakukan screen cast / mirroring ke layar lain. Matikan screen cast sebelum memulai ujian.',
        icon: Icons.cast,
      );
      return false;
    }

    // 7. VPN
    final vpn = await KioskController.instance.checkVpn();
    if (vpn == true && mounted) {
      _showSecurityWarningDialog(
        title: 'VPN Aktif Terdeteksi',
        message: 'Koneksi VPN aktif di HP Anda. Matikan VPN sebelum memulai ujian.',
        icon: Icons.vpn_lock,
      );
      return false;
    }

    return true;
  }

  void _showSecurityWarningDialog({
    required String title,
    required String message,
    required IconData icon,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(icon, color: const Color(0xFFEF4444), size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            height: 1.6,
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            child: const Text('Saya Mengerti'),
          ),
        ],
      ),
    );
  }

  void _showBlockedDialog(String reason) {
    final body = reason.isNotEmpty
        ? reason
        : 'Sesi ujian Anda diblokir karena aplikasi terdeteksi keluar saat ujian berlangsung.\n\n'
          'Anda tidak dapat mengikuti ujian sampai guru pengawas membuka blokir sesi Anda.';

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Text('⛔ ', style: TextStyle(fontSize: 22)),
            Expanded(
              child: Text(
                'Sesi Diblokir',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: Color(0xFFDC2626)),
              ),
            ),
          ],
        ),
        content: Text(
          body,
          style: const TextStyle(fontSize: 13, color: Color(0xFF374151), height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Tutup', style: TextStyle(color: Color(0xFF6B7280))),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showStartConfirmDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Row(
          children: [
            Text('🔒 ', style: TextStyle(fontSize: 22)),
            Text(
              'Masuk Mode Lockdown',
              style: TextStyle(
                fontSize:   17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: const Text(
          'Setelah masuk, aplikasi akan:\n\n'
          '• Mencegah screenshot\n'
          '• Memblokir copy/paste\n'
          '• Melaporkan jika aplikasi diminimize\n'
          '• Mengirim data ke guru secara real-time\n\n'
          'Pastikan kamu siap sebelum memulai.',
          style: TextStyle(
            fontSize: 13,
            color:    Color(0xFF374151),
            height:   1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Batal',
              style: TextStyle(color: Color(0xFF6B7280)),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              elevation:       0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Mulai Sekarang',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: _buildAppBar(),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: SlideTransition(
          position: _slideAnim,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Info Siswa ───────────────────────────────────────────────
                if (_username.isNotEmpty) _buildStudentInfo(),

                const SizedBox(height: 16),

                // ── Info Quiz ────────────────────────────────────────────────
                _buildQuizInfoCard(),

                const SizedBox(height: 16),

                // ── Aturan Lockdown ──────────────────────────────────────────
                _buildLockdownRules(),

                const SizedBox(height: 20),

                // ── Persetujuan ──────────────────────────────────────────────
                _buildAgreementCheckbox(),

                const SizedBox(height: 24),

                // ── Tombol Mulai ─────────────────────────────────────────────
                _buildStartButton(),

                const SizedBox(height: 12),

                // ── Keterangan kecil ─────────────────────────────────────────
                const Center(
                  child: Text(
                    'Semua aktivitas selama ujian dipantau oleh guru secara real-time.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color:    Color(0xFF9CA3AF),
                      height:   1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── AppBar ───────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF1E3A5F),
      foregroundColor: Colors.white,
      elevation:       0,
      leading: IconButton(
        icon:      const Icon(Icons.arrow_back_ios_new, size: 20),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: const Text(
        'Persiapan Ujian',
        style: TextStyle(
          fontSize:   16,
          fontWeight: FontWeight.w700,
          color:      Colors.white,
        ),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(23),
        child: Column(
          children: [
            Container(
              width:   double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 3),
              color:   const Color(0xFF162E4A),
              child: const Text(
                'SMAN 1 GIANYAR',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize:      11,
                  fontWeight:    FontWeight.w700,
                  color:         Colors.white60,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            Container(
              height: 3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Student Info ─────────────────────────────────────────────────────────────

  Widget _buildStudentInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:        const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          const Text('👤', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Peserta Ujian',
                style: TextStyle(
                  fontSize: 11,
                  color:    Color(0xFF3B82F6),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                _username,
                style: const TextStyle(
                  fontSize:   14,
                  fontWeight: FontWeight.w700,
                  color:      Color(0xFF1E40AF),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Quiz Info Card ───────────────────────────────────────────────────────────

  Widget _buildQuizInfoCard() {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color:     Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset:     const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color:        const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.quiz_outlined,
                  color: Color(0xFF2563EB),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Informasi Ujian',
                style: TextStyle(
                  fontSize:   15,
                  fontWeight: FontWeight.w700,
                  color:      Color(0xFF1F2937),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          const SizedBox(height: 16),

          // Nama Quiz
          _buildInfoRow(
            icon:  Icons.assignment_outlined,
            label: 'Nama Ujian',
            value: widget.quiz.name,
            color: const Color(0xFF2563EB),
          ),

          const SizedBox(height: 12),

          // Batas Waktu
          _buildInfoRow(
            icon:  Icons.timer_outlined,
            label: 'Batas Waktu',
            value: widget.quiz.timeLimitLabel,
            color: const Color(0xFFD97706),
          ),

          const SizedBox(height: 12),

          // Jadwal
          _buildInfoRow(
            icon:  Icons.calendar_today_outlined,
            label: 'Jadwal',
            value: widget.quiz.scheduleLabel,
            color: const Color(0xFF059669),
          ),

          // Percobaan
          if (widget.quiz.attempts > 0) ...[
            const SizedBox(height: 12),
            _buildInfoRow(
              icon:  Icons.replay_outlined,
              label: 'Percobaan',
              value: '${widget.quiz.attempts}x',
              color: const Color(0xFF7C3AED),
            ),
          ],

          // Deskripsi
          if (widget.quiz.intro.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            const SizedBox(height: 12),
            Text(
              widget.quiz.intro,
              style: const TextStyle(
                fontSize: 13,
                color:    Color(0xFF6B7280),
                height:   1.6,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String   label,
    required String   value,
    required Color    color,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width:  32,
          height: 32,
          decoration: BoxDecoration(
            color:        color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color:    Color(0xFF9CA3AF),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize:   14,
                  color:      Color(0xFF1F2937),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Lockdown Rules ───────────────────────────────────────────────────────────

  Widget _buildLockdownRules() {
    const rules = [
      (
        icon:  '🔒',
        title: 'Screenshot Diblokir',
        desc:  'Layar dilindungi — tidak bisa di-screenshot atau direkam.',
      ),
      (
        icon:  '📋',
        title: 'Copy/Paste Dinonaktifkan',
        desc:  'Menyalin teks soal atau jawaban tidak diperbolehkan.',
      ),
      (
        icon:  '📱',
        title: 'Jangan Minimize Aplikasi',
        desc:  'Membuka aplikasi lain atau menekan tombol Home akan dicatat.',
      ),
      (
        icon:  '💓',
        title: 'Heartbeat Otomatis',
        desc:  'Aplikasi mengirim sinyal tiap 10 detik. Koneksi terputus = diblokir.',
      ),
      (
        icon:  '👁️',
        title: 'Dipantau Real-Time',
        desc:  'Semua aktivitas terkirim ke guru secara langsung.',
      ),
    ];

    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color:        const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          const Row(
            children: [
              Text('⚠️', style: TextStyle(fontSize: 20)),
              SizedBox(width: 10),
              Text(
                'Aturan Mode Lockdown',
                style: TextStyle(
                  fontSize:   15,
                  fontWeight: FontWeight.w700,
                  color:      Color(0xFF92400E),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Daftar aturan
          ...rules.map(
            (rule) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.icon,
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rule.title,
                          style: const TextStyle(
                            fontSize:   13,
                            fontWeight: FontWeight.w700,
                            color:      Color(0xFF92400E),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          rule.desc,
                          style: const TextStyle(
                            fontSize: 12,
                            color:    Color(0xFFB45309),
                            height:   1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Agreement Checkbox ───────────────────────────────────────────────────────

  Widget _buildAgreementCheckbox() {
    return GestureDetector(
      onTap: () => setState(() => _rulesAccepted = !_rulesAccepted),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _rulesAccepted
              ? const Color(0xFFF0FDF4)
              : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _rulesAccepted
                ? const Color(0xFF86EFAC)
                : const Color(0xFFE5E7EB),
            width: 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width:  22,
              height: 22,
              decoration: BoxDecoration(
                color: _rulesAccepted
                    ? const Color(0xFF16A34A)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: _rulesAccepted
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF9CA3AF),
                  width: 2,
                ),
              ),
              child: _rulesAccepted
                  ? const Icon(
                      Icons.check,
                      size:  14,
                      color: Colors.white,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Saya memahami dan menyetujui aturan ujian di atas. '
                'Saya siap mengerjakan ujian dengan jujur dan tidak akan '
                'mencoba melakukan kecurangan.',
                style: TextStyle(
                  fontSize: 13,
                  color:    Color(0xFF374151),
                  height:   1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Start Button ─────────────────────────────────────────────────────────────

  Widget _buildStartButton() {
    return SizedBox(
      width:  double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: (_isStarting || !_rulesAccepted) ? null : _startExam,
        style: ElevatedButton.styleFrom(
          backgroundColor:         const Color(0xFF2563EB),
          disabledBackgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.5),
          foregroundColor:         Colors.white,
          elevation:               0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: _isStarting
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width:  18,
                    height: 18,
                    child:  CircularProgressIndicator(
                      color:       Colors.white,
                      strokeWidth: 2.5,
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Memuat Ujian...',
                    style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('🔒', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Mulai Ujian (Mode Lockdown)',
                    style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
