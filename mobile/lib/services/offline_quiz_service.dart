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
  final String sequenceCheckValue;
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
  final List<OfflineQuestion> questions;

  OfflineQuizPackage({
    required this.quizId,
    required this.courseId,
    required this.attemptId,
    required this.userId,
    required this.quizName,
    required this.endTimeEpochSec,
    required this.questions,
  });

  Map<String, dynamic> toJson() => {
        'quizId': quizId,
        'courseId': courseId,
        'attemptId': attemptId,
        'userId': userId,
        'quizName': quizName,
        'endTimeEpochSec': endTimeEpochSec,
        'questions': questions.map((q) => q.toJson()).toList(),
      };

  factory OfflineQuizPackage.fromJson(Map<String, dynamic> j) => OfflineQuizPackage(
        quizId: (j['quizId'] as num?)?.toInt() ?? 0,
        courseId: (j['courseId'] as num?)?.toInt() ?? 0,
        attemptId: (j['attemptId'] as num?)?.toInt() ?? 0,
        userId: (j['userId'] as num?)?.toInt() ?? 0,
        quizName: j['quizName'] as String? ?? 'Ujian',
        endTimeEpochSec: (j['endTimeEpochSec'] as num?)?.toInt() ?? 0,
        questions: (j['questions'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(OfflineQuestion.fromJson)
            .toList(),
      );
}

class OfflineQuizService {
  OfflineQuizService._();

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

    // Jika paket lokal untuk attempt inprogress tersebut sudah ada, langsung pakai!
    if (activeAttempt != null) {
      final attId = (activeAttempt['id'] as num?)?.toInt() ?? 0;
      final existing = await loadSavedPackage(userId: userId, quizId: quizId);
      if (existing != null && existing.attemptId == attId && existing.questions.isNotEmpty) {
        onProgress?.call('Melanjutkan sesi ujian...', 1.0);
        return existing;
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

    // 4. Parse tiap soal Pilihan Ganda + unduh gambar inline ke base64
    final parsed = <OfflineQuestion>[];
    final imageCache = <String, String>{};
    for (var i = 0; i < rawQuestions.length; i++) {
      onProgress?.call(
        'Menyiapkan soal ${i + 1} dari ${rawQuestions.length}...',
        0.60 + (0.38 * (i + 1) / rawQuestions.length),
      );
      final q = await _parseMoodleQuestion(rawQuestions[i], i + 1, token, imageCache);
      parsed.add(q);
    }

    final pkg = OfflineQuizPackage(
      quizId: quizId,
      courseId: courseId,
      attemptId: attemptId,
      userId: userId,
      quizName: quizName,
      endTimeEpochSec: endTime,
      questions: parsed,
    );

    await savePackage(pkg);
    onProgress?.call('Soal ujian siap!', 1.0);
    return pkg;
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

  static Future<OfflineQuestion> _parseMoodleQuestion(
    Map<String, dynamic> raw,
    int fallbackNumber,
    String token,
    Map<String, String> imageCache,
  ) async {
    final slot = (raw['slot'] as num?)?.toInt() ?? fallbackNumber;
    final number = int.tryParse('${raw['number'] ?? ''}') ?? fallbackNumber;
    final type = (raw['type'] as String? ?? 'multichoice').toLowerCase();
    final html = raw['html'] as String? ?? '';
    final seqCheckNum = (raw['sequencecheck'] as num?)?.toInt() ?? 1;

    // Ekstrak input hidden sequencecheck: name="q123:1_:sequencecheck" value="1"
    String seqName = '';
    String seqVal = '$seqCheckNum';
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

    // Ekstrak bagian teks soal (<div class="qtext">...</div>)
    String qtextHtml = '';
    final qtextMatch = RegExp(
      r'''<div[^>]*class=["'][^"']*\bqtext\b[^"']*["'][^>]*>([\s\S]*?)</div>\s*(?=<div[^>]*class=["'][^"']*\bablock\b)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (qtextMatch != null) {
      qtextHtml = qtextMatch.group(1) ?? '';
    } else {
      // Fallback: ambil dari <div class="qtext"> sampai </div> terdekat sebelum radio
      final simpleQtext = RegExp(
        r'''<div[^>]*class=["'][^"']*\bqtext\b[^"']*["'][^>]*>([\s\S]*?)</div>''',
        caseSensitive: false,
      ).firstMatch(html);
      qtextHtml = simpleQtext?.group(1) ?? html;
    }

    qtextHtml = await _inlineImages(qtextHtml, token, imageCache);

    // Ekstrak semua opsi radio (<input type="radio" ...>)
    String answerFieldName = '';
    String? preselected;
    final options = <OfflineOption>[];

    // Cari blok <div class="answer">...</div>
    final ansBlockMatch = RegExp(
      r'''<div[^>]*class=["'][^"']*\banswer\b[^"']*["'][^>]*>([\s\S]*)$''',
      caseSensitive: false,
    ).firstMatch(html);
    final ansArea = ansBlockMatch?.group(1) ?? html;

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

      // Ambil isi di dalam <div class="flex-fill..."> atau <label ...> atau bersihkan wrapper
      String optHtml = chunk;
      final flexMatch = RegExp(
        r'''<div[^>]*class=["'][^"']*flex-fill[^"']*["'][^>]*>([\s\S]*?)</div>''',
        caseSensitive: false,
      ).firstMatch(chunk);
      if (flexMatch != null) {
        optHtml = flexMatch.group(1) ?? chunk;
      } else {
        final labelMatch = RegExp(
          r'''<label[^>]*>([\s\S]*?)</label>''',
          caseSensitive: false,
        ).firstMatch(chunk);
        if (labelMatch != null) {
          optHtml = labelMatch.group(1) ?? chunk;
        }
      }

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

      optHtml = await _inlineImages(optHtml.trim(), token, imageCache);

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

  /// Unduh gambar <img src="..."> dari server Moodle dan ubah jadi base64 inline data URI.
  static Future<String> _inlineImages(
    String html,
    String token,
    Map<String, String> cache,
  ) async {
    final imgRegex = RegExp(r'''<img\b[^>]*\bsrc=["']([^"']+)["'][^>]*>''', caseSensitive: false);
    final matches = imgRegex.allMatches(html).toList();
    if (matches.isEmpty) return html;

    var result = html;
    for (final m in matches) {
      final rawUrl = (m.group(1) ?? '').replaceAll('&amp;', '&');
      if (rawUrl.isEmpty || rawUrl.startsWith('data:')) continue;

      if (cache.containsKey(rawUrl)) {
        result = result.replaceAll(m.group(1)!, cache[rawUrl]!);
        continue;
      }

      try {
        var fetchUrl = rawUrl;
        if (fetchUrl.startsWith('/')) {
          fetchUrl = '${AppConfig.moodleUrl}$fetchUrl';
        }
        // Pastikan URL pluginfile menggunakan endpoint webservice + token agar tidak butuh cookie
        if (fetchUrl.contains('/pluginfile.php/') && !fetchUrl.contains('/webservice/pluginfile.php/')) {
          fetchUrl = fetchUrl.replaceFirst('/pluginfile.php/', '/webservice/pluginfile.php/');
        }
        if (token.isNotEmpty && !fetchUrl.contains('token=')) {
          final sep = fetchUrl.contains('?') ? '&' : '?';
          fetchUrl = '$fetchUrl${sep}token=${Uri.encodeComponent(token)}';
        }

        final resp = await http.get(
          Uri.parse(fetchUrl),
          headers: {'User-Agent': AppConfig.examBrowserUserAgent},
        ).timeout(const Duration(seconds: 12));

        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          final ct = (resp.headers['content-type'] ?? 'image/png').split(';').first.trim();
          final b64 = base64Encode(resp.bodyBytes);
          final dataUri = 'data:$ct;base64,$b64';
          cache[rawUrl] = dataUri;
          result = result.replaceAll(m.group(1)!, dataUri);
        }
      } catch (_) {
        // Jika gagal download satu gambar, biarkan URL asli
      }
    }
    return result;
  }
}
