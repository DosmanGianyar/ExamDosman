<?php
/**
 * Hook callback: blokir akses quiz bagi student yang tidak memakai
 * Dosman Exam (Android) atau Safe Exam Browser (iOS).
 * Juga mendeteksi login Android dan menegakkan global lock_status.
 *
 * @package    local_dosman_ujian
 * @copyright  2024 dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\hook\output;

class before_http_headers {

    public static function callback(\core\hook\output\before_http_headers $hook): void {
        global $USER, $DB;

        $ua           = $_SERVER['HTTP_USER_AGENT'] ?? '';
        $script       = $_SERVER['SCRIPT_NAME'] ?? '';
        $isDosmanApp  = (strpos($ua, 'ExamDosmanAndroid') !== false) || (strpos($ua, 'ExamDosmanIOS') !== false);
        $isAndroid    = $isDosmanApp;
        $isSEB        = !$isDosmanApp && (strpos($ua, 'SEB') !== false || strpos($ua, 'SafeExamBrowser') !== false);
        $is_quiz_page = (bool) preg_match(
            '#/mod/quiz/(view|attempt|startattempt|processattempt|summary)\.php#', $script
        );

        // ── SEB: update ping di SEMUA halaman (login, kuis, maupun halaman lain) ──
        if ($isSEB && !empty($USER->id) && !\isguestuser($USER)
                && !\is_siteadmin($USER) && !self::is_teacher_or_above((int)$USER->id)) {
            self::update_seb_ping((int)$USER->id, $script, $is_quiz_page);
            if ($is_quiz_page) {
                self::auto_register_session((int)$USER->id, $script);
            }
            return;
        }

        // ── ANDROID: global lock check + ping (berlaku di SEMUA halaman) ────
        if ($isAndroid && !empty($USER->id) && !\isguestuser($USER)
                && !\is_siteadmin($USER) && !self::is_teacher_or_above((int)$USER->id)) {

            $now    = time();
            $ip     = $_SERVER['REMOTE_ADDR'] ?? '';
            $appRow = $DB->get_record('local_dosman_ujian_appstatus', ['userid' => (int)$USER->id]);
            $lock   = $appRow ? (int)$appRow->lock_status : 0;

            if ($lock === 2) {
                // Akun diblokir global oleh guru.
                // Kebijakan baru: tidak tampilkan halaman blokir.
                // Paksa logout agar alur kembali ke login Moodle.
                if (defined('AJAX_SCRIPT') && AJAX_SCRIPT) {
                    header('Content-Type: application/json; charset=utf-8');
                    echo json_encode([
                        'error' => 'account_suspended',
                        'status' => 'suspended',
                        'message' => 'Akun Anda dinonaktifkan oleh pengawas. Silakan login ulang.'
                    ]);
                    exit;
                }
                \require_logout();
                \redirect(new \moodle_url('/login/index.php'));
            }

            if ($lock === 3) {
                // Akun dijeda sementara oleh guru
                if (defined('AJAX_SCRIPT') && AJAX_SCRIPT) {
                    header('Content-Type: application/json; charset=utf-8');
                    echo json_encode(['error' => 'paused', 'status' => 'paused',
                                      'message' => 'Ujian Anda sedang dijeda oleh pengawas.']);
                    exit;
                }
                self::render_pause_page();
                exit;
            }

            // Tentukan quiz yang sedang aktif dikerjakan.
            // - attempt.php              → set dari attempt ID
            // - view.php / startattempt  → set dari cmid
            // - halaman quiz lain        → biarkan nilai lama
            // - non-quiz AJAX            → biarkan (AJAX moodle bisa tembak dari dalam attempt)
            // - non-quiz full-page       → clear ke 0
            $currentQuizId  = 0;
            $updateQuizId   = false;

            if ($is_quiz_page && preg_match('#/mod/quiz/attempt\.php$#', $script)) {
                $attemptid = (int)($_GET['attempt'] ?? 0);
                if ($attemptid > 0) {
                    $row = $DB->get_record('quiz_attempts',
                        ['id' => $attemptid, 'userid' => (int)$USER->id], 'quiz');
                    if ($row) {
                        $currentQuizId = (int)$row->quiz;
                        $updateQuizId  = true;
                    }
                }
            } else if ($is_quiz_page && preg_match('#/mod/quiz/(view|startattempt)\.php$#', $script)) {
                $cmid = (int)($_GET['id'] ?? ($_GET['cmid'] ?? 0));
                if ($cmid > 0) {
                    $cm = $DB->get_record('course_modules', ['id' => $cmid], 'instance');
                    if ($cm) {
                        $currentQuizId = (int)$cm->instance;
                        $updateQuizId  = true;
                    }
                }
            } else if (!$is_quiz_page && !(defined('AJAX_SCRIPT') && AJAX_SCRIPT)) {
                // Full-page navigation ke halaman non-quiz → reset quizid
                $updateQuizId  = true;
                $currentQuizId = 0;
            }
            // Halaman quiz lain (summary, processattempt) atau request AJAX → biarkan nilai lama

            // Upsert appstatus: set lock_status=1 jika baru, update current_quizid hanya jika perlu
            if ($appRow) {
                $upd = (object)[
                    'id'        => $appRow->id,
                    'lastping'  => $now,
                    'ipaddress' => $ip,
                ];
                if ($updateQuizId) {
                    $upd->current_quizid = $currentQuizId;
                }
                if ($lock === 0) {
                    $upd->lock_status = 1;
                }
                $DB->update_record('local_dosman_ujian_appstatus', $upd);
            } else {
                $DB->insert_record('local_dosman_ujian_appstatus', (object)[
                    'userid'          => (int)$USER->id,
                    'lastping'        => $now,
                    'ipaddress'       => $ip,
                    'lock_status'     => 1,
                    'current_quizid'  => $currentQuizId,
                ]);
            }

            // Di halaman kuis: auto-daftarkan sesi monitoring
            if ($is_quiz_page) {
                self::auto_register_session((int)$USER->id, $script);
            }
            return;
        }

        // ── Hanya berlaku untuk halaman ujian (untuk browser non-Android) ──
        if (!$is_quiz_page) {
            return;
        }

        // Belum login / tamu → biarkan Moodle tangani sendiri
        if (empty($USER->id) || \isguestuser($USER)) {
            return;
        }

        // Site admin bebas pakai browser apa saja
        if (\is_siteadmin($USER)) {
            return;
        }

        // Guru / manajer: bebas
        if (self::is_teacher_or_above((int)$USER->id)) {
            return;
        }

        // Blokir browser biasa hanya jika quiz ini mengaktifkan "Wajib Dosman Exam"
        // (quizaccess_dosmanexam). Tanpa ini, opsi No di form quiz diabaikan karena hook
        // memaksa aplikasi untuk semua halaman kuis.
        $quizid = self::resolve_quiz_id_for_current_quiz_script($script, (int)$USER->id);
        if ($quizid <= 0 || !self::quiz_requires_dosman_browser($quizid)) {
            return;
        }

        // Browser biasa + quiz wajib app: blokir dengan halaman "gunakan aplikasi resmi"
        header('HTTP/1.1 403 Forbidden');
        header('Content-Type: text/html; charset=utf-8');
        echo self::get_ua_block_html();
        exit;
    }

    // ── Halaman jeda sementara (dijeda oleh guru) ─────────────────────────
    private static function render_pause_page(): void {
        header('HTTP/1.1 200 OK');
        header('Content-Type: text/html; charset=utf-8');
        echo <<<HTML
<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="10">
  <title>Ujian Dijeda — Dosman Exam</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#fffbeb;
         min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
    .card{background:#fff;border-radius:16px;padding:40px 32px;max-width:420px;width:100%;
          text-align:center;box-shadow:0 4px 32px rgba(0,0,0,.10)}
    .icon{font-size:64px;margin-bottom:16px;animation:pulse 2s infinite}
    @keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
    h1{font-size:22px;color:#d97706;margin-bottom:10px}
    p{font-size:14px;color:#374151;line-height:1.6;margin-bottom:12px}
    .note{background:#fffbeb;border:1px solid #fde68a;border-radius:10px;
          padding:14px 16px;font-size:13px;color:#92400e;margin-top:8px;text-align:left}
    .school{margin-top:24px;font-size:12px;color:#94a3b8}
    .countdown{font-size:12px;color:#9ca3af;margin-top:16px}
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#x23F8;&#xFE0F;</div>
    <h1>Ujian Sedang Dijeda</h1>
    <p>Pengawas ujian telah menjeda sesi Anda sementara. Harap tunggu hingga ujian dilanjutkan kembali.</p>
    <div class="note">
      &#x1F514; <strong>Tetap berada di halaman ini</strong> dan jangan menutup aplikasi. Ujian akan dilanjutkan otomatis oleh pengawas.
    </div>
    <p class="countdown">Halaman ini diperbarui otomatis setiap 10 detik.</p>
    <p class="school">SMAN 1 Gianyar &mdash; Sistem Pengawasan Ujian Online</p>
  </div>
</body>
</html>
HTML;
    }

    // ── Halaman blokir UA (bukan Dosman Exam / SEB) ───────────────────────
    private static function get_ua_block_html(): string {
        return <<<HTML
<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Akses Ditolak — Dosman Exam</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #f1f5f9;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }
    .card {
      background: #fff;
      border-radius: 16px;
      padding: 40px 32px;
      max-width: 420px;
      width: 100%;
      text-align: center;
      box-shadow: 0 4px 32px rgba(0,0,0,.10);
    }
    .icon { font-size: 52px; margin-bottom: 16px; }
    h1 { font-size: 22px; color: #dc2626; margin-bottom: 10px; }
    p  { font-size: 14px; color: #374151; line-height: 1.6; margin-bottom: 20px; }
    .apps {
      background: #f8fafc;
      border: 1px solid #e2e8f0;
      border-radius: 10px;
      padding: 14px 18px;
      text-align: left;
      font-size: 14px;
      color: #1e293b;
      line-height: 2;
    }
    .school { margin-top: 24px; font-size: 12px; color: #94a3b8; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#x1F512;</div>
    <h1>Akses Ditolak</h1>
    <p>Ujian ini hanya dapat diakses melalui aplikasi resmi. Browser standar tidak diizinkan.</p>
    <div class="apps">
      &#x1F4F1; <strong>Android</strong> — Aplikasi <em>Dosman Exam</em><br>
      &#xF8FF; <strong>iOS / iPadOS</strong> — <em>Safe Exam Browser (SEB)</em>
    </div>
    <p class="school">SMAN 1 Gianyar &mdash; Sistem Pengawasan Ujian Online</p>
  </div>
</body>
</html>
HTML;
    }

    private static function auto_register_session(int $userid, string $script): void {
        global $DB;
        $now      = time();
        $ua       = substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 512);
        $quizid   = 0;
        $courseid = 0;

        if (strpos($script, 'attempt.php') !== false) {
            $attemptid = (int)($_GET['attempt'] ?? 0);
            if ($attemptid > 0) {
                $row = $DB->get_record('quiz_attempts', ['id' => $attemptid, 'userid' => $userid], 'quiz');
                if ($row) {
                    $quizid = (int)$row->quiz;
                    $q = $DB->get_record('quiz', ['id' => $quizid], 'course');
                    if ($q) $courseid = (int)$q->course;
                }
            }
        } elseif (strpos($script, 'view.php') !== false || strpos($script, 'startattempt.php') !== false) {
            $cmid = (int)($_GET['id'] ?? ($_GET['cmid'] ?? 0));
            if ($cmid > 0) {
                $cm = $DB->get_record('course_modules', ['id' => $cmid], 'instance,course');
                if ($cm) { $quizid = (int)$cm->instance; $courseid = (int)$cm->course; }
            }
        }

        if ($quizid <= 0 || $courseid <= 0) return;

        $existing = $DB->get_record('local_dosman_ujian_sessions', ['userid' => $userid, 'quizid' => $quizid]);
        if ($existing) {
            if ($existing->status === 'blocked') return;
            $DB->update_record('local_dosman_ujian_sessions', (object)[
                'id'             => $existing->id,
                'last_heartbeat' => $now,
                'useragent'      => $ua,
                'timemodified'   => $now,
            ]);
        } else {
            $DB->insert_record('local_dosman_ujian_sessions', (object)[
                'userid' => $userid, 'quizid' => $quizid, 'courseid' => $courseid,
                'status' => 'active', 'last_heartbeat' => $now, 'useragent' => $ua,
                'blocked_reason' => null, 'blocked_at' => null, 'pause_granted_at' => null,
                'reset_count' => 0, 'exit_request' => 'none',
                'exit_requested_at' => null, 'exit_processed_at' => null,
                'timecreated' => $now, 'timemodified' => $now,
            ]);
        }
    }

    private static function update_seb_ping(int $userid, string $script, bool $is_quiz_page): void {
        global $DB;
        $now = time();
        $ip  = $_SERVER['REMOTE_ADDR'] ?? '';

        // Tentukan quiz yang sedang aktif, sama seperti logika Android
        $currentQuizId = 0;
        $updateQuizId  = false;

        if ($is_quiz_page && preg_match('#/mod/quiz/attempt\.php$#', $script)) {
            $attemptid = (int)($_GET['attempt'] ?? 0);
            if ($attemptid > 0) {
                $row = $DB->get_record('quiz_attempts', ['id' => $attemptid, 'userid' => $userid], 'quiz');
                if ($row) {
                    $currentQuizId = (int)$row->quiz;
                    $updateQuizId  = true;
                }
            }
        } elseif ($is_quiz_page && preg_match('#/mod/quiz/(view|startattempt)\.php$#', $script)) {
            $cmid = (int)($_GET['id'] ?? ($_GET['cmid'] ?? 0));
            if ($cmid > 0) {
                $cm = $DB->get_record('course_modules', ['id' => $cmid], 'instance');
                if ($cm) {
                    $currentQuizId = (int)$cm->instance;
                    $updateQuizId  = true;
                }
            }
        } elseif (!$is_quiz_page && !(defined('AJAX_SCRIPT') && AJAX_SCRIPT)) {
            // Halaman non-kuis full-page → reset quizid
            $updateQuizId  = true;
            $currentQuizId = 0;
        }

        $existing = $DB->get_record('local_dosman_ujian_appstatus', ['userid' => $userid]);
        if ($existing) {
            $upd = (object)['id' => $existing->id, 'lastping' => $now, 'ipaddress' => $ip];
            if ($updateQuizId) {
                $upd->current_quizid = $currentQuizId;
            }
            $DB->update_record('local_dosman_ujian_appstatus', $upd);
        } else {
            $DB->insert_record('local_dosman_ujian_appstatus', (object)[
                'userid'         => $userid,
                'lastping'       => $now,
                'ipaddress'      => $ip,
                'lock_status'    => 0,
                'current_quizid' => $currentQuizId,
            ]);
        }
    }

    private static function update_app_ping(int $userid): void {
        global $DB;
        $now = time();
        $ip  = $_SERVER['REMOTE_ADDR'] ?? '';
        $existing = $DB->get_record('local_dosman_ujian_appstatus', ['userid' => $userid]);
        if ($existing) {
            $DB->update_record('local_dosman_ujian_appstatus', (object)[
                'id'        => $existing->id,
                'lastping'  => $now,
                'ipaddress' => $ip,
            ]);
        } else {
            $DB->insert_record('local_dosman_ujian_appstatus', (object)[
                'userid'      => $userid,
                'lastping'    => $now,
                'ipaddress'   => $ip,
                'lock_status' => 0,
            ]);
        }
    }

    /**
     * True jika baris quizaccess_dosmanexam menyetel requirebrowser=1 untuk quiz ini.
     */
    private static function quiz_requires_dosman_browser(int $quizid): bool {
        global $DB;
        $row = $DB->get_record('quizaccess_dosmanexam', ['quizid' => $quizid], 'requirebrowser');
        return $row && (int)$row->requirebrowser === 1;
    }

    /**
     * Quiz id dari konteks halaman mod/quiz (view/startattempt/attempt/processattempt/summary).
     */
    private static function resolve_quiz_id_for_current_quiz_script(string $script, int $userid): int {
        global $DB;

        $attemptid = 0;
        if (preg_match('#/mod/quiz/processattempt\.php$#', $script)) {
            $attemptid = (int)($_POST['attempt'] ?? $_GET['attempt'] ?? 0);
        } else if (preg_match('#/mod/quiz/(attempt|summary)\.php$#', $script)) {
            $attemptid = (int)($_GET['attempt'] ?? 0);
        }

        if ($attemptid > 0) {
            $row = $DB->get_record('quiz_attempts', ['id' => $attemptid, 'userid' => $userid], 'quiz');
            if ($row) {
                return (int)$row->quiz;
            }
        }

        if (preg_match('#/mod/quiz/(view|startattempt)\.php$#', $script)) {
            $cmid = (int)($_GET['id'] ?? ($_GET['cmid'] ?? 0));
            if ($cmid > 0) {
                $cm = $DB->get_record('course_modules', ['id' => $cmid], 'instance');
                if ($cm) {
                    return (int)$cm->instance;
                }
            }
        }

        return 0;
    }

    private static function is_teacher_or_above(int $userid): bool {
        global $DB;
        $sql = "SELECT COUNT(ra.id)
                  FROM {role_assignments} ra
                  JOIN {role} r ON r.id = ra.roleid
                 WHERE ra.userid = :userid
                   AND r.archetype IN ('manager','coursecreator','editingteacher','teacher')";
        return $DB->count_records_sql($sql, ['userid' => $userid]) > 0;
    }
}
