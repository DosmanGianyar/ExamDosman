// ===========================
// DOSMAN UJIAN - Offline Quiz Service (Android Semi-Offline MCQ)
// Mengunduh soal Pilihan Ganda saat Start Quiz, menyimpan lokal,
// dan mengirim seluruh jawaban secara batch saat Submit.
// ===========================

import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'api_service.dart';
import 'auth_service.dart';

enum SubmitErrorAction {
  alreadyFinished,
  outOfSequence,
  authBlocked,
  retryableNetwork,
}

class OfflineOption {
  final String value;
  final String labelLetter; // A, B, C, D, E
  final String html;

  const OfflineOption({
    required this.value,
    required this.labelLetter,
    required this.html,
  });

  Map<String, dynamic> toJson() => {
        'value': value,
        'labelLetter': labelLetter,
        'html': html,
      };

  factory OfflineOption.fromJson(Map<String, dynamic> j) => OfflineOption(
        value: j['value'] as String? ?? '',
        labelLetter: j['labelLetter'] as String? ?? '',
        html: j['html'] as String? ?? '',
      );
}

class OfflineQuestion {
  final int slot;
  final int number;
  final String type;
  final String questionHtml;
  final String answerFieldName;
  final String sequenceCheckName;
  String sequenceCheckValue;
  final List<OfflineOption> options;
  String? selectedValue;
  bool isFlagged;

  OfflineQuestion({
    required this.slot,
    required this.number,
    required this.type,
    required this.questionHtml,
    required this.answerFieldName,
    required this.sequenceCheckName,
    required this.sequenceCheckValue,
    required this.options,
    this.selectedValue,
    this.isFlagged = false,
  });

  Map<String, dynamic> toJson() => {
        'slot': slot,
        'number': number,
        'type': type,
        'questionHtml': questionHtml,
        'answerFieldName': answerFieldName,
        'sequenceCheckName': sequenceCheckName,
        'sequenceCheckValue': sequenceCheckValue,
        'options': options.map((o) => o.toJson()).toList(),
        'selectedValue': selectedValue,
        'isFlagged': isFlagged,
      };

