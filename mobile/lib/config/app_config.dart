import 'package:flutter/foundation.dart';

// ===========================
// DOSMAN UJIAN - App Config
// ===========================

class AppConfig {
  // URL Moodle server
  static const String moodleUrl = 'https://lms.sman1-gianyar.sch.id:9443';

  /// Host/domain yang diizinkan dibuka dari WebView saat ujian.
  /// Minimal harus mencakup host dari [moodleUrl].
  ///
  /// Tambahkan host lain jika Moodle memuat asset/SSO dari domain berbeda
  /// (mis. CDN sekolah, domain auth, atau storage internal).
  static const List<String> allowedHosts = [
    '36.93.15.146',
    '36.93.15.146:9443',
    'lms.sman1-gianyar.sch.id',
    'lms.sman1-gianyar.sch.id:9443',
  ];

  // Nama service Moodle Web Service — gunakan official mobile service agar
  // token dapat dibuat tanpa perlu capability moodle/webservice:createtoken.
  static const String serviceName = 'moodle_mobile_app';

  // MethodChannel untuk komunikasi Flutter <-> Android/iOS native
  static const String lockdownChannel = 'com.dosman.ujian/lockdown';

  // Interval heartbeat (detik)
  static const int heartbeatInterval = 10;

  // User agent WebView ujian — kata kunci dikenali server Moodle.
  static String get examBrowserUserAgent {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) ExamDosmanIOS';
    }
    return 'Mozilla/5.0 (Linux; Android) ExamDosmanAndroid';
  }

  // API key statis untuk endpoint exitpwd.php — harus sama dengan nilai di server.
  static const String exitPwdApiKey = 'dosman-exam-sman1gianyar-2024';

  // Password akses kuis Moodle (field #id_quizpassword).
  // Nilai ini harus diambil dari konfigurasi server — jangan hardcode di sini.
  // Kosong = tidak auto-fill (aman jika quiz tidak memakai password).
  static const String quizAccessPassword = '';

  // Timeout heartbeat server-side (detik) - sama dengan heartbeat.php
  static const int heartbeatTimeout = 15;

  // Batas waktu app di background dengan layar HIDUP (detik) sebelum diblokir.
  static const int backgroundBlockTimeout = 45;

  // Batas waktu layar MATI (detik) — siswa meletakkan HP — sebelum diblokir.
  // 45 menit: cukup untuk mengerjakan soal di kertas tanpa menyentuh HP.
  static const int screenOffAutoBlockSec = 45 * 60;

  // Label event untuk UI
  static const Map<String, String> eventLabels = {
    'exam_start':            'Ujian Dimulai',
    'exam_end':              'Ujian Selesai',
    'app_background':        'Aplikasi Diminimize',
    'screenshot_attempt':    'Percobaan Screenshot',
    'copy_attempt':          'Percobaan Copy Teks',
    'focus_lost':            'Layar Tidak Fokus',
    'screen_record_attempt': 'Percobaan Screen Record',
    'multi_finger_gesture':  'Gestur Multi-Jari',
    'app_force_closed':      'Aplikasi Ditutup Paksa',
    'manually_blocked':      'Diblokir oleh Guru',
    'session_reset':         'Blokir Direset Guru',
    'exit_requested':        'Minta izin keluar aplikasi',
    'exit_approved':         'Izin keluar disetujui',
    'exit_rejected':         'Izin keluar ditolak',
  };

  // Event yang dianggap mencurigakan
  static const List<String> suspiciousEvents = [
    'app_background',
    'screenshot_attempt',
    'copy_attempt',
    'focus_lost',
    'screen_record_attempt',
  ];

  // Warna status sesi
  static const Map<String, int> statusColors = {
    'active':    0xFF16A34A, // hijau
    'paused':    0xFFCA8A04, // kuning
    'blocked':   0xFFDC2626, // merah
    'completed': 0xFF6B7280, // abu-abu
    'offline':   0xFF1F2937, // hitam
  };
}
