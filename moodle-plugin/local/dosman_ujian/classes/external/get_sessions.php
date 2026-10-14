<?php
/**
 * External function: get_sessions
 * Ambil semua sesi aktif untuk dashboard guru
 *
 * @package    local_dosman_ujian
 * @copyright  2024 Dosman Ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\external;

defined('MOODLE_INTERNAL') || die();
require_once($CFG->libdir . '/externallib.php');
require_once($CFG->dirroot . '/local/dosman_ujian/lib.php');

use external_api;
use external_value;
use external_single_structure;
use external_multiple_structure;
use external_function_parameters;
use context_course;

class get_sessions extends external_api {

    public static function execute_parameters(): external_function_parameters {
        return new external_function_parameters([
            'quizid'   => new external_value(PARAM_INT, 'Quiz ID'),
            'courseid' => new external_value(PARAM_INT, 'Course ID'),
        ]);
    }

    public static function execute(int $quizid, int $courseid): array {
        global $DB;

        $params = self::validate_parameters(self::execute_parameters(), [
            'quizid'   => $quizid,
            'courseid' => $courseid,
        ]);

        $context = context_course::instance($params['courseid']);
        self::validate_context($context);
        if (!local_dosman_ujian_user_can_monitor_course($context)) {
            require_capability('mod/quiz:viewreports', $context);
        }

        $now = time();
        $timeoutThreshold = $now - 15;

        // Auto-suspend: siswa yang tidak heartbeat > 15 detik dianggap keluar aplikasi.
        // Setelah kena aturan ini, akun Moodle disuspend dan sesi web/app diputus.
        $staleSessions = $DB->get_records_select(
            'local_dosman_ujian_sessions',
            'quizid = :quizid AND courseid = :courseid AND status = :status AND last_heartbeat < :threshold',
            [
                'quizid' => $params['quizid'],
                'courseid' => $params['courseid'],
                'status' => 'active',
                'threshold' => $timeoutThreshold,
            ]
        );

        foreach ($staleSessions as $stale) {
            $DB->update_record('local_dosman_ujian_sessions', (object)[
                'id' => $stale->id,
                'status' => 'blocked',
                'blocked_reason' => 'Keluar dari aplikasi (otomatis)',
                'blocked_at' => $now,
                'timemodified' => $now,
            ]);
            $DB->execute(
                'UPDATE {local_dosman_ujian_appstatus} SET lock_status = 2 WHERE userid = ?',
                [$stale->userid]
            );
            $DB->set_field('user', 'suspended', 1, ['id' => $stale->userid]);
            $DB->set_field('user', 'timemodified', $now, ['id' => $stale->userid]);
            \core\session\manager::kill_user_sessions($stale->userid);

            $DB->insert_record('local_dosman_ujian_logs', (object)[
                'userid' => $stale->userid,
                'courseid' => $stale->courseid,
                'quizid' => $stale->quizid,
                'eventtype' => 'app_force_closed',
                'eventdata' => json_encode(['reason' => 'heartbeat_timeout_15s_auto_suspend']),
                'suspicious' => 1,
                'timecreated' => $now,
            ]);
        }

        // Ambil semua sesi untuk quiz ini beserta info user
        $sql = 'SELECT s.id, s.userid, s.quizid, s.courseid, s.status,
                       s.last_heartbeat, s.blocked_reason, s.blocked_at,
                       s.pause_granted_at, s.reset_count, s.timecreated, s.timemodified,
                       s.exit_request, s.exit_requested_at, s.exit_processed_at,
                       s.useragent,
                       u.firstname, u.lastname, u.email,
                       u.department, u.institution,
                       (SELECT COUNT(*) FROM {local_dosman_ujian_logs} l
                        WHERE l.userid = s.userid AND l.quizid = s.quizid
                        AND l.suspicious = 1) as suspicious_count
                  FROM {local_dosman_ujian_sessions} s
                  JOIN {user} u ON u.id = s.userid
                 WHERE s.quizid   = :quizid
                   AND s.courseid = :courseid
              ORDER BY s.status ASC, suspicious_count DESC';

        $records = $DB->get_records_sql($sql, [
            'quizid'   => $params['quizid'],
            'courseid' => $params['courseid'],
        ]);

        if (empty($records)) {
            // Fallback: jika courseid tidak cocok, ambil sesi berdasarkan quiz saja.
            $fallbackSql = str_replace('AND s.courseid = :courseid', '', $sql);
            $records = $DB->get_records_sql($fallbackSql, ['quizid' => $params['quizid']]);
        }

        $sessions = [];
        foreach ($records as $r) {
            // Hitung detik sejak heartbeat terakhir
            $secondsSinceHeartbeat = $now - $r->last_heartbeat;

            // Deteksi jika offline (tidak ada heartbeat > 15 detik) tapi masih active
            $isOffline = ($r->status === 'active' && $secondsSinceHeartbeat > 15);

            // Deteksi tipe klien dari user agent
            $ua = $r->useragent ?? '';
            if (stripos($ua, 'ExamDosmanAndroid') !== false) {
                $clientType = 'android';
            } elseif (stripos($ua, 'ExamDosmanIOS') !== false) {
                $clientType = 'ios';
            } elseif (stripos($ua, 'SafeExamBrowser') !== false || stripos($ua, '/SEB') !== false || stripos($ua, ' SEB/') !== false) {
                $clientType = 'seb';
            } elseif ($ua !== '') {
                $clientType = 'browser';
            } else {
                $clientType = 'unknown';
            }

            $sessions[] = [
                'id'                      => (int)$r->id,
                'userid'                  => (int)$r->userid,
                'firstname'               => $r->firstname,
                'lastname'                => $r->lastname,
                'email'                   => $r->email,
                'department'              => $r->department ?? '',
                'institution'             => $r->institution ?? '',
                'quizid'                  => (int)$r->quizid,
                'courseid'                => (int)$r->courseid,
                'status'                  => $r->status,
                'is_offline'              => $isOffline,
                'last_heartbeat'          => (int)$r->last_heartbeat,
                'seconds_since_heartbeat' => (int)$secondsSinceHeartbeat,
                'blocked_reason'          => $r->blocked_reason ?? '',
                'blocked_at'              => (int)($r->blocked_at ?? 0),
                'pause_granted_at'        => (int)($r->pause_granted_at ?? 0),
                'reset_count'             => (int)$r->reset_count,
                'suspicious_count'        => (int)$r->suspicious_count,
                'timecreated'             => (int)$r->timecreated,
                'timemodified'            => (int)($r->timemodified ?? 0),
                'exit_request'            => $r->exit_request ?? 'none',
                'exit_requested_at'       => (int)($r->exit_requested_at ?? 0),
                'exit_processed_at'       => (int)($r->exit_processed_at ?? 0),
                'client_type'             => $clientType,
            ];
        }

        // Supplement: siswa yang terdeteksi di appstatus (current_quizid = quizid) tapi belum punya sesi
        $sessionUserIds = array_column($sessions, 'userid');
        $appSupplements = $DB->get_records_sql(
            "SELECT a.userid, a.lastping, a.lock_status,
                    u.firstname, u.lastname, u.email,
                    u.department, u.institution
               FROM {local_dosman_ujian_appstatus} a
               JOIN {user} u ON u.id = a.userid
              WHERE a.current_quizid = :quizid AND a.lock_status > 0",
            ['quizid' => $params['quizid']]
        );
        foreach ($appSupplements as $a) {
            if (in_array((int)$a->userid, $sessionUserIds)) continue;
            $secAgo          = $now - (int)$a->lastping;
            $ls              = (int)$a->lock_status;
            $isGlobalBlocked = ($ls === 2);
            $isGlobalPaused  = ($ls === 3);
            $sessions[] = [
                'id'                      => 0,
                'userid'                  => (int)$a->userid,
                'firstname'               => $a->firstname,
                'lastname'                => $a->lastname,
                'email'                   => $a->email,
                'department'              => $a->department ?? '',
                'institution'             => $a->institution ?? '',
                'quizid'                  => (int)$params['quizid'],
                'courseid'                => (int)$params['courseid'],
                'status'                  => $isGlobalBlocked ? 'blocked' : ($isGlobalPaused ? 'paused' : 'active'),
                'is_offline'              => ($secAgo > 15),
                'last_heartbeat'          => (int)$a->lastping,
                'seconds_since_heartbeat' => (int)$secAgo,
                'blocked_reason'          => $isGlobalBlocked ? 'Diblokir global oleh pengawas' : '',
                'blocked_at'              => 0,
                'pause_granted_at'        => $isGlobalPaused ? $now : 0,
                'reset_count'             => 0,
                'suspicious_count'        => 0,
                'timecreated'             => (int)$a->lastping,
                'timemodified'            => (int)$a->lastping,
                'exit_request'            => 'none',
                'exit_requested_at'       => 0,
                'exit_processed_at'       => 0,
                'client_type'             => 'android',
            ];
        }

        // Statistik ringkasan
        $totalActive       = count(array_filter($sessions, fn($s) => $s['status'] === 'active' && !$s['is_offline']));
        $totalBlocked      = count(array_filter($sessions, fn($s) => $s['status'] === 'blocked'));
        $totalPaused       = count(array_filter($sessions, fn($s) => $s['status'] === 'paused'));
        $totalOffline      = count(array_filter($sessions, fn($s) => $s['is_offline']));
        $totalExitPending  = count(array_filter($sessions, fn($s) => ($s['exit_request'] ?? 'none') === 'pending'));

        return [
            'sessions'            => $sessions,
            'total_active'        => $totalActive,
            'total_blocked'       => $totalBlocked,
            'total_paused'        => $totalPaused,
            'total_offline'       => $totalOffline,
            'total_exit_pending'  => $totalExitPending,
        ];
    }

    public static function execute_returns(): external_single_structure {
        return new external_single_structure([
            'sessions' => new external_multiple_structure(
                new external_single_structure([
                    'id'                      => new external_value(PARAM_INT,   'Session ID'),
                    'userid'                  => new external_value(PARAM_INT,   'User ID'),
                    'firstname'               => new external_value(PARAM_TEXT,  'First name'),
                    'lastname'                => new external_value(PARAM_TEXT,  'Last name'),
                    'email'                   => new external_value(PARAM_EMAIL, 'Email'),
                    'department'              => new external_value(PARAM_TEXT,  'User department (often class)', VALUE_DEFAULT, ''),
                    'institution'             => new external_value(PARAM_TEXT,  'User institution', VALUE_DEFAULT, ''),
                    'quizid'                  => new external_value(PARAM_INT,   'Quiz ID'),
                    'courseid'                => new external_value(PARAM_INT,   'Course ID'),
                    'status'                  => new external_value(PARAM_TEXT,  'Status: active, paused, blocked, completed'),
                    'is_offline'              => new external_value(PARAM_BOOL,  'True if no heartbeat > 15s'),
                    'last_heartbeat'          => new external_value(PARAM_INT,   'Last heartbeat timestamp'),
                    'seconds_since_heartbeat' => new external_value(PARAM_INT,   'Seconds since last heartbeat'),
                    'blocked_reason'          => new external_value(PARAM_TEXT,  'Reason for blocking'),
                    'blocked_at'              => new external_value(PARAM_INT,   'Blocked timestamp'),
                    'pause_granted_at'        => new external_value(PARAM_INT,   'Pause granted timestamp'),
                    'reset_count'             => new external_value(PARAM_INT,   'Number of resets by teacher'),
                    'suspicious_count'        => new external_value(PARAM_INT,   'Number of suspicious events'),
                    'timecreated'             => new external_value(PARAM_INT,   'Session created timestamp'),
                    'timemodified'            => new external_value(PARAM_INT,   'Session updated timestamp'),
                    'exit_request'            => new external_value(PARAM_TEXT,  'Exit request: none, pending, approved, rejected'),
                    'exit_requested_at'       => new external_value(PARAM_INT,   'When exit was requested'),
                    'exit_processed_at'       => new external_value(PARAM_INT,   'When exit was approved/rejected'),
                    'client_type'             => new external_value(PARAM_TEXT,  'Client type: android, seb, browser, unknown', VALUE_DEFAULT, 'unknown'),
                ])
            ),
            'total_active'        => new external_value(PARAM_INT, 'Total active students'),
            'total_blocked'       => new external_value(PARAM_INT, 'Total blocked students'),
            'total_paused'        => new external_value(PARAM_INT, 'Total paused students'),
            'total_offline'       => new external_value(PARAM_INT, 'Total offline students'),
            'total_exit_pending'  => new external_value(PARAM_INT, 'Students waiting for exit approval'),
        ]);
    }
}
