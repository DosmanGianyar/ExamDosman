// ===========================
// DOSMAN UJIAN - Offline Quiz Screen (Android Semi-Offline MCQ)
// - Download paket soal + gambar saat Start Quiz
// - Pengerjaan 100% offline dengan KaTeX lokal (tanpa beban server / kebal sinyal putus)
// - Batch submit saat selesai dengan Auto-Retry jika sinyal putus
// - Anti-cheat & suspend check tetap aktif
// ===========================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../config/app_config.dart';
import '../models/quiz.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';
import '../services/offline_quiz_service.dart';
import '../widgets/exit_password_dialog.dart';
import 'blocked_screen.dart';
import 'exam_screen.dart';

class OfflineQuizScreen extends StatefulWidget {
  final Quiz quiz;
  final int courseId;
  final int userId;

  const OfflineQuizScreen({
    super.key,
    required this.quiz,
    required this.courseId,
    required this.userId,
  });

  @override
  State<OfflineQuizScreen> createState() => _OfflineQuizScreenState();
}

class _OfflineQuizScreenState extends State<OfflineQuizScreen>
    with WidgetsBindingObserver {
  // ─── Download & Paket Soal ───────────────────────────────────────────────
  bool _isDownloading = true;
  String _downloadStatus = 'Menyiapkan ujian...';
  double _downloadProgress = 0.0;
  String? _downloadError;
  String? _quizPassword;
  OfflineQuizPackage? _package;
  int _currentIndex = 0;

  // ─── WebView Soal Lokal ──────────────────────────────────────────────────
  InAppWebViewController? _webCtrl;
  bool _webReady = false;

  // ─── Timer Ujian ─────────────────────────────────────────────────────────
  Timer? _countdownTimer;
  int _remainingSec = 0;
  bool _autoSubmittedOnTimeout = false;

  // ─── Submit & Auto-Retry ─────────────────────────────────────────────────
  bool _isSubmitting = false;
  bool _waitingSignalToSubmit = false;
  String _submitError = '';
  Timer? _submitRetryTimer;

  // ─── Keamanan & Heartbeat ────────────────────────────────────────────────
  Timer? _pingTimer;
  Timer? _blockTimer;
  DateTime? _backgroundedAt;
  bool _screenWasOff = false;
  bool _blockSent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    KioskController.instance.addViolationListener(_onNativeViolation);
    KioskController.instance.lock(userId: widget.userId);
    KioskController.instance.enterExam();
    _startDownload();
    _startHeartbeat();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    KioskController.instance.removeViolationListener(_onNativeViolation);
    KioskController.instance.exitExam();
    _countdownTimer?.cancel();
    _pingTimer?.cancel();
    _blockTimer?.cancel();
    _submitRetryTimer?.cancel();
    super.dispose();
  }

  // ─── Download Paket Soal Saat Start Quiz ─────────────────────────────────

  Future<void> _startDownload({String? password}) async {
    if (!mounted) return;
    setState(() {
      _isDownloading = true;
      _downloadError = null;
      _downloadStatus = 'Menyiapkan soal ujian...';
      _downloadProgress = 0.05;
    });

    try {
      final pkg = await OfflineQuizService.downloadQuizPackage(
        quizId: widget.quiz.id,
        courseId: widget.courseId,
        userId: widget.userId,
        quizName: widget.quiz.name,
        timeLimitSec: widget.quiz.timelimit,
        timeCloseEpochSec: widget.quiz.timeclose,
        quizPassword: password ?? _quizPassword,
        onProgress: (status, prog) {
          if (!mounted) return;
          setState(() {
            _downloadStatus = status;
            _downloadProgress = prog;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _package = pkg;
        _isDownloading = false;
        _currentIndex = 0;
      });
      _initCountdown();
      // Kirim ping dengan quizId agar dashboard pengawas tahu siswa mulai kuis
      ExamService.pingAppLogin(quizId: widget.quiz.id).ignore();
    } on ApiException catch (e) {
      if (!mounted) return;
      final msgLower = e.message.toLowerCase();
      if (msgLower.contains('password') || msgLower.contains('sandi')) {
        final enteredPwd = await _askQuizPasswordDialog();
        if (enteredPwd != null && enteredPwd.isNotEmpty) {
          _quizPassword = enteredPwd;
          await _startDownload(password: enteredPwd);
          return;
        }
      }
      setState(() {
        _isDownloading = false;
        _downloadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadError = e.toString();
      });
    }
  }

  Future<String?> _askQuizPasswordDialog() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Password Kuis Diperlukan',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Masukkan password kuis dari pengawas',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
            filled: true,
            fillColor: Colors.black26,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Batal', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Lanjut'),
          ),
        ],
      ),
    );
  }

  // ─── Timer Ujian Lokal ───────────────────────────────────────────────────

  void _initCountdown() {
    _countdownTimer?.cancel();
    final endEpoch = _package?.endTimeEpochSec ?? 0;
    if (endEpoch <= 0) return;

    void tick() {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final diff = endEpoch - nowSec;
      if (!mounted) return;
      setState(() => _remainingSec = diff > 0 ? diff : 0);
      if (diff <= 0 && !_autoSubmittedOnTimeout) {
        _autoSubmittedOnTimeout = true;
        _countdownTimer?.cancel();
        _submitQuiz(timeUp: true);
      }
    }

    tick();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  String _formatTimer(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ─── Render Soal + Pilihan A-E ke WebView Lokal (Offline + KaTeX) ────────

  Future<void> _renderCurrentQuestion() async {
    final ctrl = _webCtrl;
    final pkg = _package;
    if (ctrl == null || pkg == null || !_webReady) return;
    final q = pkg.questions[_currentIndex];

    final optionsHtml = StringBuffer();
    for (final opt in q.options) {
      final isSelected = q.selectedValue == opt.value;
      final cls = isSelected ? 'opt-card selected' : 'opt-card';
      final escapedVal = _escapeHtml(opt.value);
      optionsHtml.write('''
        <div class="$cls" data-val="$escapedVal" onclick="selectOpt(this)">
          <div class="opt-letter">${_escapeHtml(opt.labelLetter)}</div>
          <div class="opt-body">${opt.html}</div>
          <div class="opt-check">&#10003;</div>
        </div>
      ''');
    }

    final fullHtml = '''
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
<link rel="stylesheet" href="katex.min.css">
<style>
  * { box-sizing: border-box; -webkit-user-select: none; user-select: none; -webkit-tap-highlight-color: transparent; }
  body {
    margin: 0;
    padding: 14px 14px 36px 14px;
    font-family: -apple-system, Roboto, 'Segoe UI', sans-serif;
    background: #F1F5F9;
    color: #0F172A;
    font-size: 15.5px;
    line-height: 1.65;
  }
  .q-card {
    background: #FFFFFF;
    border-radius: 18px;
    padding: 16px 16px 18px 16px;
    border: 1px solid #E2E8F0;
    margin-bottom: 16px;
    box-shadow: 0 4px 16px rgba(15,23,42,0.05);
    overflow-x: auto;
  }
  .q-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: linear-gradient(135deg, #0F172A, #1E3A8A);
    color: #FFFFFF;
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.4px;
    padding: 4px 11px;
    border-radius: 999px;
    margin-bottom: 12px;
    border-bottom: 2px solid #F59E0B;
  }
  .q-card img, .opt-body img {
    max-width: 100%;
    height: auto;
    display: block;
    border-radius: 10px;
    margin: 10px auto;
    border: 1px solid #E2E8F0;
    background: #FFFFFF;
  }
  .img-hint {
    font-size: 11px;
    color: #64748B;
    text-align: center;
    margin-top: -4px;
    margin-bottom: 8px;
  }
  .q-card table {
    border-collapse: collapse;
    max-width: 100%;
    display: block;
    overflow-x: auto;
  }
  .q-card td, .q-card th {
    border: 1px solid #CBD5E1;
    padding: 6px 8px;
  }
  .opt-card {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    background: #FFFFFF;
    border: 1.5px solid #CBD5E1;
    border-radius: 14px;
    padding: 13px 14px;
    margin-bottom: 10px;
    cursor: pointer;
    box-shadow: 0 2px 6px rgba(15,23,42,0.03);
    transition: transform 0.08s ease, border-color 0.12s ease, background 0.12s ease;
  }
  .opt-card:active {
    transform: scale(0.988);
  }
  .opt-card.selected {
    background: linear-gradient(135deg, #EFF6FF, #DBEAFE);
    border-color: #2563EB;
    box-shadow: 0 4px 14px rgba(37,99,235,0.16);
  }
  .opt-letter {
    flex-shrink: 0;
    width: 32px;
    height: 32px;
    border-radius: 10px;
    background: #F1F5F9;
    color: #334155;
    font-weight: 800;
    font-size: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid #E2E8F0;
  }
  .opt-card.selected .opt-letter {
    background: linear-gradient(135deg, #1E3A8A, #2563EB);
    color: #FFFFFF;
    border-color: transparent;
  }
  .opt-body {
    flex: 1;
    min-width: 0;
    padding-top: 3px;
    word-wrap: break-word;
    overflow-wrap: anywhere;
  }
  .opt-check {
    flex-shrink: 0;
    width: 22px;
    height: 22px;
    border-radius: 999px;
    border: 1.5px solid #CBD5E1;
    margin-top: 5px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 12px;
    color: transparent;
  }
  .opt-card.selected .opt-check {
    background: #16A34A;
    border-color: #16A34A;
    color: #FFFFFF;
  }
  .opt-body p:first-child, .q-card p:first-child { margin-top: 0; }
  .opt-body p:last-child, .q-card p:last-child { margin-bottom: 0; }
  .katex-display { overflow-x: auto; overflow-y: hidden; padding: 4px 0; }
</style>
</head>
<body>
  <div class="q-card">
    <div class="q-badge">PERTANYAAN NOMOR ${q.number}</div>
    ${q.questionHtml}
  </div>
  <div class="options-wrap">$optionsHtml</div>
  <script src="katex.min.js"></script>
  <script src="auto-render.min.js"></script>
  <script>
    function selectOpt(el) {
      var val = el.getAttribute('data-val');
      var cards = document.querySelectorAll('.opt-card');
      for (var i = 0; i < cards.length; i++) {
        cards[i].classList.remove('selected');
      }
      el.classList.add('selected');
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('selectOption', val);
      }
    }
    document.addEventListener('DOMContentLoaded', function() {
      var imgs = document.querySelectorAll('.q-card img, .opt-body img');
      for (var i = 0; i < imgs.length; i++) {
        (function(img) {
          img.addEventListener('click', function(e) {
            e.stopPropagation();
            if (window.flutter_inappwebview && img.src) {
              window.flutter_inappwebview.callHandler('zoomImage', img.src);
            }
          });
        })(imgs[i]);
      }
      if (typeof renderMathInElement === 'function') {
        try {
          renderMathInElement(document.body, {
            delimiters: [
              {left: '\\\\(', right: '\\\\)', display: false},
              {left: '\\\\[', right: '\\\\]', display: true},
              {left: '\$\$', right: '\$\$', display: true}
            ],
            throwOnError: false,
            strict: false
          });
        } catch (e) {}
      }
    });
  </script>
</body>
</html>
''';

    await ctrl.loadData(
      data: fullHtml,
      baseUrl: WebUri('file:///android_asset/flutter_assets/assets/katex/'),
      mimeType: 'text/html',
      encoding: 'utf-8',
    );
  }

  String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  void _onSelectOption(String value) {
    final pkg = _package;
    if (pkg == null || !mounted) return;
    setState(() {
      pkg.questions[_currentIndex].selectedValue = value;
    });
    OfflineQuizService.saveAnswersState(pkg);
  }

  void _goToQuestion(int idx) {
    final pkg = _package;
    if (pkg == null) return;
    if (idx < 0 || idx >= pkg.questions.length) return;
    setState(() => _currentIndex = idx);
    _renderCurrentQuestion();
  }

  void _toggleFlag() {
    final pkg = _package;
    if (pkg == null) return;
    setState(() {
      pkg.questions[_currentIndex].isFlagged =
          !pkg.questions[_currentIndex].isFlagged;
    });
    OfflineQuizService.saveAnswersState(pkg);
  }

  // ─── Submit Batch Jawaban (Online di Akhir + Auto-Retry) ────────────────

  Future<void> _confirmAndSubmit() async {
    final pkg = _package;
    if (pkg == null) return;
    final answered = pkg.questions.where((q) => q.selectedValue != null).length;
    final unanswered = pkg.questions.length - answered;
    final flagged = pkg.questions.where((q) => q.isFlagged).length;
    bool agreed = false;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.assignment_turned_in_rounded, color: Color(0xFF60A5FA), size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Konfirmasi Kirim Jawaban',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Terjawab: $answered dari ${pkg.questions.length} soal',
                style: const TextStyle(color: Color(0xFF86EFAC), fontSize: 14, fontWeight: FontWeight.w600),
              ),
              if (unanswered > 0) ...[
                const SizedBox(height: 6),
                Text(
                  'Belum dijawab: $unanswered soal',
                  style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
              if (flagged > 0) ...[
                const SizedBox(height: 6),
                Text(
                  'Ditandai ragu-ragu: $flagged soal',
                  style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 13),
                ),
              ],
              const SizedBox(height: 14),
              InkWell(
                onTap: () => setDlgState(() => agreed = !agreed),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: agreed
                        ? const Color(0xFF16A34A).withValues(alpha: 0.16)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: agreed ? const Color(0xFF22C55E) : Colors.white24,
                    ),
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: agreed,
                        onChanged: (v) => setDlgState(() => agreed = v == true),
                        activeColor: const Color(0xFF16A34A),
                        side: const BorderSide(color: Colors.white54),
                      ),
                      const Expanded(
                        child: Text(
                          'Saya yakin sudah memeriksa seluruh jawaban dan siap mengakhiri ujian ini.',
                          style: TextStyle(color: Colors.white, fontSize: 12, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal / Periksa Lagi', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              onPressed: agreed ? () => Navigator.pop(ctx, true) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: Colors.white38,
              ),
              child: const Text('Kirim Jawaban'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      await _submitQuiz();
    }
  }

  Future<void> _submitQuiz({bool timeUp = false}) async {
    final pkg = _package;
    if (pkg == null || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _submitError = '';
    });

    try {
      final payload = OfflineQuizService.buildSubmitPayload(pkg);
      final attemptState = await ApiService.processQuizAttempt(
        pkg.attemptId,
        payload,
        finishAttempt: true,
        timeUp: timeUp,
        quizPassword: _quizPassword,
      );

      if (attemptState != 'finished' && attemptState != 'overdue' && attemptState != 'abandoned') {
        throw ApiException('Server belum mengonfirmasi status selesai ($attemptState).');
      }

      final answeredCount = pkg.questions.where((q) => q.selectedValue != null).length;
      final studentName = await AuthService.getFullname();
      final sentTime = DateTime.now();
      final timeLabel =
          '${sentTime.hour.toString().padLeft(2, '0')}:${sentTime.minute.toString().padLeft(2, '0')}:${sentTime.second.toString().padLeft(2, '0')}';

      _submitRetryTimer?.cancel();
      await OfflineQuizService.clearSavedPackage(
        userId: pkg.userId,
        quizId: pkg.quizId,
      );
      _countdownTimer?.cancel();

      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _waitingSignalToSubmit = false;
      });

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF064E3B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFF34D399), width: 1.5),
          ),
          title: const Row(
            children: [
              Icon(Icons.verified_rounded, color: Color(0xFF34D399), size: 28),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'BUKTI UJIAN TERKIRIM',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Jawaban Anda telah diterima dan tersimpan resmi di server Moodle.',
                style: TextStyle(color: Color(0xFFD1FAE5), fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Siswa: $studentName', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('Ujian: ${pkg.quizName}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text('Terjawab: $answeredCount / ${pkg.questions.length} soal', style: const TextStyle(color: Color(0xFF6EE7B7), fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Jam Kirim: $timeLabel WITA (ID #${pkg.attemptId})', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                child: const Text('Selesai & Kembali', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      );

      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst || route.settings.name == '/courses');
      }
    } catch (e) {
      if (!mounted) return;
      // Gagal kirim karena sinyal putus → tahan di layar tunggu dengan auto-retry 5 detik
      setState(() {
        _isSubmitting = false;
        _waitingSignalToSubmit = true;
        _submitError = e.toString();
      });
      _submitRetryTimer?.cancel();
      _submitRetryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted && _waitingSignalToSubmit && !_isSubmitting) {
          _submitQuiz(timeUp: timeUp);
        }
      });
    }
  }

  // ─── Keamanan & Heartbeat ────────────────────────────────────────────────

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 45), (_) async {
      if (!mounted || _blockSent) return;
      final alive = await ExamService.pingAppLogin(quizId: widget.quiz.id);
      if (!mounted) return;
      if (!alive) {
        _pingTimer?.cancel();
        await AuthService.saveSuspendedByAdmin(true);
        await AuthService.logout();
        await KioskController.instance.unlock();
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
        return;
      }
      final blockRes = await ExamService.checkBlocked(userId: widget.userId);
      if (!mounted || _blockSent) return;
      if (blockRes.reachable && blockRes.blocked) {
        _blockSent = true;
        _pingTimer?.cancel();
        await AuthService.saveBlockedStatus(true);
        await KioskController.instance.unlock();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => BlockedScreen(userId: widget.userId, reason: blockRes.reason),
          ),
          (route) => false,
        );
      }
    });
  }

  void _onNativeViolation(String reason) {
    if (reason == 'screenshot_attempt') return;
    if (_blockSent || !mounted) return;
    _blockSent = true;
    _triggerSuspend(reason);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  Future<void> _onAppPaused() async {
    if (_blockSent || (_blockTimer != null && _blockTimer!.isActive)) return;
    _backgroundedAt = DateTime.now();
    bool screenOn = true;
    try {
      screenOn = (await const MethodChannel(AppConfig.lockdownChannel)
              .invokeMethod<bool>('isScreenInteractive')) ??
          true;
    } catch (_) {}

    if (!screenOn) {
      _screenWasOff = true;
      return;
    }
    _screenWasOff = false;
    if (KioskController.instance.isInGracePeriod) return;

    _blockTimer = Timer(
      const Duration(seconds: AppConfig.backgroundBlockTimeout),
      () async {
        if (KioskController.instance.isInGracePeriod) return;
        _blockSent = true;
        await _triggerSuspend('background_timeout_auto_suspend');
      },
    );
  }

  Future<void> _onAppResumed() async {
    _blockTimer?.cancel();
    final wasOff = _screenWasOff;
    _screenWasOff = false;
    if (_blockSent || _backgroundedAt == null) return;
    final elapsed = DateTime.now().difference(_backgroundedAt!).inSeconds;
    _backgroundedAt = null;
    if (wasOff) return;
    if (elapsed >= AppConfig.backgroundBlockTimeout && !KioskController.instance.isInGracePeriod) {
      _blockSent = true;
      await _triggerSuspend('background_timeout_auto_suspend');
    }
  }

  Future<void> _triggerSuspend(String reason) async {
    _pingTimer?.cancel();
    _countdownTimer?.cancel();
    bool suspended = false;
    try {
      suspended = await ExamService.suspendStudent(
        userId: widget.userId,
        reason: 'Pelanggaran keamanan ujian: $reason',
      );
    } catch (_) {
      suspended = false;
    }
    if (!suspended && widget.userId > 0) {
      await ExamScreen.savePendingSuspend(widget.userId);
    }
    await AuthService.saveBlockedStatus(true);
    await AuthService.saveSuspendedByAdmin(true);
    await KioskController.instance.unlock();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => BlockedScreen(
          userId: widget.userId,
          reason: 'Akun Anda ditangguhkan karena pelanggaran keamanan saat ujian berlangsung.',
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _handleExit() async {
    final pkg = _package;
    if (pkg != null) {
      final answered = pkg.questions.where((q) => q.selectedValue != null).length;
      final proceedExit = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF450A0A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFFCA5A5), size: 26),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'JAWABAN BELUM DIKIRIM!',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: Text(
            'PERHATIAN: Jawaban ujian Anda ($answered/${pkg.questions.length} soal) BELUM dikirim ke server Moodle!\n\n'
            'Jika belum selesai, kembali ke ujian dan tekan tombol "Selesai" untuk mengirim nilai.',
            style: const TextStyle(color: Color(0xFFFEE2E2), fontSize: 13, height: 1.5),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
              child: const Text('Kembali ke Ujian'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Tetap Keluar', style: TextStyle(color: Color(0xFFFCA5A5))),
            ),
          ],
        ),
      );
      if (proceedExit != true) return;
    }

    final fetch = await KioskController.instance.fetchExitPassword();
    if (!fetch.success) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tidak dapat memverifikasi password keluar. Periksa sinyal Wi-Fi.'),
          backgroundColor: Color(0xFFD97706),
        ),
      );
      return;
    }

    if (fetch.password.isNotEmpty && mounted) {
      final pwdOk = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const ExitPasswordDialog(),
      );
      if (pwdOk != true) return;
    }

    await KioskController.instance.unlock();
    await AuthService.saveBlockedStatus(false);
    await AuthService.logout();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  void _showZoomImageDialog(String src) {
    if (!mounted) return;
    Widget imgWidget;
    if (src.startsWith('data:image/') && src.contains('base64,')) {
      try {
        final b64Part = src.split('base64,').last;
        imgWidget = Image.memory(base64Decode(b64Part), fit: BoxFit.contain);
      } catch (_) {
        imgWidget = const Icon(Icons.broken_image, color: Colors.white54, size: 48);
      }
    } else {
      imgWidget = Image.network(src, fit: BoxFit.contain);
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.5,
              child: Center(child: imgWidget),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showQuestionGridSheet() {
    final pkg = _package;
    if (pkg == null) return;
    final answeredCnt = pkg.questions.where((q) => q.selectedValue != null).length;
    final flaggedCnt = pkg.questions.where((q) => q.isFlagged).length;
    final emptyCnt = pkg.questions.length - answeredCnt;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Navigasi Nomor Soal',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '$answeredCnt/${pkg.questions.length} Terjawab',
                    style: const TextStyle(color: Color(0xFF86EFAC), fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  _legendItem(const Color(0xFF2563EB), 'Aktif'),
                  _legendItem(const Color(0xFF16A34A), 'Terjawab ($answeredCnt)'),
                  _legendItem(const Color(0xFFD97706), 'Ragu ($flaggedCnt)'),
                  _legendItem(const Color(0xFF334155), 'Kosong ($emptyCnt)'),
                ],
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.48,
                ),
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: pkg.questions.length,
                  itemBuilder: (_, i) {
                    final q = pkg.questions[i];
                    final isCur = i == _currentIndex;
                    final Color bg;
                    if (isCur) {
                      bg = const Color(0xFF2563EB);
                    } else if (q.isFlagged) {
                      bg = const Color(0xFFD97706);
                    } else if (q.selectedValue != null) {
                      bg = const Color(0xFF16A34A);
                    } else {
                      bg = const Color(0xFF334155);
                    }
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _goToQuestion(i);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(11),
                          border: isCur ? Border.all(color: Colors.white, width: 2) : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${q.number}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11)),
      ],
    );
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: SafeArea(
          child: _isDownloading
              ? _buildDownloadingView()
              : _downloadError != null
                  ? _buildDownloadErrorView()
                  : _waitingSignalToSubmit
                      ? _buildWaitingSubmitView()
                      : _buildQuizView(),
        ),
      ),
    );
  }

  Widget _buildDownloadingView() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.assignment_rounded, color: Color(0xFF60A5FA), size: 54),
            const SizedBox(height: 18),
            Text(
              widget.quiz.name,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            LinearProgressIndicator(
              value: _downloadProgress,
              backgroundColor: Colors.white12,
              color: const Color(0xFF3B82F6),
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 12),
            Text(
              _downloadStatus,
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadErrorView() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 52),
            const SizedBox(height: 16),
            const Text(
              'Gagal Menyiapkan Soal Ujian',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              _downloadError ?? 'Periksa koneksi Wi-Fi Anda.',
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _startDownload(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Coba Lagi'),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Kembali', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaitingSubmitView() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_find_rounded, color: Color(0xFFFBBF24), size: 56),
            const SizedBox(height: 18),
            const Text(
              'Menunggu Sinyal untuk Mengirim Jawaban',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Jangan tutup aplikasi! Seluruh jawaban Anda sudah tersimpan aman di HP ini. '
              'Aplikasi otomatis mencoba mengirim ulang setiap 5 detik begitu sinyal Wi-Fi terhubung.',
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.55),
              textAlign: TextAlign.center,
            ),
            if (_submitError.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _submitError,
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                textAlign: TextAlign.center,
                maxLines: 2,
              ),
            ],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : () => _submitQuiz(timeUp: _autoSubmittedOnTimeout),
                icon: const Icon(Icons.send_rounded),
                label: Text(_isSubmitting ? 'Mengirim...' : 'Kirim Ulang Sekarang'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuizView() {
    final pkg = _package!;
    final q = pkg.questions[_currentIndex];
    final isLast = _currentIndex == pkg.questions.length - 1;
    final answeredCount = pkg.questions.where((item) => item.selectedValue != null).length;
    final progressVal = pkg.questions.isEmpty ? 0.0 : answeredCount / pkg.questions.length;

    return Column(
      children: [
        // ── Header Bar ─────────────────────────────────────────────────────
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0F172A), Color(0xFF1E3A5F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pkg.quizName,
                          style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Soal ${q.number} dari ${pkg.questions.length} • $answeredCount terjawab',
                          style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  if (_remainingSec > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: _remainingSec < 300
                            ? const Color(0xFFDC2626).withValues(alpha: 0.25)
                            : Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _remainingSec < 300 ? const Color(0xFFEF4444) : Colors.white24,
                        ),
                      ),
                      child: Text(
                        _formatTimer(_remainingSec),
                        style: TextStyle(
                          color: _remainingSec < 300 ? const Color(0xFFFCA5A5) : Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.grid_view_rounded, color: Color(0xFFFBBF24), size: 22),
                    onPressed: _showQuestionGridSheet,
                    tooltip: 'Daftar Soal',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  ),
                  IconButton(
                    icon: const Icon(Icons.exit_to_app_rounded, color: Color(0xFFFCA5A5), size: 21),
                    onPressed: _handleExit,
                    tooltip: 'Keluar',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progressVal,
                minHeight: 3,
                backgroundColor: Colors.white12,
                color: const Color(0xFF22C55E),
              ),
            ],
          ),
        ),

        // ── Konten Soal & Pilihan (WebView Lokal Offline) ──────────────────
        Expanded(
          child: InAppWebView(
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: false,
              disableContextMenu: true,
              disableLongPressContextMenuOnLinks: true,
              allowFileAccess: true,
              allowFileAccessFromFileURLs: true,
              allowUniversalAccessFromFileURLs: true,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            ),
            onWebViewCreated: (ctrl) {
              _webCtrl = ctrl;
              _webReady = true;
              ctrl.addJavaScriptHandler(
                handlerName: 'selectOption',
                callback: (args) {
                  if (args.isNotEmpty) {
                    _onSelectOption('${args[0]}');
                  }
                },
              );
              ctrl.addJavaScriptHandler(
                handlerName: 'zoomImage',
                callback: (args) {
                  if (args.isNotEmpty) {
                    _showZoomImageDialog('${args[0]}');
                  }
                },
              );
              _renderCurrentQuestion();
            },
          ),
        ),

        // ── Footer Navigasi Anti-Overflow ──────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: const Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: OutlinedButton.icon(
                  onPressed: _currentIndex > 0 ? () => _goToQuestion(_currentIndex - 1) : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    side: BorderSide(
                      color: _currentIndex > 0 ? const Color(0xFF94A3B8) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  icon: const Icon(Icons.chevron_left_rounded, size: 18),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Sebelum', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: OutlinedButton.icon(
                  onPressed: _toggleFlag,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    backgroundColor: q.isFlagged ? const Color(0xFFFEF3C7) : null,
                    foregroundColor: q.isFlagged ? const Color(0xFFB45309) : const Color(0xFF475569),
                    side: BorderSide(
                      color: q.isFlagged ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1),
                    ),
                  ),
                  icon: Icon(q.isFlagged ? Icons.flag_rounded : Icons.flag_outlined, size: 16),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Ragu-ragu', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: !isLast
                    ? ElevatedButton.icon(
                        onPressed: () => _goToQuestion(_currentIndex + 1),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E3A8A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.chevron_right_rounded, size: 18),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Lanjut', style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      )
                    : ElevatedButton.icon(
                        onPressed: _isSubmitting ? null : _confirmAndSubmit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16A34A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.check_circle_outline_rounded, size: 17),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _isSubmitting ? 'Kirim...' : 'Selesai',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
