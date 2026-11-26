// ===========================
// DOSMAN UJIAN - Exam Service
// API calls khusus untuk sesi ujian siswa
// ===========================

import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'kiosk_controller.dart';
import '../models/session.dart';
import '../utils/app_version.dart';

/// Hasil pemanggilan endpoint `suspend_student.php` untuk membedakan
/// penolakan resmi aturan server (`ignored: true`) dari putus jaringan/error server.
enum SuspendAccountOutcome {
  suspended,
  ignoredByServer,
  networkOrServerError,
}

class ExamService {
  ExamService._();

  static const _kPendingSuspendKey = 'dosman_pending_suspend_userid';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  /// Simpan userId yang gagal disuspend karena offline untuk di-flush saat app dibuka kembali.
  static Future<void> savePendingSuspend(int userId) async {
    try {
      await _storage.write(key: _kPendingSuspendKey, value: userId.toString());
    } catch (_) {}
  }

  static Future<void> clearPendingSuspend() async {
    try {
      await _storage.delete(key: _kPendingSuspendKey);
    } catch (_) {}
  }

  /// Kirim ulang suspend yang tertunda akibat jaringan putus saat pelanggaran terjadi.
  static Future<void> flushPendingSuspend() async {
    final val = await _storage.read(key: _kPendingSuspendKey);
    if (val == null) return;
    final uid = int.tryParse(val) ?? 0;
    if (uid <= 0) {
      await clearPendingSuspend();
      return;
    }
    final outcome = await suspendStudentWithOutcome(userId: uid);
    if (outcome == SuspendAccountOutcome.suspended ||
        outcome == SuspendAccountOutcome.ignoredByServer) {
      await clearPendingSuspend();
    }
  }

  /// Pengumuman broadcast aktif dari pengawas/dashboard.
  /// Berisi: { message: String, created_at: int, expires_at: int, sender: String }
  static final ValueNotifier<Map<String, dynamic>?> activeBroadcast = ValueNotifier(null);

  /// Latency ping terakhir ke server Moodle (ms). null = putus / timeout.
  static final ValueNotifier<int?> lastPingLatencyMs = ValueNotifier(null);

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

  /// Parser respons JSON `suspend_student.php`.
  @visibleForTesting
  static SuspendAccountOutcome parseSuspendResponse(int statusCode, String body) {
    if (statusCode < 200 || statusCode >= 300) {
      return SuspendAccountOutcome.networkOrServerError;
    }
    try {
      final decoded = json.decode(body);
      if (decoded is Map<String, dynamic>) {
        if (decoded['success'] == true) {
          return SuspendAccountOutcome.suspended;
        }
        if (decoded['ignored'] == true) {
          return SuspendAccountOutcome.ignoredByServer;
        }
      }
    } catch (_) {}
    return SuspendAccountOutcome.networkOrServerError;
  }

  /// Suspend akun siswa di server dengan status terperinci (`suspended` / `ignoredByServer` / `networkOrServerError`).
  static Future<SuspendAccountOutcome> suspendStudentWithOutcome({
    required int userId,
    String reason = 'Siswa memaksa melepas pinned screen (alarm aktif)',
  }) async {
    try {
      final username = (await AuthService.getUsername()).toLowerCase().trim();
      if (KioskController.isReviewerUsername(username)) {
        return SuspendAccountOutcome.ignoredByServer;
      }

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

      return parseSuspendResponse(resp.statusCode, resp.body);
    } catch (_) {
      return SuspendAccountOutcome.networkOrServerError;
    }
  }

