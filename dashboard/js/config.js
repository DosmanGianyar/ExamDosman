const CONFIG = {
  MOODLE_URL: "https://lms.sman1-gianyar.sch.id:9443",
  /** Sama dengan AppConfig.exitPwdApiKey (mobile) & DOSMAN_EXIT_API_KEY di exitpwd.php */
  EXIT_PWD_API_KEY: "dosman-exam-sman1gianyar-2024",
  REFRESH_INTERVAL: 10000,
  MAX_ALERTS: 15,
  WARNING_THRESHOLD: 2,
  DANGER_THRESHOLD: 5,

  EVENT_LABELS: {
    exam_start: { label: "Ujian Dimulai", icon: "✅" },
    exam_end: { label: "Ujian Selesai", icon: "🏁" },
    session_register_failed: { label: "Gagal Daftar Sesi", icon: "❌" },
    lock_task_failed: { label: "LockTask Ditolak", icon: "🚫" },
    app_background: { label: "Aplikasi Diminimize", icon: "⚠️" },
    screenshot_attempt: { label: "Percobaan Screenshot", icon: "🚨" },
    copy_attempt: { label: "Percobaan Copy Teks", icon: "🚨" },
    focus_lost: { label: "Layar Tidak Fokus", icon: "⚠️" },
    screen_record_attempt: { label: "Percobaan Screen Record", icon: "🚨" },
    multi_finger_gesture: { label: "Gestur Multi-Jari", icon: "⚠️" },
    app_force_closed: { label: "Aplikasi Ditutup Paksa", icon: "🔴" },
    session_reset: { label: "Blokir Direset Guru", icon: "🔓" },
    exit_requested: { label: "Minta izin keluar aplikasi", icon: "🚪" },
    exit_approved: { label: "Izin keluar disetujui", icon: "✅" },
    exit_rejected: { label: "Izin keluar ditolak", icon: "⛔" },
    app_ping_stale_auto_block: { label: "Diblokir otomatis (tidak ada ping)", icon: "🔴" },
    device_block_escalated_to_suspend: { label: "Akun di-suspend otomatis oleh sistem", icon: "🚫" },
    unpin_attempt: { label: "Percobaan Cabut Pin Aplikasi", icon: "📌" },
  },

  STATUS_INFO: {
    active: { label: "Aktif", icon: "🟢", badge: "badge-success" },
    paused: { label: "Dijeda", icon: "🟡", badge: "badge-warning" },
    completed: { label: "Selesai", icon: "✅", badge: "badge-gray" },
    offline: { label: "Offline", icon: "⚫", badge: "badge-danger" },
    released: { label: "Sudah izin keluar", icon: "🚪", badge: "badge-gray" },
  },
};
