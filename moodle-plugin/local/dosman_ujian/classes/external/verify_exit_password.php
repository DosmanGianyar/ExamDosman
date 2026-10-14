<?php
/**
 * External function: verify_exit_password
 * Verifikasi password keluar siswa terhadap config admin di server.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
namespace local_dosman_ujian\external;

defined('MOODLE_INTERNAL') || die();
require_once($CFG->libdir . '/externallib.php');

use external_api;
use external_value;
use external_single_structure;
use external_function_parameters;

class verify_exit_password extends external_api {
    public static function execute_parameters(): external_function_parameters {
        return new external_function_parameters([
            'session_id' => new external_value(PARAM_INT, 'Session ID'),
            'userid' => new external_value(PARAM_INT, 'Student user ID'),
            'password' => new external_value(PARAM_TEXT, 'Exit password entered by user'),
        ]);
    }

    public static function execute(int $sessionId, int $userid, string $password): array {
        global $DB, $USER;

        $params = self::validate_parameters(self::execute_parameters(), [
            'session_id' => $sessionId,
            'userid' => $userid,
            'password' => $password,
        ]);

        if ($USER->id != $params['userid'] && !is_siteadmin()) {
            return ['success' => false, 'message' => 'Permission denied'];
        }

        $session = $DB->get_record('local_dosman_ujian_sessions', [
            'id' => $params['session_id'],
            'userid' => $params['userid'],
        ]);
        if (!$session) {
            return ['success' => false, 'message' => 'Sesi tidak ditemukan'];
        }

        if (!in_array($session->status, ['active', 'paused'])) {
            return ['success' => false, 'message' => 'Sesi tidak valid untuk verifikasi keluar'];
        }

        // Baca langsung dari tabel config_plugins agar selalu mendapat nilai terbaru.
        // setpwd.php menyimpan langsung ke DB, sehingga get_config() bisa tertinggal cache.
        $savedrec = $DB->get_record('config_plugins', [
            'plugin' => 'local_dosman_ujian',
            'name' => 'admin_exit_password',
        ], 'value', IGNORE_MISSING);
        $saved = $savedrec ? (string) $savedrec->value : (string) get_config('local_dosman_ujian', 'admin_exit_password');
        $saved = trim($saved);
        if ($saved === '') {
            return ['success' => false, 'message' => 'Password keluar belum diset oleh admin'];
        }

        $entered = trim((string) $params['password']);

        // Akun reviewer Play Store & App Store selalu dapat keluar dengan 123456
        $currentUser = $DB->get_record('user', ['id' => $params['userid']], 'username');
        if ($currentUser) {
            $uname = strtolower(trim($currentUser->username));
            if (in_array($uname, ['playstore.review', 'appstore.review'], true) && $entered === '123456') {
                return [
                    'success' => true,
                    'message' => 'Password valid (Reviewer)',
                ];
            }
        }

        $ok = hash_equals($saved, $entered);
        return [
            'success' => $ok,
            'message' => $ok ? 'Password valid' : 'Password admin salah',
        ];
    }

    public static function execute_returns(): external_single_structure {
        return new external_single_structure([
            'success' => new external_value(PARAM_BOOL, 'Verification result'),
            'message' => new external_value(PARAM_TEXT, 'Response message'),
        ]);
    }
}