  /// Suspend akun siswa di server (paksa logout dari app/web).
  /// Wrapper kompatibel yang mengembalikan true hanya bila server benar-benar men-suspend.
  static Future<bool> suspendStudent({
    required int userId,
    String reason = 'Siswa memaksa melepas pinned screen (alarm aktif)',
  }) async {
    return (await suspendStudentWithOutcome(userId: userId, reason: reason)) ==
        SuspendAccountOutcome.suspended;
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
  static Future<bool> pingAppLogin({int quizId = 0}) async {
    final sw = Stopwatch()..start();
    try {
      final token = await AuthService.getToken();
      if (token == null || token.isEmpty) {
        lastPingLatencyMs.value = null;
        return false;
      }
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/app_ping.php',
      );
      final bodyMap = <String, dynamic>{
        'token': token,
        'platform': kIsWeb ? 'web' : (Platform.isIOS ? 'ios' : 'android'),
        'app_version': kAppVersion,
        'app_build': kBuildNumber,
      };
      if (quizId > 0) bodyMap['quizid'] = quizId;
      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(bodyMap),
      ).timeout(const Duration(seconds: 5));
      sw.stop();
      lastPingLatencyMs.value = sw.elapsedMilliseconds;
      if (resp.statusCode == 200 || resp.statusCode == 401) {
        ApiService.updateServerClockFromHeader(resp.headers['date']);
      }

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
      lastPingLatencyMs.value = null;
      return true;
    }
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
  static Future<({bool success, bool deviceBlocked, bool updateRequired, String reason, int blockedAt})>
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
              'app_version': kAppVersion,
              'app_build': kBuildNumber,
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (success: false, deviceBlocked: false, updateRequired: false, reason: '', blockedAt: 0);
      }
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        return (
          success: decoded['success'] == true,
          deviceBlocked: decoded['device_blocked'] == true,
          updateRequired: decoded['update_required'] == true,
          reason: decoded['block_reason'] as String? ?? '',
          blockedAt: (decoded['blocked_at'] as num?)?.toInt() ?? 0,
        );
      }
      return (success: false, deviceBlocked: false, updateRequired: false, reason: '', blockedAt: 0);
    } catch (_) {
      return (success: false, deviceBlocked: false, updateRequired: false, reason: '', blockedAt: 0);
    }
  }

  /// Verifikasi jumlah soal terjawab yang benar-benar tersimpan di server Moodle
  /// setelah [mod_quiz_process_attempt] untuk mencegah status kirim palsu saat terlambat.
  static Future<({bool reachable, String state, int totalSlots, int answeredSlots})>
      verifyAttemptSaved({required int attemptId}) async {
    if (attemptId <= 0) {
      return (reachable: false, state: '', totalSlots: 0, answeredSlots: 0);
    }
    try {
      final token = (await AuthService.getToken()) ?? ApiService.currentToken ?? '';
      if (token.isEmpty) {
        return (reachable: false, state: '', totalSlots: 0, answeredSlots: 0);
      }
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/verify_attempt_saved.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'token': token,
              'attempt_id': attemptId,
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (reachable: false, state: '', totalSlots: 0, answeredSlots: 0);
      }
      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic> && decoded['success'] == true) {
        return (
          reachable: true,
          state: (decoded['state'] as String? ?? '').toLowerCase(),
          totalSlots: (decoded['total_slots'] as num?)?.toInt() ?? 0,
          answeredSlots: (decoded['answered_slots'] as num?)?.toInt() ?? 0,
        );
      }
      return (reachable: false, state: '', totalSlots: 0, answeredSlots: 0);
    } catch (_) {
      return (reachable: false, state: '', totalSlots: 0, answeredSlots: 0);
    }
  }

  /// Kirim darurat dengan Kode Proktor untuk menyelamatkan jawaban terkunci di HP
  /// saat attempt di Moodle telanjur ditutup dengan 0 terjawab setelah lewat grace period.
  static Future<({bool success, int totalSlots, int answeredSlots, String message})>
      rescueSubmitAttempt({
    required int attemptId,
    required String proctorCode,
    required List<Map<String, String>> answerData,
    int lockedAtEpochSec = 0,
  }) async {
    final cleanCode = proctorCode.trim();
    if (attemptId <= 0 || cleanCode.isEmpty || answerData.isEmpty) {
      return (
        success: false,
        totalSlots: 0,
        answeredSlots: 0,
        message: 'Data jawaban atau kode proktor belum lengkap.',
      );
    }
    try {
      final token = (await AuthService.getToken()) ?? ApiService.currentToken ?? '';
      if (token.isEmpty) {
        return (
          success: false,
          totalSlots: 0,
          answeredSlots: 0,
          message: 'Sesi login siswa tidak tersedia. Silakan login ulang.',
        );
      }
      final uri = Uri.parse(
        '${AppConfig.moodleUrl}/local/dosman_ujian/rescue_submit_attempt.php',
      );
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'token': token,
              'attempt_id': attemptId,
              'proctor_code': cleanCode,
              'data': answerData,
              'locked_at': lockedAtEpochSec,
            }),
          )
          .timeout(const Duration(seconds: 25));

      final decoded = json.decode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final ok = resp.statusCode >= 200 &&
            resp.statusCode < 300 &&
            decoded['success'] == true;
        return (
          success: ok,
          totalSlots: (decoded['total_slots'] as num?)?.toInt() ?? 0,
          answeredSlots: (decoded['answered_slots'] as num?)?.toInt() ?? 0,
          message: decoded['message'] as String? ??
              (ok
                  ? 'Jawaban darurat berhasil disimpan & dinilai di Moodle.'
                  : 'Gagal memproses kirim darurat (HTTP ${resp.statusCode}).'),
        );
      }
      return (
        success: false,
        totalSlots: 0,
        answeredSlots: 0,
        message: 'Respon server tidak valid (HTTP ${resp.statusCode}).',
      );
    } catch (_) {
      return (
        success: false,
        totalSlots: 0,
        answeredSlots: 0,
        message: 'Gagal menghubungi server Moodle. Periksa koneksi Wi-Fi sekolah.',
      );
    }
  }

  // ─── Helper: Build event data JSON ──────────────────────────────────────────

  /// Buat JSON string untuk eventdata dari map sederhana.
  static String buildEventData(Map<String, dynamic> data) {
    return jsonEncode(data);
  }
}
