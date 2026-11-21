// ===========================
// DOSMAN UJIAN - Course List Screen
// Daftar course yang diikuti siswa
// ===========================

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/course.dart';
import '../models/quiz.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/exam_service.dart';
import '../services/kiosk_controller.dart';
import '../services/offline_quiz_service.dart';
import '../widgets/course_card.dart';
import '../widgets/exit_password_dialog.dart';
import 'quiz_list_screen.dart';
import 'offline_quiz_screen.dart';
import 'login_screen.dart';

class CourseListScreen extends StatefulWidget {
  const CourseListScreen({super.key});

  @override
  State<CourseListScreen> createState() => _CourseListScreenState();
}

class _CourseListScreenState extends State<CourseListScreen> {
  List<Course> _courses     = [];
  bool         _isLoading   = true;
  String       _errorMsg    = '';
  String       _searchQuery = '';
  String       _fullname    = 'Siswa';
  String       _department  = '';
  int          _userId      = 0;
  final Map<int, ({int finished, int inProgress})> _courseStats = {};

  final _searchCtrl = TextEditingController();
  Timer? _pingTimer;

  @override
  void initState() {
    super.initState();
    _init();
    // Perbarui status di dashboard setiap 60 detik selama siswa di layar ini
    _pingTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) async {
        final alive = await ExamService.pingAppLogin();
        if (!alive && mounted) {
          await AuthService.saveSuspendedByAdmin(true);
          await AuthService.logout();
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ─── Init: load nama user + courses ─────────────────────────────────────────

  Future<void> _init() async {
    final fullname = await AuthService.getFullname();
    final department = await AuthService.getDepartment();
    final userId = await AuthService.getUserId();
    if (mounted) {
      setState(() {
        _fullname = fullname;
        _department = department;
      });
    }
    _fetchUserDepartmentIfNeeded(userId);
    await KioskController.instance.lock(userId: userId);
    await _loadCourses();
    await _checkPendingOfflineSubmissions(userId);
  }

  Future<void> _fetchUserDepartmentIfNeeded(int userId) async {
    if (userId <= 0) return;
    try {
      final res = await ApiService.call('core_user_get_users_by_field', {
        'field': 'id',
        'values[0]': userId,
      });
      if (res is List && res.isNotEmpty && res.first is Map<String, dynamic>) {
        final u = res.first as Map<String, dynamic>;
        final dept = (u['department'] as String? ?? '').trim();
        final full = (u['fullname'] as String? ?? '').trim();
        if (dept.isNotEmpty) {
          await AuthService.saveDepartment(dept);
        }
        if (mounted && (dept.isNotEmpty || full.isNotEmpty)) {
          setState(() {
            if (dept.isNotEmpty) _department = dept;
            if (full.isNotEmpty) _fullname = full;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _checkPendingOfflineSubmissions(int userId) async {
    if (!mounted || userId <= 0) return;
    final pending = await OfflineQuizService.findPendingPackages(userId);
    if (pending.isEmpty || !mounted) return;
    final pkg = pending.first;
    final answered = pkg.questions.where((q) => q.selectedValue != null).length;

    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFF59E0B), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFFBBF24), size: 24),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Jawaban Belum Terkirim',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: Text(
          'Ditemukan jawaban ujian "${pkg.quizName}" ($answered/${pkg.questions.length} soal) yang belum dikirim ke server.\n\n'
          'Silakan lanjutkan dan tekan "Selesai" untuk mengirim jawaban Anda.',
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Nanti', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Lanjutkan & Kirim'),
          ),
        ],
      ),
    );

    if (resume == true && mounted) {
      final dummyQuiz = Quiz(
        id: pkg.quizId,
        coursemodule: 0,
        course: pkg.courseId,
        name: pkg.quizName,
        intro: '',
        timeopen: 0,
        timeclose: pkg.endTimeEpochSec,
        timelimit: 0,
        attempts: 1,
        gradepass: 0,
        grade: 100,
        visible: true,
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OfflineQuizScreen(
            quiz: dummyQuiz,
            courseId: pkg.courseId,
            userId: userId,
          ),
        ),
      );
    }
  }

  // ─── Load Courses ─────────────────────────────────────────────────────────────

  Future<void> _loadCourses() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMsg  = '';
    });

    try {
      final userId  = await AuthService.getUserId();
      final raw     = await ApiService.getCourses(userId);
      final courses = raw
          .map((c) => Course.fromJson(c as Map<String, dynamic>))
          .where((c) => c.visible)
          .toList();

      // Urutkan berdasarkan nama
      courses.sort((a, b) => a.fullname.compareTo(b.fullname));

      if (!mounted) return;
      setState(() {
        _userId    = userId;
        _courses   = courses;
        _isLoading = false;
      });
      _loadCourseStats(userId, courses);
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
        _errorMsg  = 'Gagal memuat daftar course: $e';
        _isLoading = false;
      });
    }
  }

  // ─── Filter ───────────────────────────────────────────────────────────────────

  List<Course> get _filteredCourses {
    if (_searchQuery.isEmpty) return _courses;
    final q = _searchQuery.toLowerCase();
    return _courses.where((c) {
      return c.fullname.toLowerCase().contains(q) ||
             c.shortname.toLowerCase().contains(q) ||
             c.categoryname.toLowerCase().contains(q);
    }).toList();
  }

  // ─── Logout ───────────────────────────────────────────────────────────────────

  Future<void> _logout() async {
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

    if (!mounted) return;
    bool? confirmed;
    if (fetch.password.isNotEmpty) {
      confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const ExitPasswordDialog(),
      );
    } else {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Keluar',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          content: const Text('Yakin ingin keluar dari aplikasi?'),
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
                backgroundColor: const Color(0xFFDC2626),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Keluar'),
            ),
          ],
        ),
      );
    }

    if (confirmed == true) {
      await KioskController.instance.unlock();
      await AuthService.logout();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _loadCourseStats(int userId, List<Course> courses) async {
    if (userId <= 0 || courses.isEmpty) return;
    try {
      final rawQuizzes = await ApiService.getQuizzesForCourses(
        courses.map((c) => c.id).toList(),
      );
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      const daySec = 86400;

      final relevantQuizzes = <({int quizId, int courseId})>[];
      final statsByCourse = <int, ({int finished, int inProgress})>{};

      for (final q in rawQuizzes) {
        final visible = q['visible'] == 1 || q['visible'] == true;
        if (!visible) continue;
        final qid = (q['id'] as num?)?.toInt() ?? 0;
        final cid = (q['course'] as num?)?.toInt() ?? 0;
        if (qid <= 0 || cid <= 0) continue;

        final timeOpen = (q['timeopen'] as num?)?.toInt() ?? 0;
        final timeClose = (q['timeclose'] as num?)?.toInt() ?? 0;
        final openOk = timeOpen == 0 || nowSec >= timeOpen;
        final closeRecentOrOpen = timeClose == 0 || nowSec <= (timeClose + daySec);
        if (openOk && closeRecentOrOpen) {
          relevantQuizzes.add((quizId: qid, courseId: cid));
        }
      }

      if (relevantQuizzes.isNotEmpty) {
        var nextIdx = 0;
        final workerCount = relevantQuizzes.length < 2 ? relevantQuizzes.length : 2;
        Future<void> worker() async {
          while (true) {
            if (nextIdx >= relevantQuizzes.length) break;
            final item = relevantQuizzes[nextIdx++];
            try {
              final attempts = await ApiService.getUserQuizAttempts(item.quizId, userId);
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
              final prev = statsByCourse[item.courseId] ?? (finished: 0, inProgress: 0);
              statsByCourse[item.courseId] = (
                finished: prev.finished + fin,
                inProgress: prev.inProgress + inp,
              );
            } catch (_) {}
          }
        }
        await Future.wait(List.generate(workerCount, (_) => worker()));
      }

      if (mounted) {
        setState(() {
          for (final c in courses) {
            _courseStats[c.id] = statsByCourse[c.id] ?? (finished: 0, inProgress: 0);
          }
        });
      }
    } catch (_) {}
  }

  // ─── Navigate ke QuizList ─────────────────────────────────────────────────────

  Future<void> _openCourse(Course course) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QuizListScreen(
          courseId:   course.id,
          courseName: course.fullname,
        ),
      ),
    );
    if (_userId > 0 && _courses.isNotEmpty) {
      _loadCourseStats(_userId, _courses);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F5F9),
        appBar: _buildAppBar(),
        body: RefreshIndicator(
          onRefresh: _loadCourses,
          color:     const Color(0xFF1E3A8A),
          child:     _buildBody(),
        ),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            border: Border(
              top: BorderSide(color: Color(0xFFF59E0B), width: 1.5),
            ),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            10 + MediaQuery.of(context).padding.bottom,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFF59E0B), width: 1.2),
                ),
                child: ClipOval(
                  child: Image.asset('assets/icon/app_icon_1024.png', fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'EXAM DOSMAN  •  SMA Negeri 1 Gianyar',
                style: TextStyle(
                  color: Color(0xFFCBD5E1),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── AppBar ───────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor:  const Color(0xFF0F172A),
      foregroundColor:  Colors.white,
      elevation:        0,
      automaticallyImplyLeading: false,
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFF59E0B), width: 1.8),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                  blurRadius: 8,
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset('assets/icon/app_icon_1024.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'EXAM DOSMAN',
              style: TextStyle(
                fontSize:   17,
                fontWeight: FontWeight.w800,
                color:      Colors.white,
                letterSpacing: 0.8,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: ElevatedButton.icon(
            onPressed: _logout,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              elevation: 0,
            ),
            icon: const Icon(Icons.logout_rounded, size: 17),
            label: const Text(
              'Keluar',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
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
    if (_isLoading)         return _buildLoading();
    if (_errorMsg.isNotEmpty) return _buildError();
    if (_courses.isEmpty)   return _buildEmpty();
    return _buildCourseList();
  }

  // ─── Loading Skeleton ────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return GridView.builder(
      padding:    const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount:   2,
        crossAxisSpacing: 12,
        mainAxisSpacing:  12,
        childAspectRatio: 0.9,
      ),
      itemCount:   6,
      itemBuilder: (_, __) => const _SkeletonCard(),
    );
  }

  // ─── Error State ──────────────────────────────────────────────────────────────

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
              onPressed: _loadCourses,
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

  // ─── Empty State ──────────────────────────────────────────────────────────────

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📚', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            const Text(
              'Belum Ada Course',
              style: TextStyle(
                fontSize:   18,
                fontWeight: FontWeight.w700,
                color:      Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Kamu belum terdaftar di course manapun.\nHubungi guru untuk mendaftarkan kamu.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color:    Colors.grey.shade500,
                height:   1.6,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _loadCourses,
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

  // ─── Course Grid ──────────────────────────────────────────────────────────────

  Widget _buildCourseList() {
    final filtered = _filteredCourses;

    return Column(
      children: [
        // ── Banner Selamat Datang Mewah + Search bar ─────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0F172A), Color(0xFF1E3A5F)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Builder(
                      builder: (_) {
                        final parsed = AuthService.parseNameAndClass(_fullname, _department);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Selamat Datang,',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF93C5FD),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              parsed.name,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.25,
                              ),
                              softWrap: true,
                            ),
                            if (parsed.studentClass.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Text(
                                  'Kelas: ${parsed.studentClass}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFE2E8F0),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_user_rounded, color: Color(0xFFFBBF24), size: 14),
                        SizedBox(width: 4),
                        Text(
                          'Mode Ujian',
                          style: TextStyle(
                            color: Color(0xFFFDE68A),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Search bar mengambang
              TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
                decoration: InputDecoration(
                  hintText: 'Cari mata pelajaran ujian...',
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF94A3B8),
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: Color(0xFF64748B),
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          color: const Color(0xFF64748B),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ],
          ),
        ),

        // ── Course count info ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Row(
            children: [
              const Icon(Icons.layers_rounded, size: 15, color: Color(0xFF475569)),
              const SizedBox(width: 6),
              Text(
                _searchQuery.isEmpty
                    ? '${_courses.length} Mata Pelajaran Tersedia'
                    : '${filtered.length} dari ${_courses.length} Mata Pelajaran',
                style: const TextStyle(
                  fontSize:   12,
                  color:      Color(0xFF475569),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),

        // ── Daftar Course Elegan ─────────────────────────────────────────────
        Expanded(
          child: filtered.isEmpty
              ? _buildNoResult()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final course = filtered[index];
                    final stat = _courseStats[course.id];
                    return CourseCard(
                      course:           course,
                      onTap:            () => _openCourse(course),
                      colorIndex:       _courses.indexOf(course),
                      finishedAttempts: stat?.finished,
                      inProgressCount:  stat?.inProgress,
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ─── No Result ────────────────────────────────────────────────────────────────

  Widget _buildNoResult() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 12),
          Text(
            'Tidak ada course\nyang cocok dengan "$_searchQuery"',
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

// ─── Skeleton Card ────────────────────────────────────────────────────────────

class _SkeletonCard extends StatefulWidget {
  const _SkeletonCard();

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
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Banner
            Container(
              height: 8,
              decoration: BoxDecoration(
                color:        Colors.grey.shade300,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Judul
                  Container(
                    height: 14,
                    width:  double.infinity,
                    decoration: BoxDecoration(
                      color:        Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 14,
                    width:  120,
                    decoration: BoxDecoration(
                      color:        Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Kode
                  Container(
                    height: 11,
                    width:  80,
                    decoration: BoxDecoration(
                      color:        Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Tombol
                  Container(
                    height: 28,
                    width:  double.infinity,
                    decoration: BoxDecoration(
                      color:        Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
