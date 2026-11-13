// ===========================
// DOSMAN UJIAN - API Service
// Handles semua HTTP request ke Moodle REST API
// ===========================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

// ─── Custom Exceptions ───────────────────────────────────────────────────────

class TokenExpiredException implements Exception {
  final String message;
  TokenExpiredException([this.message = 'Token tidak valid atau sudah kedaluwarsa']);
  @override
  String toString() => message;
}

class ApiException implements Exception {
  final String message;
  final String? errorCode;
  ApiException(this.message, {this.errorCode});
  @override
  String toString() => message;
}

class NetworkException implements Exception {
  final String message;
  NetworkException([this.message = 'Tidak dapat terhubung ke server. Periksa koneksi internet.']);
  @override
  String toString() => message;
}

// ─── API Service ─────────────────────────────────────────────────────────────

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  /// Kirim heartbeat ke backend (proxy.php)
  static Future<void> heartbeatPing(String username) async {
    final url = Uri.parse(
      '${AppConfig.moodleUrl}/dashboard/proxy.php?_endpoint=heartbeat'
      '&username=${Uri.encodeComponent(username)}'
      '&token=${Uri.encodeComponent(_token ?? '')}',
    );
    try {
      await http.get(url).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Kirim aktivitas logout ke backend (proxy.php)
  static Future<void> logoutActivity(String username) async {
    final url = Uri.parse(
      '${AppConfig.moodleUrl}/dashboard/proxy.php?_endpoint=logout_activity'
      '&username=${Uri.encodeComponent(username)}'
      '&token=${Uri.encodeComponent(_token ?? '')}',
    );
    try {
      await http.get(url).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // Singleton token — diset setelah login
  static String? _token;
  static String get moodleUrl => AppConfig.moodleUrl;

  static void setToken(String token) => _token = token;
  static void clearToken() => _token = null;
  static String? get currentToken => _token;

  // ─── Login → ambil token ───────────────────────────────────────────────────

  /// Login ke Moodle dan kembalikan token.
  /// Menggunakan [serviceName] (moodle_mobile_app) — official Moodle mobile service,
  /// token dapat dibuat oleh semua Authenticated user tanpa perlu capability tambahan.
  static Future<String> loginGetToken(
    String username,
    String password, {
    String serviceName = AppConfig.serviceName,
  }) async {
    try {
      final uri = Uri.parse('$moodleUrl/login/token.php').replace(
        queryParameters: {
          'username': username,
          'password': password,
          'service':  serviceName,
        },
      );

      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw ApiException('Server error: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;

      if (data['token'] != null) {
        final token = data['token'] as String;
        setToken(token);
        return token;
      }

      // error Moodle → terjemahkan ke pesan yang mudah dipahami siswa
      final raw = data['error'] as String? ?? '';
      final code = data['errorcode'] as String? ?? '';
      if (code == 'invalidlogin') {
        throw ApiException('Username atau password salah. Periksa kembali dan coba lagi.');
      }
      if (code == 'servicenotavailableatsite' || code == 'servicenotavailable') {
        throw ApiException('Layanan ujian tidak tersedia di server ini. Hubungi pengawas.');
      }
      throw ApiException(raw.isNotEmpty ? raw : 'Login gagal. Periksa username dan password.');
    } on TimeoutException {
      throw NetworkException('Koneksi ke server ujian timeout (lambat). Pastikan Wi-Fi sekolah terhubung stabil.');
    } on SocketException {
      throw NetworkException();
    } on ApiException {
      rethrow;
    } on FormatException {
      throw ApiException('Response tidak valid dari server.');
    } catch (e) {
      if (e is ApiException || e is NetworkException) rethrow;
      throw ApiException('Terjadi kesalahan: $e');
    }
  }

  // ─── Generic REST API call ─────────────────────────────────────────────────

  /// Panggil Moodle Web Service function dengan [wsfunction] dan [params].
  /// Otomatis menyertakan wstoken dan moodlewsrestformat=json.
  static Future<dynamic> call(
    String wsfunction,
    Map<String, dynamic> params, {
    String? token,
  }) async {
    final activeToken = token ?? _token;
    if (activeToken == null || activeToken.isEmpty) {
      throw TokenExpiredException('Belum login. Token tidak tersedia.');
    }

    // Konversi semua params ke String (REST API butuh query string)
    final queryParams = <String, String>{
      'wstoken':            activeToken,
      'wsfunction':         wsfunction,
      'moodlewsrestformat': 'json',
    };

    _flattenParams(params, queryParams);

    final uri = Uri.parse('$moodleUrl/webservice/rest/server.php')
        .replace(queryParameters: queryParams);

    try {
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw ApiException('HTTP Error: ${response.statusCode}');
      }

      // Moodle kadang mengembalikan HTML notice di depan JSON — bersihkan dulu
      final cleaned = _extractJson(response.body);
      final data = json.decode(cleaned);

      // Cek Moodle exception
      if (data is Map<String, dynamic> && data.containsKey('exception')) {
        final errorCode = data['errorcode'] as String?;
        final message   = data['message']   as String? ?? data['exception'] as String? ?? 'API Error';

        if (errorCode == 'invalidtoken' || errorCode == 'accessdenied') {
          throw TokenExpiredException(message);
        }
        throw ApiException(message, errorCode: errorCode);
      }

      return data;
    } on TimeoutException {
      throw NetworkException('Koneksi ke server ujian timeout (lambat). Pastikan Wi-Fi sekolah terhubung stabil.');
    } on SocketException {
      throw NetworkException();
    } on TokenExpiredException {
      rethrow;
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Gagal memproses response: $e');
    }
  }

  // ─── Core Moodle functions ─────────────────────────────────────────────────

  /// Verifikasi token dan ambil info user yang sedang login.
  /// Returns: {userid, fullname, siteurl, ...}
  static Future<Map<String, dynamic>> getSiteInfo({String? token}) async {
    final data = await call('core_webservice_get_site_info', {}, token: token);
    return data as Map<String, dynamic>;
  }

  /// Ambil daftar course yang diikuti oleh [userId].
  static Future<List<dynamic>> getCourses(int userId) async {
    var resolvedUserId = userId;

    // Beberapa sesi lama bisa tidak menyimpan userid dengan benar.
    // Fallback ke site_info agar call course tidak gagal diam-diam.
    if (resolvedUserId <= 0) {
      final siteInfo = await getSiteInfo();
      resolvedUserId = (siteInfo['userid'] as num?)?.toInt() ?? 0;
    }

    if (resolvedUserId > 0) {
      final data = await call('core_enrol_get_users_courses', {
        'userid': resolvedUserId,
      });

      if (data is List && data.isNotEmpty) {
        return data.where((c) {
          final id = _toInt(c['id']);
          return id > 1;
        }).toList();
      }
    }

    // Fallback untuk role siswa yang kadang hanya diizinkan endpoint timeline.
    try {
      final enrolled = await call(
        'core_course_get_enrolled_courses_by_timeline_classification',
        {
          'classification': 'all',
          'sort': 'fullname',
          'limit': 0,
          'offset': 0,
        },
      );

      if (enrolled is Map<String, dynamic>) {
        final courses = enrolled['courses'];
        if (courses is List && courses.isNotEmpty) {
          return courses.where((c) {
            final id = _toInt(c['id']);
            return id > 1;
          }).toList();
        }
      }
    } catch (_) {
      // lanjut ke fallback berikutnya
    }

    // Fallback: ambil semua course (perlu akses admin)
    final fallback = await call('core_course_get_courses', {});
    if (fallback is List) {
      return fallback.where((c) {
        final id = _toInt(c['id']);
        return id > 1;
      }).toList();
    }

    return [];
  }

  /// Ambil daftar quiz dalam satu [courseId].
  static Future<List<dynamic>> getQuizzes(int courseId) async {
    final data = await call('mod_quiz_get_quizzes_by_courses', {
      'courseids[0]': courseId,
    });

    if (data is Map<String, dynamic>) {
      final quizzes = data['quizzes'] as List<dynamic>? ?? [];
      if (quizzes.isNotEmpty) return quizzes;
    }

    // Fallback: parse quiz dari isi course jika endpoint quiz kosong.
    try {
      final contents = await call('core_course_get_contents', {
        'courseid': courseId,
      });
      if (contents is List) {
        final parsed = <Map<String, dynamic>>[];
        for (final section in contents) {
          if (section is! Map<String, dynamic>) continue;
          final modules = section['modules'];
          if (modules is! List) continue;
          for (final mod in modules) {
            if (mod is! Map<String, dynamic>) continue;
            final modName = mod['modname'] as String? ?? '';
            if (modName != 'quiz') continue;
            final cmid = _toInt(mod['id']);
            final quizId = _toInt(mod['instance']) != 0
                ? _toInt(mod['instance'])
                : cmid;
            parsed.add({
              'id': quizId,
              'coursemodule': cmid,
              'course': courseId,
              'name': mod['name'] as String? ?? 'Quiz',
              'intro': mod['description'] as String? ?? '',
              'visible': mod['visible'] ?? 1,
              'timeopen': 0,
              'timeclose': 0,
              'timelimit': 0,
              'attempts': 0,
              'gradepass': 0,
              'grade': 0,
            });
          }
        }
        return parsed;
      }
    } catch (_) {
      // biarkan return []
    }

    return [];
  }

  // ─── Helper: flatten nested params ────────────────────────────────────────

  /// Moodle REST API menggunakan query string flat.
  /// Konversi nested map/list menjadi 'key[0]', 'key[1]', dst.
  static void _flattenParams(
    Map<String, dynamic> params,
    Map<String, String> output, {
    String prefix = '',
  }) {
    params.forEach((key, value) {
      final flatKey = prefix.isEmpty ? key : '$prefix[$key]';
      if (value is Map<String, dynamic>) {
        _flattenParams(value, output, prefix: flatKey);
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          final listKey = '$flatKey[$i]';
          if (value[i] is Map<String, dynamic>) {
            _flattenParams(value[i] as Map<String, dynamic>, output, prefix: listKey);
          } else {
            output[listKey] = value[i].toString();
          }
        }
      } else {
        output[flatKey] = value.toString();
      }
    });
  }

  // ─── Helper: ekstrak JSON bersih ──────────────────────────────────────────

  /// Moodle kadang mengembalikan PHP notice/warning HTML di depan JSON.
  /// Fungsi ini mencari awal karakter { atau [ dan memotong string di sana.
  static String _extractJson(String raw) {
    raw = raw.trim();
    if (raw.isEmpty) return '{}';
    if (raw[0] == '{' || raw[0] == '[') return raw;

    final posObj = raw.indexOf('{');
    final posArr = raw.indexOf('[');

    int start;
    if (posObj == -1 && posArr == -1) return '{}';
    if (posObj == -1) {
      start = posArr;
    } else if (posArr == -1) {
      start = posObj;
    } else {
      start = posObj < posArr ? posObj : posArr;
    }

    return raw.substring(start);
  }

  static int _toInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }
}
