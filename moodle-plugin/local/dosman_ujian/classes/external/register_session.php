<?php
/**
 * External function: register_session
 * Siswa daftarkan sesi ujian saat lockdown dimulai
 *
 * @package    local_dosman_ujian
 * @copyright  2024 Dosman Ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\external;

defined('MOODLE_INTERNAL') || die();
require_once($CFG->libdir . '/externallib.php');
require_once(__DIR__ . '/../../device_id_helper.inc.php');
require_once(__DIR__ . '/../../lib.php');

use external_api;
use external_value;
use external_single_structure;
use external_function_parameters;
use context_course;

class register_session extends external_api {

    public static function execute_parameters(): external_function_parameters {
        return new external_function_parameters([
            'userid'   => new external_value(PARAM_INT,  'Student user ID'),
            'quizid'   => new external_value(PARAM_INT,  'Quiz ID'),
            'courseid' => new external_value(PARAM_INT,  'Course ID'),
        ]);
    }

    public static function execute(int $userid, int $quizid, int $courseid): array {
        global $DB, $USER;

        $params = self::validate_parameters(self::execute_parameters(), [
            'userid'   => $userid,
            'quizid'   => $quizid,
            'courseid' => $courseid,
        ]);

        $context = context_course::instance($params['courseid']);
        self::validate_context($context);

        // Pastikan user yang request adalah user sendiri
        if ($USER->id != $params['userid'] && !is_siteadmin()) {
            return ['success' => false, 'status' => 'error', 'message' => 'Permission denied'];
        }

        // Penegakan mode akses jaringan (Lokal / Offline Saja vs Lokal & Online)
        $netMode      = trim((string)(get_config('local_dosman_ujian', 'network_access_mode') ?: 'both'));
        $allowedCidrs = (string)(get_config('local_dosman_ujian', 'allowed_local_cidrs') ?: '');
        $clientIp     = $_SERVER['REMOTE_ADDR'] ?? '';
        $isExempt     = is_siteadmin()
            || local_dosman_ujian_is_teacher_or_above($params['userid'])
            || dosman_is_reviewer_username((string)($USER->username ?? ''));
        if ($netMode === 'local_only' && !$isExempt && !dosman_is_local_school_ip($clientIp, $allowedCidrs)) {
            return [
                'success'    => false,
                'status'     => 'blocked',
                'message'    => 'Akses ujian saat ini dikunci khusus Wi-Fi lokal sekolah (EXAM DOSMAN). Matikan data seluler, sambungkan HP ke Wi-Fi EXAM DOSMAN, lalu coba mulai ujian lagi.',
                'session_id' => 0,
            ];
        }

        $now = time();
        $ua  = substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 512);

        // Cek apakah sudah ada sesi untuk quiz ini
        $existing = $DB->get_record('local_dosman_ujian_sessions', [
            'userid'  => $params['userid'],
            'quizid'  => $params['quizid'],
        ]);

        // Sesi "released" = guru sudah izinkan keluar; buat sesi baru agar siswa bisa login lagi
        if ($existing && $existing->status === 'released') {
            $DB->delete_records('local_dosman_ujian_sessions', ['id' => $existing->id]);
            $existing = null;
        }

        if ($existing) {
            // Jika statusnya blocked, siswa tidak bisa masuk
            if ($existing->status === 'blocked') {
                return [
                    'success'    => false,
                    'status'     => 'blocked',
                    'message'    => 'Akun Anda diblokir karena keluar dari ujian tanpa izin. Hubungi guru untuk membuka blokir.',
                    'session_id' => (int)$existing->id,
                ];
            }

            // Jika paused, izinkan masuk kembali
            if ($existing->status === 'paused') {
                return [
                    'success'    => true,
                    'status'     => 'paused',
                    'message'    => 'Sesi sedang dijeda oleh guru. Tunggu guru mengaktifkan kembali.',
                    'session_id' => (int)$existing->id,
                ];
            }

            // Update heartbeat jika sesi aktif
            $DB->update_record('local_dosman_ujian_sessions', (object)[
                'id'             => $existing->id,
                'status'         => 'active',
                'last_heartbeat' => $now,
                'useragent'      => $ua,
                'timemodified'   => $now,
            ]);

            return [
                'success'    => true,
                'status'     => 'active',
                'message'    => 'Sesi aktif',
                'session_id' => (int)$existing->id,
            ];
        }

        // Buat sesi baru
        $record = (object)[
            'userid'            => $params['userid'],
            'quizid'            => $params['quizid'],
            'courseid'          => $params['courseid'],
            'status'            => 'active',
            'last_heartbeat'    => $now,
            'useragent'         => $ua,
            'blocked_reason'    => null,
            'blocked_at'        => null,
            'pause_granted_at'  => null,
            'reset_count'       => 0,
            'exit_request'      => 'none',
            'exit_requested_at' => null,
            'exit_processed_at' => null,
            'timecreated'       => $now,
            'timemodified'      => $now,
        ];

        $sessionId = $DB->insert_record('local_dosman_ujian_sessions', $record);

        return [
            'success'    => true,
            'status'     => 'active',
            'message'    => 'Sesi baru dibuat',
            'session_id' => (int)$sessionId,
        ];
    }

    public static function execute_returns(): external_single_structure {
        return new external_single_structure([
            'success'    => new external_value(PARAM_BOOL, 'Success status'),
            'status'     => new external_value(PARAM_TEXT, 'Session status: active, paused, blocked, error'),
            'message'    => new external_value(PARAM_TEXT, 'Response message'),
            'session_id' => new external_value(PARAM_INT,  'Session ID', VALUE_DEFAULT, 0),
        ]);
    }
}