  factory OfflineQuestion.fromJson(Map<String, dynamic> j) => OfflineQuestion(
        slot: (j['slot'] as num?)?.toInt() ?? 0,
        number: (j['number'] as num?)?.toInt() ?? 0,
        type: j['type'] as String? ?? 'multichoice',
        questionHtml: j['questionHtml'] as String? ?? '',
        answerFieldName: j['answerFieldName'] as String? ?? '',
        sequenceCheckName: j['sequenceCheckName'] as String? ?? '',
        sequenceCheckValue: j['sequenceCheckValue'] as String? ?? '1',
        options: (j['options'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(OfflineOption.fromJson)
            .toList(),
        selectedValue: j['selectedValue'] as String?,
        isFlagged: j['isFlagged'] == true,
      );
}

class OfflineQuizPackage {
  final int quizId;
  final int courseId;
  final int attemptId;
  final int userId;
  final String quizName;
  final int endTimeEpochSec; // 0 jika tanpa batas waktu
  final int parserVersion;
  final List<OfflineQuestion> questions;

  OfflineQuizPackage({
    required this.quizId,
    required this.courseId,
    required this.attemptId,
    required this.userId,
    required this.quizName,
    required this.endTimeEpochSec,
    required this.questions,
    this.parserVersion = 1,
  });

  Map<String, dynamic> toJson() => {
        'quizId': quizId,
        'courseId': courseId,
        'attemptId': attemptId,
        'userId': userId,
        'quizName': quizName,
        'endTimeEpochSec': endTimeEpochSec,
        'parserVersion': parserVersion,
        'questions': questions.map((q) => q.toJson()).toList(),
      };

  factory OfflineQuizPackage.fromJson(Map<String, dynamic> j) => OfflineQuizPackage(
        quizId: (j['quizId'] as num?)?.toInt() ?? 0,
        courseId: (j['courseId'] as num?)?.toInt() ?? 0,
        attemptId: (j['attemptId'] as num?)?.toInt() ?? 0,
        userId: (j['userId'] as num?)?.toInt() ?? 0,
        quizName: j['quizName'] as String? ?? 'Ujian',
        endTimeEpochSec: (j['endTimeEpochSec'] as num?)?.toInt() ?? 0,
        parserVersion: (j['parserVersion'] as num?)?.toInt() ?? 1,
        questions: (j['questions'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(OfflineQuestion.fromJson)
            .toList(),
      );
}

class OfflineQuizService {
  OfflineQuizService._();

  static const int kCurrentParserVersion = 2;

  static const _storage = FlutterSecureStorage();

  static String _answersKey(int userId, int quizId) =>
      'dosman_offline_ans_${userId}_$quizId';

  static String? _cachedBaseDir;

  /// Gunakan direktori permanen aplikasi (filesDir) agar tidak ikut terhapus
  /// oleh fitur pembersih cache bawaan HP (Xiaomi/Oppo/Vivo).
  static Future<String> _getStorageDir() async {
    if (_cachedBaseDir != null) return _cachedBaseDir!;
    try {
      final dir = await const MethodChannel(AppConfig.lockdownChannel)
          .invokeMethod<String>('getAppFilesDir');
      if (dir != null && dir.isNotEmpty) {
        _cachedBaseDir = dir;
        return dir;
      }
    } catch (_) {}
    _cachedBaseDir = Directory.systemTemp.path;
    return _cachedBaseDir!;
  }

  static Future<File> _packageFile(int userId, int quizId) async {
    final dir = await _getStorageDir();
    return File('$dir/dosman_offline_pkg_${userId}_$quizId.json');
  }

  /// Cek apakah sudah ada paket soal tersimpan untuk [userId] & [quizId].
  static Future<OfflineQuizPackage?> loadSavedPackage({
    required int userId,
    required int quizId,
  }) async {
    try {
      final f = await _packageFile(userId, quizId);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final pkg = OfflineQuizPackage.fromJson(
        json.decode(raw) as Map<String, dynamic>,
      );

      // Pulihkan jawaban & flag terbaru dari SecureStorage jika ada
      final ansRaw = await _storage.read(key: _answersKey(userId, quizId));
      if (ansRaw != null && ansRaw.isNotEmpty) {
        final ansMap = json.decode(ansRaw) as Map<String, dynamic>;
        for (final q in pkg.questions) {
          final saved = ansMap['${q.slot}'];
          if (saved is Map<String, dynamic>) {
            q.selectedValue = saved['v'] as String?;
            q.isFlagged = saved['f'] == true;
          }
        }
      }
      return pkg;
    } catch (_) {
      return null;
    }
  }

  /// Simpan paket soal lengkap ke file lokal.
  static Future<void> savePackage(OfflineQuizPackage pkg) async {
    try {
      final f = await _packageFile(pkg.userId, pkg.quizId);
      await f.writeAsString(json.encode(pkg.toJson()));
      await saveAnswersState(pkg);
    } catch (_) {}
  }

  /// Simpan jawaban & status ragu-ragu secara instan ke SecureStorage.
  static Future<void> saveAnswersState(OfflineQuizPackage pkg) async {
    try {
      final map = <String, dynamic>{};
      for (final q in pkg.questions) {
        map['${q.slot}'] = {
          'v': q.selectedValue,
          'f': q.isFlagged,
        };
      }
      await _storage.write(
        key: _answersKey(pkg.userId, pkg.quizId),
        value: json.encode(map),
      );
    } catch (_) {}
  }

  /// Hapus paket soal & jawaban lokal setelah berhasil disubmit ke server.
  static Future<void> clearSavedPackage({
    required int userId,
    required int quizId,
  }) async {
    try {
      final f = await _packageFile(userId, quizId);
      if (await f.exists()) await f.delete();
      await _storage.delete(key: _answersKey(userId, quizId));
    } catch (_) {}
  }

  /// Cari paket ujian lokal milik [userId] yang belum disubmit (untuk auto-recovery).
  static Future<List<OfflineQuizPackage>> findPendingPackages(int userId) async {
    final result = <OfflineQuizPackage>[];
    if (userId <= 0) return result;
    try {
      final prefix = 'dosman_offline_pkg_${userId}_';
      final baseDir = await _getStorageDir();
      final dir = Directory(baseDir);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(prefix) || !name.endsWith('.json')) continue;
        final quizIdStr = name.substring(prefix.length, name.length - 5);
        final quizId = int.tryParse(quizIdStr) ?? 0;
        if (quizId > 0) {
          final pkg = await loadSavedPackage(userId: userId, quizId: quizId);
          if (pkg != null && pkg.questions.isNotEmpty) {
            result.add(pkg);
          }
        }
      }
    } catch (_) {}
    return result;
  }

  /// Download paket soal dari Moodle tepat saat siswa klik Start Quiz.
  static Future<OfflineQuizPackage> downloadQuizPackage({
    required int quizId,
    required int courseId,
    required int userId,
    required String quizName,
    required int timeLimitSec,
    required int timeCloseEpochSec,
    String? quizPassword,
    void Function(String status, double progress)? onProgress,
  }) async {
    onProgress?.call('Menyiapkan ujian...', 0.05);

    // 1. Cek apakah ada attempt inprogress yang bisa dilanjutkan
    Map<String, dynamic>? activeAttempt;
    final attempts = await ApiService.getUserQuizAttempts(quizId, userId);
    for (final a in attempts) {
      if ((a['state'] as String? ?? '').toLowerCase() == 'inprogress') {
        activeAttempt = a;
        break;
      }
    }

    // Jika paket lokal untuk attempt inprogress tersebut sudah ada & parser masih terkini, langsung pakai!
    Map<int, ({String? v, bool f})>? preservedAnswers;
    if (activeAttempt != null) {
      final attId = (activeAttempt['id'] as num?)?.toInt() ?? 0;
      final existing = await loadSavedPackage(userId: userId, quizId: quizId);
      if (existing != null && existing.attemptId == attId && existing.questions.isNotEmpty) {
        if (existing.parserVersion >= kCurrentParserVersion) {
          onProgress?.call('Melanjutkan sesi ujian...', 1.0);
          return existing;
        }
        // Paket berasal dari parser versi lama: simpan jawaban & flag lalu re-download & re-parse.
        preservedAnswers = {
          for (final q in existing.questions)
            q.slot: (v: q.selectedValue, f: q.isFlagged),
        };
      }
    }

    // 2. Mulai attempt baru jika belum ada
    activeAttempt ??= await ApiService.startQuizAttempt(
      quizId,
      quizPassword: quizPassword,
    );

    final attemptId = (activeAttempt['id'] as num?)?.toInt() ?? 0;
    if (attemptId <= 0) {
      throw ApiException('ID attempt kuis tidak valid.');
    }

    // Hitung waktu selesai (endTime)
    final timeStart = (activeAttempt['timestart'] as num?)?.toInt() ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    int endTime = 0;
    if (timeLimitSec > 0) {
      endTime = timeStart + timeLimitSec;
    }
    if (timeCloseEpochSec > 0 && (endTime == 0 || timeCloseEpochSec < endTime)) {
      endTime = timeCloseEpochSec;
    }

    // 3. Unduh semua halaman soal dengan mod_quiz_get_attempt_data
    final token = await AuthService.getToken() ?? '';
    final rawQuestions = <Map<String, dynamic>>[];
    int page = 0;
    int safetyGuard = 0;

    while (page >= 0 && safetyGuard < 150) {
      safetyGuard++;
      onProgress?.call('Menyiapkan lembar soal ${page + 1}...', 0.15 + (safetyGuard * 0.03).clamp(0.0, 0.45));
      final pageData = await ApiService.getQuizAttemptData(
        attemptId,
        page,
        quizPassword: quizPassword,
      );
      final qList = pageData['questions'] as List<dynamic>? ?? [];
      for (final q in qList) {
        if (q is Map<String, dynamic>) {
          rawQuestions.add(q);
        }
      }
      final nextPage = (pageData['nextpage'] as num?)?.toInt() ?? -1;
      if (nextPage <= page || nextPage < 0) break;
      page = nextPage;
    }

    if (rawQuestions.isEmpty) {
      throw ApiException('Tidak ada soal ditemukan pada kuis ini.');
    }

    // 4. Parse tiap soal Pilihan Ganda dulu (tanpa jaringan), lalu unduh gambar unik secara paralel (maks 4)
    final imageCache = <String, String>{};
    final draftQuestions = <OfflineQuestion>[];
    final imageUrls = <String>{};
    for (var i = 0; i < rawQuestions.length; i++) {
      onProgress?.call(
        'Menyiapkan soal ${i + 1} dari ${rawQuestions.length}...',
        0.55 + (0.05 * (i + 1) / rawQuestions.length),
      );
      final q = await parseMoodleQuestion(
        rawQuestions[i],
        i + 1,
        inlineImages: false,
      );
      draftQuestions.add(q);
      imageUrls.addAll(_extractExternalImageUrls(q.questionHtml));
      for (final opt in q.options) {
        imageUrls.addAll(_extractExternalImageUrls(opt.html));
      }
    }

    if (imageUrls.isNotEmpty) {
      await _prefetchImages(
        imageUrls,
        token,
        imageCache,
        onImageProgress: (done, total) {
          onProgress?.call(
            'Menyiapkan gambar $done dari $total...',
            0.60 + (0.36 * done / total),
          );
        },
      );
    }

    final parsed = draftQuestions.map((q) {
      final inlinedQ = imageCache.isEmpty
          ? q.questionHtml
          : _replaceCachedImages(q.questionHtml, imageCache);
      final inlinedOpts = imageCache.isEmpty
          ? q.options
          : q.options
              .map(
                (o) => OfflineOption(
                  value: o.value,
                  labelLetter: o.labelLetter,
                  html: _replaceCachedImages(o.html, imageCache),
                ),
              )
              .toList();
      return OfflineQuestion(
        slot: q.slot,
        number: q.number,
        type: q.type,
        questionHtml: inlinedQ,
        answerFieldName: q.answerFieldName,
        sequenceCheckName: q.sequenceCheckName,
        sequenceCheckValue: q.sequenceCheckValue,
        options: inlinedOpts,
        selectedValue: q.selectedValue,
        isFlagged: q.isFlagged,
      );
    }).toList();

    if (preservedAnswers != null) {
      for (final q in parsed) {
        final prev = preservedAnswers[q.slot];
        if (prev != null) {
          q.selectedValue ??= prev.v;
          if (prev.f) q.isFlagged = true;
        }
      }
    }

    // Pulihkan juga dari SecureStorage bila ada jawaban terbaru yang tersimpan
    try {
      final ansRaw = await _storage.read(key: _answersKey(userId, quizId));
      if (ansRaw != null && ansRaw.isNotEmpty) {
        final ansMap = json.decode(ansRaw) as Map<String, dynamic>;
        for (final q in parsed) {
          final saved = ansMap['${q.slot}'];
          if (saved is Map<String, dynamic>) {
            final v = saved['v'] as String?;
            if (v != null && v.isNotEmpty) q.selectedValue = v;
            if (saved['f'] == true) q.isFlagged = true;
          }
        }
      }
    } catch (_) {}

    final pkg = OfflineQuizPackage(
      quizId: quizId,
      courseId: courseId,
      attemptId: attemptId,
      userId: userId,
      quizName: quizName,
      endTimeEpochSec: endTime,
      questions: parsed,
      parserVersion: kCurrentParserVersion,
    );

    await savePackage(pkg);
    onProgress?.call('Soal ujian siap!', 1.0);
    return pkg;
  }

  /// Klasifikasikan error saat mengirim jawaban batch agar UI tidak terjebak loop abadi.
  static SubmitErrorAction classifySubmitError(Object error) {
    if (error is TokenExpiredException) {
      return SubmitErrorAction.authBlocked;
    }
    if (error is ApiException) {
      final code = (error.errorCode ?? '').toLowerCase();
      final msg = error.message.toLowerCase();
      if (code == 'attemptalreadyclosed' ||
          msg.contains('already been finished') ||
          msg.contains('sudah selesai')) {
        return SubmitErrorAction.alreadyFinished;
      }
      if (code.contains('outofsequence') ||
          msg.contains('outside the normal sequence')) {
        return SubmitErrorAction.outOfSequence;
      }
      if (code == 'invalidtoken' ||
          code == 'accessdenied' ||
          msg.contains('suspended') ||
          msg.contains('refused web service')) {
        return SubmitErrorAction.authBlocked;
      }
      return SubmitErrorAction.retryableNetwork;
    }
    return SubmitErrorAction.retryableNetwork;
  }

  /// Ambil ulang nilai `sequencecheck` terkini dari server untuk attempt [pkg.attemptId]
  /// tanpa mengubah jawaban & tanda ragu yang sudah dipilih siswa secara lokal.
  static Future<String> refreshSequenceChecks(
    OfflineQuizPackage pkg, {
    String? quizPassword,
  }) async {
    final attempts = await ApiService.getUserQuizAttempts(pkg.quizId, pkg.userId);
    for (final a in attempts) {
      final id = (a['id'] as num?)?.toInt() ?? 0;
      if (id == pkg.attemptId) {
        final st = (a['state'] as String? ?? '').toLowerCase();
        if (st == 'finished' || st == 'overdue' || st == 'abandoned') {
          return st;
        }
        break;
      }
    }

    final freshSeqBySlot = <int, String>{};
    int page = 0;
    int safetyGuard = 0;
    while (page >= 0 && safetyGuard < 150) {
      safetyGuard++;
      final pageData = await ApiService.getQuizAttemptData(
        pkg.attemptId,
        page,
        quizPassword: quizPassword,
      );
      final qList = pageData['questions'] as List<dynamic>? ?? [];
      for (final raw in qList) {
        if (raw is! Map<String, dynamic>) continue;
        final slot = (raw['slot'] as num?)?.toInt();
        if (slot == null) continue;
        final seq = _extractSequenceCheck(raw);
        if (seq.value.isNotEmpty) {
          freshSeqBySlot[slot] = seq.value;
        }
      }
      final nextPage = (pageData['nextpage'] as num?)?.toInt() ?? -1;
      if (nextPage <= page || nextPage < 0) break;
      page = nextPage;
    }

    if (freshSeqBySlot.isNotEmpty) {
      for (final q in pkg.questions) {
        final fresh = freshSeqBySlot[q.slot];
        if (fresh != null && fresh.isNotEmpty) {
          q.sequenceCheckValue = fresh;
        }
      }
      await savePackage(pkg);
    }
    return 'inprogress';
  }

  /// Bangun payload `data` untuk `mod_quiz_process_attempt` dari paket lokal.
  static List<Map<String, String>> buildSubmitPayload(OfflineQuizPackage pkg) {
    final payload = <Map<String, String>>[];
    for (final q in pkg.questions) {
      if (q.sequenceCheckName.isNotEmpty) {
        payload.add({
          'name': q.sequenceCheckName,
          'value': q.sequenceCheckValue,
        });
      }
      if (q.answerFieldName.isNotEmpty && q.selectedValue != null) {
        payload.add({
          'name': q.answerFieldName,
          'value': q.selectedValue!,
        });
      }
    }
    return payload;
  }

  // ─── Parser HTML Soal Pilihan Ganda Moodle ────────────────────────────────

  static final RegExp _htmlTagScanRegex = RegExp(
    r'''<!--[\s\S]*?-->|<(/?)([a-zA-Z0-9]+)((?:[^>"'/]|"[^"]*"|'[^']*'|/(?!>))*)(/?)>''',
  );

  static const Set<String> _pairedHtmlTags = <String>{
    'div', 'p', 'span', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th',
    'ul', 'ol', 'li', 'b', 'strong', 'i', 'em', 'u', 's', 'sub', 'sup',
    'font', 'blockquote', 'section', 'article', 'center', 'pre', 'code',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'a', 'small', 'big', 'label',
    'fieldset',
  };

  static const Set<String> _voidHtmlTags = <String>{
    'br', 'img', 'hr', 'input', 'wbr', 'col', 'source', 'meta', 'link',
    'area', 'base', 'embed', 'param', 'track',
  };

  /// Ekstrak innerHTML dari elemen yang cocok dengan [openTagPattern] dengan menghitung
  /// kedalaman tag buka/tutup secara seimbang agar nested <div> tidak memotong isi.
  static String? extractBalancedElementInnerHtml(
    String html,
    RegExp openTagPattern,
  ) {
    final firstMatch = openTagPattern.firstMatch(html);
    if (firstMatch == null) return null;

    final matchedTag = firstMatch.group(0) ?? '';
    final tagNameMatch = RegExp(r'^<\s*([a-zA-Z0-9]+)').firstMatch(matchedTag);
    if (tagNameMatch == null) return null;
    final targetTag = tagNameMatch.group(1)!.toLowerCase();

    final contentStart = firstMatch.end;
    if (matchedTag.trimRight().endsWith('/>')) {
      return '';
    }

    var depth = 1;
    for (final m in _htmlTagScanRegex.allMatches(html, contentStart)) {
      final rawTag = m.group(2);
      if (rawTag == null) continue; // Komentar HTML
      final tagName = rawTag.toLowerCase();
      if (tagName != targetTag) continue;

      final isClose = m.group(1) == '/';
      final isSelfClosing = m.group(4) == '/';
      if (isClose) {
        depth--;
        if (depth == 0) {
          return html.substring(contentStart, m.start);
        }
      } else if (!isSelfClosing) {
        depth++;
      }
    }
    return html.substring(contentStart);
  }

  /// Bersihkan komentar MS Word / HTML serta seimbangkan tag buka/tutup agar fragmen
  /// soal maupun opsi jawaban tidak merusak struktur kartu di WebView.
  static String sanitizeFragmentHtml(String html) {
    final cleaned = html
        .replaceAll(
          RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

    final buf = StringBuffer();
    final stack = <String>[];
    var lastIdx = 0;

    for (final m in _htmlTagScanRegex.allMatches(cleaned)) {
      if (m.start > lastIdx) {
        buf.write(cleaned.substring(lastIdx, m.start));
      }
      lastIdx = m.end;

      final isClose = m.group(1) == '/';
      final rawTag = m.group(2);
      if (rawTag == null) continue;
      final tag = rawTag.toLowerCase();
      final isSelfClosing = m.group(4) == '/';

      if (_voidHtmlTags.contains(tag) || (!isClose && isSelfClosing)) {
        buf.write(m.group(0));
        continue;
      }

      if (!_pairedHtmlTags.contains(tag)) {
        buf.write(m.group(0));
        continue;
      }

      if (!isClose) {
        stack.add(tag);
        buf.write(m.group(0));
      } else {
        final idx = stack.lastIndexOf(tag);
        if (idx == -1) {
          // Buang tag penutup liar tanpa pasangan pembuka
          continue;
        }
        while (stack.length - 1 > idx) {
          final unclosed = stack.removeLast();
          buf.write('</$unclosed>');
        }
        stack.removeLast();
        buf.write('</$tag>');
      }
    }

    if (lastIdx < cleaned.length) {
      buf.write(cleaned.substring(lastIdx));
    }
    while (stack.isNotEmpty) {
      final unclosed = stack.removeLast();
      buf.write('</$unclosed>');
    }
    return buf.toString();
  }

  static Future<OfflineQuestion> parseMoodleQuestionWithoutNetwork(
    Map<String, dynamic> raw,
    int fallbackNumber,
  ) =>
      parseMoodleQuestion(raw, fallbackNumber, inlineImages: false);

  static ({String name, String value}) _extractSequenceCheck(
    Map<String, dynamic> raw,
  ) {
    final html = raw['html'] as String? ?? '';
    final seqCheckNum = (raw['sequencecheck'] as num?)?.toInt() ?? 1;
    var seqName = '';
    var seqVal = '$seqCheckNum';
    final seqMatch = RegExp(
      r'''<input[^>]*name=["']([^"']*:sequencecheck)["'][^>]*value=["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (seqMatch != null) {
      seqName = seqMatch.group(1) ?? '';
      seqVal = seqMatch.group(2) ?? '$seqCheckNum';
    } else {
      final seqMatchRev = RegExp(
        r'''<input[^>]*value=["']([^"']*)["'][^>]*name=["']([^"']*:sequencecheck)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (seqMatchRev != null) {
        seqVal = seqMatchRev.group(1) ?? '$seqCheckNum';
        seqName = seqMatchRev.group(2) ?? '';
      }
    }
    return (name: seqName, value: seqVal);
  }

  static Future<OfflineQuestion> parseMoodleQuestion(
    Map<String, dynamic> raw,
    int fallbackNumber, {
    String token = '',
    Map<String, String>? imageCache,
    bool inlineImages = true,
  }) async {
    final slot = (raw['slot'] as num?)?.toInt() ?? fallbackNumber;
    final number = int.tryParse('${raw['number'] ?? ''}') ?? fallbackNumber;
    final type = (raw['type'] as String? ?? 'multichoice').toLowerCase();
    final html = raw['html'] as String? ?? '';

    // Ekstrak input hidden sequencecheck: name="q123:1_:sequencecheck" value="1"
    final seqInfo = _extractSequenceCheck(raw);
    var seqName = seqInfo.name;
    final seqVal = seqInfo.value;

    // Ekstrak bagian teks soal (<div class="qtext">...</div>) dengan balanced tag extractor
    String qtextHtml = extractBalancedElementInnerHtml(
          html,
          RegExp(
            r'''<div\b[^>]*class=["'][^"']*\bqtext\b[^"']*["'][^>]*>''',
            caseSensitive: false,
          ),
        ) ??
        '';
    if (qtextHtml.isEmpty) {
      final blockMatch = RegExp(
        r'''<(?:fieldset|div)\b[^>]*class=["'][^"']*\b(?:ablock|answer)\b''',
        caseSensitive: false,
      ).firstMatch(html);
      qtextHtml = blockMatch != null ? html.substring(0, blockMatch.start) : html;
    }

    qtextHtml = sanitizeFragmentHtml(qtextHtml).trim();
    if (inlineImages) {
      qtextHtml = await _inlineImages(
        qtextHtml,
        token,
        imageCache ?? <String, String>{},
      );
    }

    // Ekstrak semua opsi radio (<input type="radio" ...>)
    String answerFieldName = '';
    String? preselected;
    final options = <OfflineOption>[];

    // Cari blok <div class="answer">...</div> secara balanced
    String ansArea = extractBalancedElementInnerHtml(
          html,
          RegExp(
            r'''<div\b[^>]*class=["'][^"']*\banswer\b[^"']*["'][^>]*>''',
            caseSensitive: false,
          ),
        ) ??
        '';
    if (ansArea.isEmpty) {
      final ansBlockMatch = RegExp(
        r'''<div[^>]*class=["'][^"']*\banswer\b[^"']*["'][^>]*>([\s\S]*)$''',
        caseSensitive: false,
      ).firstMatch(html);
      ansArea = ansBlockMatch?.group(1) ?? html;
    }

    // Pecah per opsi berdasarkan kemunculan <input ... type="radio" ...>
    final radioRegex = RegExp(
      r'''<input\b[^>]*type=["']radio["'][^>]*>''',
      caseSensitive: false,
    );
    final matches = radioRegex.allMatches(ansArea).toList();

    for (var i = 0; i < matches.length; i++) {
      final tag = matches[i].group(0) ?? '';
      final nameM = RegExp(r'''name=["']([^"']+)["']''').firstMatch(tag);
      final valM = RegExp(r'''value=["']([^"']*)["']''').firstMatch(tag);
      final nameAttr = nameM?.group(1) ?? '';
      final valAttr = valM?.group(1) ?? '$i';

      // Abaikan radio clear-choice (-1)
      if (valAttr == '-1') continue;

      if (answerFieldName.isEmpty && nameAttr.isNotEmpty) {
        answerFieldName = nameAttr;
      }
      if (RegExp(r'\bchecked\b', caseSensitive: false).hasMatch(tag)) {
        preselected = valAttr;
      }

      // Ambil potongan HTML dari setelah <input> ini sampai <input> berikutnya (atau akhir blok)
      final startIdx = matches[i].end;
      final endIdx = (i + 1 < matches.length) ? matches[i + 1].start : ansArea.length;
      var chunk = ansArea.substring(startIdx, endIdx);

      // Potong penutup div container opsi berlebih jika ada "Prompt / Clear my choice"
      final clearIdx = chunk.indexOf('qtype_multichoice_clearchoice');
      if (clearIdx != -1) {
        chunk = chunk.substring(0, clearIdx);
      }

      // Ambil isi di dalam <div class="flex-fill..."> atau <label ...> dengan balanced tag extractor
      String optHtml = extractBalancedElementInnerHtml(
            chunk,
            RegExp(
              r'''<div\b[^>]*class=["'][^"']*\bflex-fill\b[^"']*["'][^>]*>''',
              caseSensitive: false,
            ),
          ) ??
          extractBalancedElementInnerHtml(
            chunk,
            RegExp(r'''<label\b[^>]*>''', caseSensitive: false),
          ) ??
          chunk;

      // Ekstrak huruf opsi jika ada <span class="answernumber">a. </span>
      String letter = String.fromCharCode(65 + options.length); // A, B, C...
      final numSpan = RegExp(
        r'''<span[^>]*class=["'][^"']*answernumber[^"']*["'][^>]*>([\s\S]*?)</span>''',
        caseSensitive: false,
      ).firstMatch(chunk);
      if (numSpan != null) {
        final rawLetter = (numSpan.group(1) ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('.', '')
            .trim()
            .toUpperCase();
        if (rawLetter.isNotEmpty) letter = rawLetter;
        optHtml = optHtml.replaceAll(numSpan.group(0)!, '');
      }

      optHtml = sanitizeFragmentHtml(optHtml).trim();
      if (inlineImages) {
        optHtml = await _inlineImages(
          optHtml,
          token,
          imageCache ?? <String, String>{},
        );
      }

      options.add(OfflineOption(
        value: valAttr,
        labelLetter: letter,
        html: optHtml,
      ));
    }

    if (seqName.isEmpty && answerFieldName.isNotEmpty) {
      seqName = answerFieldName.replaceFirst(RegExp(r'_answer$'), '_:sequencecheck');
    }

    return OfflineQuestion(
      slot: slot,
      number: number,
      type: type,
      questionHtml: qtextHtml,
      answerFieldName: answerFieldName,
      sequenceCheckName: seqName,
      sequenceCheckValue: seqVal,
      options: options,
      selectedValue: preselected,
    );
  }

  static const int kImageConcurrency = 4;

  static final RegExp _imgSrcRegex = RegExp(
    r'''<img\b[^>]*\bsrc=["']([^"']+)["'][^>]*>''',
    caseSensitive: false,
  );

  /// Ekstrak seluruh URL gambar eksternal (non-data-URI) unik dari fragmen HTML.
  static List<String> _extractExternalImageUrls(String html) {
    final urls = <String>[];
    for (final m in _imgSrcRegex.allMatches(html)) {
      final rawUrl = (m.group(1) ?? '').replaceAll('&amp;', '&').trim();
      if (rawUrl.isNotEmpty && !rawUrl.startsWith('data:')) {
        urls.add(rawUrl);
      }
    }
    return urls;
  }

  /// Gantikan atribut src gambar pada HTML dengan hasil data URI dari [cache].
  static String _replaceCachedImages(String html, Map<String, String> cache) {
    if (cache.isEmpty) return html;
    return html.replaceAllMapped(_imgSrcRegex, (m) {
      final fullTag = m.group(0) ?? '';
      final rawAttr = m.group(1) ?? '';
      final normalized = rawAttr.replaceAll('&amp;', '&').trim();
      final dataUri = cache[normalized];
      if (dataUri == null || rawAttr.isEmpty) return fullTag;
      return fullTag.replaceFirst(rawAttr, dataUri);
    });
  }

  /// Unduh satu gambar ke data URI base64 (timeout 10 detik + 1x retry jika gagal/5xx).
  static Future<String?> _downloadImageWithRetry(String rawUrl, String token) async {
    var fetchUrl = rawUrl;
    if (fetchUrl.startsWith('/')) {
      fetchUrl = '${AppConfig.moodleUrl}$fetchUrl';
    }
    // Pastikan URL pluginfile menggunakan endpoint webservice + token agar tidak butuh cookie
    if (fetchUrl.contains('/pluginfile.php/') &&
        !fetchUrl.contains('/webservice/pluginfile.php/')) {
      fetchUrl = fetchUrl.replaceFirst(
        '/pluginfile.php/',
        '/webservice/pluginfile.php/',
      );
    }
    if (token.isNotEmpty && !fetchUrl.contains('token=')) {
      final sep = fetchUrl.contains('?') ? '&' : '?';
      fetchUrl = '$fetchUrl${sep}token=${Uri.encodeComponent(token)}';
    }

    final uri = Uri.tryParse(fetchUrl);
    if (uri == null) return null;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final resp = await http
            .get(uri, headers: {'User-Agent': AppConfig.examBrowserUserAgent})
            .timeout(const Duration(seconds: 10));

        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          final ct = _inferImageMimeType(
            fetchUrl,
            resp.bodyBytes,
            resp.headers['content-type'],
          );
          final b64 = base64Encode(resp.bodyBytes);
          return 'data:$ct;base64,$b64';
        }
        if (resp.statusCode < 500) {
          return null;
        }
      } catch (_) {
        // Timeout atau error jaringan → retry sekali setelah jeda singkat
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  /// Unduh kumpulan URL gambar unik menggunakan pool paralel maksimum [kImageConcurrency].
  static Future<void> _prefetchImages(
    Iterable<String> urls,
    String token,
    Map<String, String> cache, {
    void Function(int done, int total)? onImageProgress,
  }) async {
    final pending = urls
        .where((u) => u.isNotEmpty && !u.startsWith('data:') && !cache.containsKey(u))
        .toSet()
        .toList();
    final total = pending.length;
    if (total == 0) return;

    var nextIdx = 0;
    var done = 0;
    final workerCount = total < kImageConcurrency ? total : kImageConcurrency;

    Future<void> worker() async {
      while (true) {
        if (nextIdx >= total) break;
        final url = pending[nextIdx++];
        final dataUri = await _downloadImageWithRetry(url, token);
        if (dataUri != null) {
          cache[url] = dataUri;
        }
        done++;
        onImageProgress?.call(done, total);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  /// Unduh gambar <img src="..."> dari server Moodle dan ubah jadi base64 inline data URI.
  static Future<String> _inlineImages(
    String html,
    String token,
    Map<String, String> cache,
  ) async {
    final urls = _extractExternalImageUrls(html);
    if (urls.isEmpty) return html;
    await _prefetchImages(urls, token, cache);
    return _replaceCachedImages(html, cache);
  }

  static String _inferImageMimeType(
    String url,
    List<int> bytes,
    String? headerContentType,
  ) {
    final headerCt = (headerContentType ?? '').split(';').first.trim().toLowerCase();
    if (headerCt.startsWith('image/')) {
      return headerCt;
    }

    // Cek magic bytes WebP: "RIFF" (0..3) + "WEBP" (8..11)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    final cleanPath = url.split('?').first.split('#').first.toLowerCase();
    if (cleanPath.endsWith('.webp')) return 'image/webp';
    if (cleanPath.endsWith('.jpg') || cleanPath.endsWith('.jpeg')) return 'image/jpeg';
    if (cleanPath.endsWith('.gif')) return 'image/gif';
    if (cleanPath.endsWith('.svg')) return 'image/svg+xml';
    if (cleanPath.endsWith('.bmp')) return 'image/bmp';
    if (cleanPath.endsWith('.avif')) return 'image/avif';
    return 'image/png';
  }
}
