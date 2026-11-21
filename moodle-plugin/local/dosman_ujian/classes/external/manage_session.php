<?php
/**
 * External function: manage_session
 * Guru kelola sesi siswa: pause, resume, blokir, reset
 *
 * @package    local_dosman_ujian
 * @copyright  2024 Dosman Ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\external;

defined('MOODLE_INTERNAL') || die();
require_once($CFG->libdir . '/externallib.php');
require_once($CFG->dirroot . '/local/dosman_ujian/lib.php');
require_once($CFG->dirroot . '/local/dosman_ujian/device_id_helper.inc.php');

use external_api;
use external_value;
use external_single_structure;
use external_function_parameters;
use context_course;

class manage_session extends external_api {

    public static function execute_parameters(): external_function_parameters {
        return new external_function_parameters([
            'session_id' => new external_value(PARAM_INT,  'Session ID'),
            'courseid'   => new external_value(PARAM_INT,  'Course ID for permission check'),
            'action'     => new external_value(PARAM_TEXT, 'Action: pause, resume, block, reset, approve_exit, reject_exit'),
            'reason'     => new external_value(PARAM_TEXT, 'Reason for action', VALUE_DEFAULT, ''),
        ]);
    }

    public static function execute(int $sessionId, int $courseid, string $action, string $reason = ''): array {
        global $DB;

        $params = self::validate_parameters(self::execute_parameters(), [
            'session_id' => $sessionId,
            'courseid'   => $courseid,
            'action'     => $action,
            'reason'     => $reason,
        ]);

        // Validasi hanya guru/admin yang bisa akses
        $context = context_course::instance($params['courseid']);
        self::validate_context($context);
        if (!local_dosman_ujian_user_can_monitor_course($context)) {
            require_capability('mod/quiz:viewreports', $context);
        }

        $session = $DB->get_record('local_dosman_ujian_sessions', ['id' => $params['session_id']]);
        if (!$session) {
            return ['success' => false, 'message' => 'Sesi tidak ditemukan'];
        }

        $now = time();

        switch ($params['action']) {

            case 'pause':
                // Guru menjeda sesi siswa: set session paused + lock_status=3 (halaman jeda di device)
                $DB->update_record('local_dosman_ujian_sessions', (object)[
                    'id'               => $session->id,
                    'status'           => 'paused',
                    'pause_granted_at' => $now,
                    'timemodified'     => $now,
                ]);
                $DB->execute(
                    'UPDATE {local_dosman_ujian_appstatus} SET lock_status = 3 WHERE userid = ? AND lock_status = 1',
                    [$session->userid]
                );
                @unlink('/dev/shm/dosman_app_users_cache.json');
                return ['success' => true, 'message' => 'Sesi siswa berhasil dijeda.'];

            case 'resume':
                // Guru aktifkan kembali: set session active + lock_status=1 (buka jeda)
                $DB->update_record('local_dosman_ujian_sessions', (object)[
                    'id'               => $session->id,
                    'status'           => 'active',
                    'last_heartbeat'   => $now,
                    'pause_granted_at' => null,
                    'timemodified'     => $now,
                ]);
                $DB->execute(
                    'UPDATE {local_dosman_ujian_appstatus} SET lock_status = 1 WHERE userid = ? AND lock_status = 3',
                    [$session->userid]
                );
                @unlink('/dev/shm/dosman_app_users_cache.json');
                return ['success' => true, 'message' => 'Sesi siswa berhasil diaktifkan kembali.'];

            case 'block':
                // Pastikan admin, manager, atau reviewer kebal dari blokir/suspend
                $targetUser = $DB->get_record('user', ['id' => $session->userid], 'id, username');
                $isManager = $DB->record_exists_sql(
                    "SELECT 1
                       FROM {role_assignments} ra
                       JOIN {role} r ON r.id = ra.roleid
                      WHERE ra.userid = :uid AND r.shortname = 'manager'",
                    ['uid' => $session->userid]
                );
                if (\is_siteadmin($session->userid) || $isManager
                    || ($targetUser && dosman_is_reviewer_username((string)$targetUser->username))) {
                    return ['success' => false, 'message' => 'Akun admin, manager, atau reviewer tidak dapat diblokir.'];
                }

                // Guru blokir manual
                $DB->update_record('local_dosman_ujian_sessions', (object)[
                    'id'             => $session->id,
                    'status'         => 'blocked',
                    'blocked_reason' => $params['reason'] ?: 'Diblokir oleh guru',
                    'blocked_at'     => $now,
                    'timemodified'   => $now,
                ]);
                // Set global lock_status = 2 (siswa lihat halaman blokir di semua halaman)
                $DB->execute(
                    'UPDATE {local_dosman_ujian_appstatus} SET lock_status = 2 WHERE userid = ?',
                    [$session->userid]
                );
                // Auto-suspend akun Moodle: siswa tidak bisa login ke app maupun web
                $DB->set_field('user', 'suspended',     1,    ['id' => $session->userid]);
                $DB->set_field('user', 'timemodified',  $now, ['id' => $session->userid]);
                // Hapus token webservice mobile agar sesi app langsung tidak valid
                $svcRows = $DB->get_records_list(
                    'external_services',
                    'shortname',
                    ['dosman_ujian_mobile', 'moodle_mobile_app'],
                    '',
                    'id'
                );
                if (!empty($svcRows)) {
                    list($insql, $inparams) = $DB->get_in_or_equal(array_keys($svcRows), SQL_PARAMS_NAMED);
                    $DB->delete_records_select(
                        'external_tokens',
                        "userid = :uid AND externalserviceid $insql",
                        array_merge(['uid' => $session->userid], $inparams)
                    );
                }
                // Hapus sesi Moodle web → siswa logout dari browser
                \core\session\manager::kill_user_sessions($session->userid);
                // Catat ke log
                $DB->insert_record('local_dosman_ujian_logs', (object)[
                    'userid'      => $session->userid,
                    'courseid'    => $session->courseid,
                    'quizid'      => $session->quizid,
                    'eventtype'   => 'manually_blocked',
                    'eventdata'   => json_encode(['reason' => $params['reason']]),
                    'suspicious'  => 1,
                    'timecreated' => $now,
                ]);
                // Blokir semua device fisik siswa agar tidak bisa reinstall dan masuk lagi
                $DB->execute(
                    "UPDATE {local_dosman_ujian_devices}
                        SET status = 'blocked',
                            block_reason = ?,
                            blocked_at = ?
                      WHERE userid = ? AND status = 'active'",
                    [$params['reason'] ?: 'Diblokir oleh guru', $now, $session->userid]
                );
                @unlink('/dev/shm/dosman_app_users_cache.json');
                return ['success' => true, 'message' => 'Siswa berhasil diblokir dan akun di-suspend.'];

            case 'reset':
                // Guru reset blokir - siswa bisa masuk lagi
                $DB->update_record('local_dosman_ujian_sessions', (object)[
                    'id'             => $session->id,
                    'status'         => 'active',
                    'last_heartbeat' => $now,
                    'blocked_reason' => null,
                    'blocked_at'     => null,
                    'reset_count'    => $session->reset_count + 1,
                    'timemodified'   => $now,
                ]);
                // Set global lock_status = 1 (buka blokir global, hanya jika sebelumnya 2)
                $DB->execute(
                    'UPDATE {local_dosman_ujian_appstatus} SET lock_status = 1 WHERE userid = ? AND lock_status = 2',
                    [$session->userid]
                );
                // Unsuspend akun Moodle — simetris dengan aksi block yang men-suspend
                $DB->set_field('user', 'suspended',    0,    ['id' => $session->userid]);
                $DB->set_field('user', 'timemodified', $now, ['id' => $session->userid]);
                // Catat ke log
                $DB->insert_record('local_dosman_ujian_logs', (object)[
                    'userid'      => $session->userid,
                    'courseid'    => $session->courseid,
                    'quizid'      => $session->quizid,
                    'eventtype'   => 'session_reset',
                    'eventdata'   => json_encode(['reset_count' => $session->reset_count + 1]),
                    'suspicious'  => 0,
                    'timecreated' => $now,
                ]);
                // Buka blokir device fisik siswa (simetris dengan block)
                $DB->execute(
                    "UPDATE {local_dosman_ujian_devices}
                        SET status = 'active', block_reason = NULL, blocked_at = NULL
                      WHERE userid = ?",
                    [$session->userid]
                );
                @unlink('/dev/shm/dosman_app_users_cache.json');
                return ['success' => true, 'message' => 'Blokir sesi direset dan akun diaktifkan kembali.'];

            case 'approve_exit':
                if (($session->exit_request ?? 'none') !== 'pending') {
                    return ['success' => false, 'message' => 'Tidak ada permintaan izin keluar yang menunggu.'];
                }
                $DB->update_record('local_dosman_ujian_sessions', (object)[
                    'id'                => $session->id,
                    'status'            => 'released',
                    'exit_request'      => 'approved',
                    'exit_processed_at' => $now,
                    'timemodified'      => $now,
                ]);
                $DB->insert_record('local_dosman_ujian_logs', (object)[
                    'userid'      => $session->userid,
                    'courseid'    => $session->courseid,
                    'quizid'      => $session->quizid,
                    'eventtype'   => 'exit_approved',
                    'eventdata'   => json_encode(['session_id' => $session->id]),
                    'suspicious'  => 0,
                    'timecreated' => $now,
                ]);
                return ['success' => true, 'message' => 'Izin keluar disetujui. Aplikasi siswa akan menutup.'];

            case 'reject_exit':
                if (($session->exit_request ?? 'none') !== 'pending') {
                    return ['success' => false, 'message' => 'Tidak ada permintaan yang menunggu.'];
                }
                $DB->update_record('local_dosman_ujian_sessions', (object)[
                    'id'                => $session->id,
                    'exit_request'      => 'rejected',
                    'exit_processed_at' => $now,
                    'timemodified'      => $now,
                ]);
                $DB->insert_record('local_dosman_ujian_logs', (object)[
                    'userid'      => $session->userid,
                    'courseid'    => $session->courseid,
                    'quizid'      => $session->quizid,
                    'eventtype'   => 'exit_rejected',
                    'eventdata'   => json_encode(['session_id' => $session->id]),
                    'suspicious'  => 0,
                    'timecreated' => $now,
                ]);
                return ['success' => true, 'message' => 'Permintaan izin keluar ditolak. Siswa melanjutkan ujian.'];

            default:
                return ['success' => false, 'message' => 'Action tidak valid. Gunakan: pause, resume, block, reset, approve_exit, reject_exit'];
        }
    }

    public static function execute_returns(): external_single_structure {
        return new external_single_structure([
            'success' => new external_value(PARAM_BOOL, 'Success status'),
            'message' => new external_value(PARAM_TEXT, 'Response message'),
        ]);
    }
}
