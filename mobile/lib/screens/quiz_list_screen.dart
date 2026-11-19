// ===========================
// DOSMAN UJIAN - Quiz List Screen
// Daftar quiz dalam satu course
// ===========================

import 'package:flutter/material.dart';
import '../models/quiz.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/kiosk_controller.dart';
import '../widgets/quiz_card.dart';
import 'exam_ready_screen.dart';
import 'login_screen.dart';

class QuizListScreen extends StatefulWidget {
  final int    courseId;
  final String courseName;

  const QuizListScreen({
    super.key,
    required this.courseId,
    required this.courseName,
  });

  @override
  State<QuizListScreen> createState() => _QuizListScreenState();
}

class _QuizListScreenState extends State<QuizListScreen> {
  List<Quiz> _quizzes     = [];
  bool       _isLoading   = true;
  String     _errorMsg    = '';
  String     _searchQuery = '';
  final Map<int, ({int finished, int inProgress})> _quizStats = {};

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadQuizzes();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ─── Load Quizzes ────────────────────────────────────────────────────────────

  Future<void> _loadQuizzes() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMsg  = '';
    });

    try {
      final raw    = await ApiService.getQuizzes(widget.courseId);
      final quizzes = raw
          .map((q) => Quiz.fromJson(q as Map<String, dynamic>))
          .where((q) => q.visible)
          .toList();

      // Urutkan: tersedia dulu, lalu berdasarkan nama
      quizzes.sort((a, b) {
        if (a.isOpen && !b.isOpen) return -1;
        if (!a.isOpen && b.isOpen) return 1;
        return a.name.compareTo(b.name);
      });

      if (!mounted) return;
      setState(() {
        _quizzes   = quizzes;
        _isLoading = false;
      });
      _loadQuizStats(quizzes);
    } on TokenExpiredException {
      await KioskController.instance.unlock();
      await AuthService.logout();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg  = e.message;
        _isLoading = false;
      });
    } on NetworkException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg  = e.message;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg  = 'Gagal memuat daftar ujian: $e';
        _isLoading = false;
      });
    }
  }

  // ─── Filter ──────────────────────────────────────────────────────────────────

  List<Quiz> get _filteredQuizzes {
    if (_searchQuery.isEmpty) return _quizzes;
    final q = _searchQuery.toLowerCase();
    return _quizzes.where((quiz) {
      return quiz.name.toLowerCase().contains(q) ||
             quiz.intro.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _loadQuizStats(List<Quiz> quizzes) async {
    final userId = await AuthService.getUserId();
    if (userId <= 0 || quizzes.isEmpty) return;
    await Future.wait(quizzes.map((q) async {
      try {
        final attempts = await ApiService.getUserQuizAttempts(q.id, userId);
        int fin = 0;
        int inp = 0;
        for (final a in attempts) {
          final st = (a['state'] as String? ?? '').toLowerCase();
          if (st == 'finished' || st == 'overdue') {
            fin++;
          } else if (st == 'inprogress') {
            inp++;
          }
        }
        if (mounted) {
          setState(() {
            _quizStats[q.id] = (finished: fin, inProgress: inp);
          });
        }
      } catch (_) {}
    }));
  }

  // ─── Navigate ke ExamReady ────────────────────────────────────────────────────

  void _openQuiz(Quiz quiz) {
    if (!quiz.isOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ujian "${quiz.name}" belum tersedia.\n${quiz.scheduleLabel}'),
          backgroundColor: const Color(0xFF374151),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamReadyScreen(
          quiz:     quiz,
          courseId: widget.courseId,
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        onRefresh:  _loadQuizzes,
        color:      const Color(0xFF2563EB),
        child: _buildBody(),
      ),
    );
  }

  // ─── AppBar ───────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF1E3A5F),
      foregroundColor: Colors.white,
      elevation:       0,
      titleSpacing:    0,
      leading: IconButton(
        icon:    const Icon(Icons.arrow_back_ios_new, size: 20),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize:       MainAxisSize.min,
        children: [
          const Text(
            'Pilih Ujian',
            style: TextStyle(
              fontSize:   16,
              fontWeight: FontWeight.w700,
              color:      Colors.white,
            ),
          ),
          Text(
            widget.courseName,
            style: TextStyle(
              fontSize: 11,
              color:    Colors.white.withValues(alpha: 0.7),
            ),
            maxLines:        1,
            overflow:        TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        // Tombol refresh
        IconButton(
          icon:      const Icon(Icons.refresh, size: 22),
          onPressed: _isLoading ? null : _loadQuizzes,
          tooltip:   'Refresh',
        ),
      ],
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

  // ─── Body ─────────────────────────────────────────────────────────────────────

  Widget _buildBody() {
    if (_isLoading) return _buildLoading();
    if (_errorMsg.isNotEmpty) return _buildError();
    if (_quizzes.isEmpty) return _buildEmpty();
    return _buildQuizList();
  }

  // ─── Loading Skeleton ────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return ListView.builder(
      padding:     const EdgeInsets.all(16),
      itemCount:   5,
      itemBuilder: (_, __) => _SkeletonCard(),
    );
  }

  // ─── Error State ─────────────────────────────────────────────────────────────

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('⚠️', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            Text(
              _errorMsg,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color:    Color(0xFF6B7280),
                height:   1.6,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadQuizzes,
              icon:  const Icon(Icons.refresh, size: 18),
              label: const Text('Coba Lagi'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Empty State ─────────────────────────────────────────────────────────────

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📝', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            const Text(
              'Tidak Ada Ujian',
              style: TextStyle(
                fontSize:   18,
                fontWeight: FontWeight.w700,
                color:      Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Belum ada ujian yang tersedia\ndi course ini.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color:    Colors.grey.shade500,
                height:   1.6,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _loadQuizzes,
              icon:  const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF2563EB),
                side: const BorderSide(color: Color(0xFF2563EB)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Quiz List ────────────────────────────────────────────────────────────────

  Widget _buildQuizList() {
    final filtered = _filteredQuizzes;

    return Column(
      children: [
        // ── Search Bar ──────────────────────────────────────────────────────
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller:   _searchCtrl,
                  decoration: InputDecoration(
                    hintText:   '🔍  Cari ujian...',
                    hintStyle:  const TextStyle(
                      fontSize: 13,
                      color:    Color(0xFF9CA3AF),
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size:  18,
                      color: Color(0xFF9CA3AF),
                    ),
                    filled:    true,
                    fillColor: const Color(0xFFF3F4F6),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical:   10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:   BorderSide.none,
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val),
                ),
              ),
            ],
          ),
        ),

        // ── Header Info ─────────────────────────────────────────────────────
        Container(
          color: const Color(0xFFF9FAFB),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text(
                filtered.isEmpty && _searchQuery.isNotEmpty
                    ? 'Tidak ditemukan'
                    : '${filtered.length} ujian tersedia',
                style: const TextStyle(
                  fontSize:   12,
                  color:      Color(0xFF6B7280),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              // Badge jumlah yang bisa diikuti
              if (_quizzes.where((q) => q.isOpen).isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical:   3,
                  ),
                  decoration: BoxDecoration(
                    color:        const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '🟢 ${_quizzes.where((q) => q.isOpen).length} aktif',
                    style: const TextStyle(
                      fontSize:   11,
                      fontWeight: FontWeight.w600,
                      color:      Color(0xFF15803D),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // ── List ─────────────────────────────────────────────────────────────
        Expanded(
          child: filtered.isEmpty
              ? _buildNoResult()
              : ListView.builder(
                  padding:     const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount:   filtered.length,
                  itemBuilder: (context, index) {
                    final quiz = filtered[index];
                    final stat = _quizStats[quiz.id];
                    return QuizCard(
                      quiz:             quiz,
                      onTap:            () => _openQuiz(quiz),
                      finishedAttempts: stat?.finished,
                      inProgressCount:  stat?.inProgress,
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ─── No search result ────────────────────────────────────────────────────────

  Widget _buildNoResult() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 12),
          Text(
            'Tidak ada ujian yang cocok\ndengan "$_searchQuery"',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color:    Color(0xFF6B7280),
              height:   1.6,
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              _searchCtrl.clear();
              setState(() => _searchQuery = '');
            },
            child: const Text(
              'Hapus Pencarian',
              style: TextStyle(color: Color(0xFF2563EB)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Skeleton Card (loading placeholder) ─────────────────────────────────────

class _SkeletonCard extends StatefulWidget {
  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 0.9).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        margin:      const EdgeInsets.only(bottom: 12),
        padding:     const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(12),
          border:       Border(
            left: BorderSide(
              color: Colors.grey.shade300,
              width: 4,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Baris judul + badge
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color:        Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 70,
                  height: 22,
                  decoration: BoxDecoration(
                    color:        Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Baris deskripsi
            Container(
              height: 12,
              width:  double.infinity,
              decoration: BoxDecoration(
                color:        Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 12,
              width:  200,
              decoration: BoxDecoration(
                color:        Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 16),
            // Tombol skeleton
            Container(
              height: 40,
              width:  double.infinity,
              decoration: BoxDecoration(
                color:        Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
