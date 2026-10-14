// ===========================
// DOSMAN UJIAN - Exam Service
// API calls khusus untuk sesi ujian siswa
// ===========================

import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'api_service.dart';
import 'auth_service.dart';
import '../models/session.dart';

class ExamService {
  ExamService._();

  /// Pengumuman broadcast aktif dari pengawas/dashboard.
  /// Berisi: { message: String, created_at: int, expires_at: int, sender: String }
  static final ValueNotifier<Map<String, dynamic>?> activeBroadcast = ValueNotifier(null);

  // ─── Heartbeat: ping server setiap 5 detik ─────────────────────────────
  static bool _heartbeatActive = false;
  static Future<void> startHeartbeat() async {
    if (_heartbeatActive) return;
    _heartbeatActive = true;
    while (_heartbeatActive) {
      try {
        final username = await AuthService.getUsername();
        await ApiService.heartbeatPing(username);
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  static void stopHeartbeat() {
    _heartbeatActive = false;
  }

  /// Ambil konfigurasi client untuk dashboard/admin.
  ///
  /// Server (plugin Moodle) menyediakan webservice function:
  /// `local_dosman_ujian_get_client_config`
  /// Response yang diharapkan:
  /// {
  ///   "success": true,
  ///   "admin_exit_password": "xxxxxx",
  ///   "updated_at": 1710000000
  /// }
  static Future<Map<String, dynamic>> getClientConfig() async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_get_client_config',
        const {},
      );
      if (data is Map<String, dynamic>) return data;
      return {'success': false};
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('getClientConfig error: $e', name: 'ExamService');
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Verifikasi password keluar dengan mencocokkan ke server-side config.
  static Future<({bool success, String message})> verifyExitPassword({
    required int sessionId,
    required int userId,
    required String password,
  }) async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_verify_exit_password',
        {
          'session_id': sessionId,
          'userid': userId,
          'password': password,
        },
      );
      if (data is Map<String, dynamic>) {
        return (
          success: data['success'] as bool? ?? false,
          message: data['message'] as String? ?? '',
        );
      }
      return (success: false, message: 'Response tidak valid');
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('verifyExitPassword error: $e', name: 'ExamService');
      return (success: false, message: e.toString());
    }
  }

  // ─── Register Session ────────────────────────────────────────────────────────

  /// Daftarkan sesi ujian saat siswa mulai lockdown.
  /// Jika sesi sudah ada, kembalikan sesi yang ada.
  /// Returns [RegisterSessionResult] berisi status & sessionId.
  static Future<RegisterSessionResult> registerSession({
    required int userId,
    required int quizId,
    required int courseId,
  }) async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_register_session',
        {
          'userid':   userId,
          'quizid':   quizId,
          'courseid': courseId,
        },
      );

      if (data is Map<String, dynamic>) {
        return RegisterSessionResult.fromJson(data);
      }

      return RegisterSessionResult(
        success:   false,
        status:    'error',
        message:   'Response tidak valid',
        sessionId: 0,
      );
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('registerSession error: $e', name: 'ExamService');
      return RegisterSessionResult(
        success:   false,
        status:    'error',
        message:   e.toString(),
        sessionId: 0,
      );
    }
  }

  // ─── Minta izin keluar ─────────────────────────────────────────────────────

  /// Siswa meminta izin keluar; guru menyetujui dari dashboard.
  static Future<({bool success, String message})> requestExit({
    required int sessionId,
    required int userId,
  }) async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_request_exit',
        {
          'session_id': sessionId,
          'userid':     userId,
        },
      );

      if (data is Map<String, dynamic>) {
        return (
          success: data['success'] as bool? ?? false,
          message: data['message'] as String? ?? '',
        );
      }
      return (success: false, message: 'Response tidak valid');
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('requestExit error: $e', name: 'ExamService');
      return (success: false, message: e.toString());
    }
  }

  // ─── Heartbeat ───────────────────────────────────────────────────────────────

  /// Kirim heartbeat ke server setiap 10 detik.
  /// Server akan otomatis blokir siswa yang tidak heartbeat > 30 detik.
  /// Returns [HeartbeatResult] berisi status sesi terkini.
  static Future<HeartbeatResult> sendHeartbeat({
    required int sessionId,
    required int userId,
  }) async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_heartbeat',
        {
          'session_id': sessionId,
          'userid':     userId,
        },
      );

      if (data is Map<String, dynamic>) {
        return HeartbeatResult.fromJson(data);
      }

      return HeartbeatResult.error('Response tidak valid');
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('sendHeartbeat error: $e', name: 'ExamService');
      return HeartbeatResult.error(e.toString());
    }
  }

  // ─── Log Activity ────────────────────────────────────────────────────────────

  /// Kirim log aktivitas siswa ke server.
  /// [eventType] adalah salah satu dari: exam_start, exam_end,
  /// app_background, screenshot_attempt, copy_attempt,
  /// focus_lost, screen_record_attempt, multi_finger_gesture,
  /// app_force_closed.
  /// [eventData] adalah JSON string opsional berisi detail event.
  static Future<bool> logActivity({
    required int    userId,
    required int    quizId,
    required int    courseId,
    required String eventType,
    String          eventData = '{}',
  }) async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_log_activity',
        {
          'userid':     userId,
          'quizid':     quizId,
          'courseid':   courseId,
          'eventtype':  eventType,
          'eventdata':  eventData,
        },
      );

      if (data is Map<String, dynamic>) {
        return data['success'] as bool? ?? false;
      }
      return false;
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('logActivity($eventType) error: $e', name: 'ExamService');
      return false;
    }
  }

  // ─── Get Exam Status ─────────────────────────────────────────────────────────

  /// Cek apakah siswa sedang dalam attempt quiz yang aktif (inprogress).
  /// Returns map: {is_active, attempt_id, time_remaining, time_started}
  static Future<Map<String, dynamic>> getExamStatus({
    required int userId,
    required int quizId,
  }) async {
    try {
      final data = await ApiService.call(
        'local_dosman_ujian_get_exam_status',
        {
          'userid': userId,
          'quizid': quizId,
        },
      );

      if (data is Map<String, dynamic>) return data;
      return {'is_active': false, 'attempt_id': 0, 'time_remaining': 0, 'time_started': 0};
    } on TokenExpiredException {
      rethrow;
    } catch (e) {
      dev.log('getExamStatus error: $e', name: 'ExamService');
      return {'is_active': false, 'attempt_id': 0, 'time_remaining': 0, 'time_started': 0};
    }
  }

  // ─── Kode status siswa: 0=belum login, 1=login, 2=diblokir ─────────────────
  //
  // Kode dikelola di server (block_student.php / check_blocked.php).
  // Alur:
  //   Login → server set kode = 1
  //   Keluar app > 15 detik saat kode=1 → client panggil blockStudent() → kode = 2
  //   Kode = 2 → app tampilkan BlockedScreen, tolak akses ke Moodle
  //   Teacher unblok → kode kembali ke 0/1





  /// Ubah status siswa menjadi diblokir di server.
  /// Endpoint ini dipakai untuk kasus pelanggaran di sisi client.
  static Future<bool> blockStudent({
    required int userId,
    String reason = 'manual_block',
  }) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/block_student.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'apikey': AppConfig.exitPwdApiKey,
              'userid': userId,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 6));

      if (resp.statusCode < 200 || resp.statusCode >= 300) return false;
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['success'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Suspend akun siswa di server (paksa logout dari app/web).
  /// Menggunakan apikey internal dan token siswa jika ada.
  static Future<bool> suspendStudent({
    required int userId,
    String reason = 'Siswa memaksa melepas pinned screen (alarm aktif)',
  }) async {
    try {
      final token = await AuthService.getToken();
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/suspend_student.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'token': token ?? '',
              'apikey': AppConfig.exitPwdApiKey,
              'userid': userId,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 6));

      if (resp.statusCode < 200 || resp.statusCode >= 300) return false;
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['success'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Tier-1 anti-cheat: blokir perangkat tanpa suspend akun.
  /// Server akan auto-escalate ke suspend penuh setelah 10 menit.
  static Future<bool> blockDevice({
    required String deviceId,
    String reason = 'Keluar aplikasi saat ujian aktif',
  }) async {
    try {
      final token = await AuthService.getToken();
      if (token == null || token.isEmpty) return false;
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/block_device.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'token': token,
              'device_id': deviceId,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return false;
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['success'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Cek apakah siswa sedang diblokir oleh server.
  /// [reachable] = false jika endpoint tidak bisa dihubungi.
  static Future<({bool blocked, String reason, bool reachable})> checkBlocked({
    required int userId,
  }) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/check_blocked.php?userid=$userId',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (blocked: false, reason: '', reachable: false);
      }
      final decoded = json.decode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        return (blocked: false, reason: '', reachable: true);
      }
      return (
        blocked: decoded['blocked'] == true,
        reason: decoded['reason'] as String? ?? '',
        reachable: true,
      );
    } catch (_) {
      return (blocked: false, reason: '', reachable: false);
    }
  }

  /// Daftarkan/perbarui kehadiran siswa di appstatus server.
  /// Dipanggil segera setelah login dan setiap 60 detik selama app terbuka.
  /// Returns false jika server mengindikasikan akun disuspend; true untuk semua kasus lain (termasuk error jaringan).
  static Future<bool> pingAppLogin() async {
    try {
      final token = await AuthService.getToken();
      if (token == null || token.isEmpty) return false;
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/app_ping.php',
      );
      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'token': token}),
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode == 401) {
        try {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          if (data['suspended'] == true) return false;
        } catch (_) {}
        return false;
      }
      if (resp.statusCode == 200) {
        try {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          if (data['suspended'] == true) return false;
          if (data['broadcast'] is Map<String, dynamic>) {
            activeBroadcast.value = Map<String, dynamic>.from(data['broadcast'] as Map);
          } else {
            activeBroadcast.value = null;
          }
        } catch (_) {}
      }
      return true;
    } catch (_) {
      // Error jaringan — jangan kick siswa, anggap masih valid
      return true;
    }
  }

  /// Kirim browser heartbeat ke server (bukti app masih aktif di LockedBrowserScreen).
  /// [active] = true saat aktif, false saat keluar dengan benar.
  /// Fire-and-forget — tidak perlu await, error diabaikan.
  static Future<void> sendBrowserHeartbeat({
    required int userId,
    bool active = true,
  }) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/browser_heartbeat.php',
      );
      await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'apikey': AppConfig.exitPwdApiKey,
          'userid': userId,
          'active': active ? 1 : 0,
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {} // tidak kritis, diabaikan
  }



  /// Cek apakah device_id diblokir di server.
  static Future<({bool blocked, String reason, int blockedAt})> checkDevice(
      String deviceId) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/check_device.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'device_id': deviceId}),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (blocked: false, reason: '', blockedAt: 0);
      }
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return (
          blocked: decoded['blocked'] == true,
          reason: decoded['reason'] as String? ?? '',
          blockedAt: (decoded['blocked_at'] as num?)?.toInt() ?? 0,
        );
      }
      return (blocked: false, reason: '', blockedAt: 0);
    } catch (_) {
      return (blocked: false, reason: '', blockedAt: 0);
    }
  }

  /// Verifikasi kode 6 digit dari guru untuk membuka blokir perangkat.
  static Future<({bool success, String message})> verifyUnblockToken({
    required String deviceId,
    required String code,
  }) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/verify_unblock_token.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'device_id': deviceId,
              'code': code,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (success: false, message: 'Server tidak dapat dihubungi.');
      }
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return (
          success: decoded['success'] == true,
          message: decoded['message'] as String? ?? '',
        );
      }
      return (success: false, message: 'Respons tidak valid.');
    } catch (_) {
      return (success: false, message: 'Gagal menghubungi server. Periksa koneksi.');
    }
  }

  /// Daftarkan device ke server setelah login berhasil.
  static Future<({bool success, bool deviceBlocked, String reason, int blockedAt})>
      registerDevice({
    required String deviceId,
    required String token,
    required String platform,
    String model = '',
  }) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/register_device.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'token': token,
              'device_id': deviceId,
              'platform': platform,
              'model': model,
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (success: false, deviceBlocked: false, reason: '', blockedAt: 0);
      }
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return (
          success: decoded['success'] == true,
          deviceBlocked: decoded['device_blocked'] == true,
          reason: decoded['block_reason'] as String? ?? '',
          blockedAt: (decoded['blocked_at'] as num?)?.toInt() ?? 0,
        );
      }
      return (success: false, deviceBlocked: false, reason: '', blockedAt: 0);
    } catch (_) {
      return (success: false, deviceBlocked: false, reason: '', blockedAt: 0);
    }
  }

  // ─── Helper: Build event data JSON ──────────────────────────────────────────

  /// Buat JSON string untuk eventdata dari map sederhana.
  static String buildEventData(Map<String, dynamic> data) {
    return jsonEncode(data);
  }
}
