<?php
/**
 * External function: heartbeat
 * Siswa kirim sinyal tiap 10 detik untuk buktikan masih aktif.
 * Jika tidak ada heartbeat 45 detik -> suspend akun Moodle langsung.
 *
 * @package    local_dosman_ujian
 * @copyright  2024 Dosman Ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

namespace local_dosman_ujian\external;

defined('MOODLE_INTERNAL') || die();
require_once($CFG->libdir . '/externallib.php');

use external_api;
use external_value;
use external_single_structure;
use external_function_parameters;

class heartbeat extends external_api {

    // Timeout 45 detik tanpa heartbeat = suspend langsung (tidak ada Tier 1 device block)
    const HEARTBEAT_TIMEOUT = 45;

    public static function execute_parameters(): external_function_parameters {
        return new external_function_parameters([
            'session_id' => new external_value(PARAM_INT, 'Session ID'),
            'userid'     => new external_value(PARAM_INT, 'Student user ID'),
        ]);
    }

    public static function execute(int $sessionId, int $userid): array {
        global $DB, $USER;

        $params = self::validate_parameters(self::execute_parameters(), [
            'session_id' => $sessionId,
            'userid'     => $userid,
        ]);

        // Pastikan user yang request adalah user sendiri
        if ($USER->id != $params['userid'] && !is_siteadmin()) {
            return ['success' => false, 'status' => 'error', 'message' => 'Permission denied', 'exit_request' => 'none'];
        }

        // Cek apakah akun Moodle sudah disuspend (misal oleh guru dari dashboard)
        $userSuspended = $DB->get_field('user', 'suspended', ['id' => $params['userid']]);
        if ($userSuspended) {
            return ['success' => false, 'status' => 'suspended', 'message' => 'Akun Anda telah disuspend oleh guru. Hubungi guru untuk informasi lebih lanjut.', 'exit_request' => 'none'];
        }

        $session = $DB->get_record('local_dosman_ujian_sessions', [
            'id'     => $params['session_id'],
            'userid' => $params['userid'],
        ]);

        if (!$session) {
            return ['success' => false, 'status' => 'error', 'message' => 'Sesi tidak ditemukan', 'exit_request' => 'none'];
        }

        $now        = time();
        $ua         = substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 512);
        $exitreq    = $session->exit_request ?? 'none';

        // Jika diblokir, kembalikan status blocked
        if ($session->status === 'blocked') {
            return [
                'success'      => false,
                'status'       => 'blocked',
                'message'      => 'Akun Anda diblokir. Hubungi guru untuk membuka blokir.',
                'exit_request' => 'none',
            ];
        }

        // Guru menyetujui keluar — aplikasi harus tutup
        if ($session->status === 'released') {
            return [
                'success'      => true,
                'status'       => 'exit_approved',
                'message'      => 'Izin keluar disetujui. Tutup aplikasi.',
                'exit_request' => 'approved',
            ];
        }

        // Guru menolak permintaan izin (sekali), lalu reset agar ujian lanjut
        if ($session->status === 'active' && $exitreq === 'rejected') {
            $DB->update_record('local_dosman_ujian_sessions', (object)[
                'id'                => $session->id,
                'exit_request'      => 'none',
                'exit_requested_at' => null,
                'timemodified'      => $now,
            ]);
            return [
                'success'      => true,
                'status'       => 'exit_rejected',
                'message'      => 'Permintaan izin keluar ditolak oleh guru. Lanjutkan ujian.',
                'exit_request' => 'rejected',
            ];
        }

        // Jika paused, kembalikan status paused
        if ($session->status === 'paused') {
            return [
                'success'      => true,
                'status'       => 'paused',
                'message'      => 'Ujian sedang dijeda oleh guru.',
                'exit_request' => $exitreq,
            ];
        }

        // Perbarui last_heartbeat milik pemanggil saja; auto-suspend lintas siswa akibat
        // sinyal putus dinonaktifkan (selaras dengan stale_app_ping_suspend, cron task, dan get_sessions)
        // agar siswa semi-offline tidak mengalami blokir massal.
        $DB->update_record('local_dosman_ujian_sessions', (object)[
            'id'             => $session->id,
            'last_heartbeat' => $now,
            'useragent'      => $ua,
            'timemodified'   => $now,
        ]);

        return [
            'success'      => true,
            'status'       => 'active',
            'message'      => 'Heartbeat diterima',
            'exit_request' => $exitreq === 'pending' ? 'pending' : 'none',
        ];
    }

    public static function execute_returns(): external_single_structure {
        return new external_single_structure([
            'success'      => new external_value(PARAM_BOOL, 'Success status'),
            'status'       => new external_value(PARAM_TEXT, 'Session status: active, paused, blocked, exit_approved, exit_rejected, error'),
            'message'      => new external_value(PARAM_TEXT, 'Response message'),
            'exit_request' => new external_value(PARAM_TEXT, 'none, pending, approved, rejected', VALUE_DEFAULT, 'none'),
        ]);
    }
}
