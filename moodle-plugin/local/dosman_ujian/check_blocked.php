<?php
/**
 * Endpoint: cek apakah siswa diblokir atau disuspend.
 * Dipakai oleh Flutter app untuk mendeteksi status blokir/suspend.
 *
 * GET /local/dosman_ujian/check_blocked.php?userid=123
 * Response: { "blocked": bool, "reason": string }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

define('NO_MOODLE_COOKIES', true);
require_once(__DIR__ . '/../../config.php');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');

$userid = optional_param('userid', 0, PARAM_INT);
if ($userid <= 0) {
    echo json_encode(['blocked' => false, 'reason' => '']);
    exit;
}

$user = $DB->get_record('user', ['id' => $userid, 'deleted' => 0], 'id, suspended', IGNORE_MISSING);
if (!$user) {
    echo json_encode(['blocked' => false, 'reason' => '']);
    exit;
}

if ((int)$user->suspended === 1) {
    // Cari alasan spesifik dari devices atau appstatus
    $dev = $DB->get_record('local_dosman_ujian_devices', ['userid' => $userid, 'status' => 'blocked'], 'block_reason', IGNORE_MISSING);
    $reason = ($dev && !empty($dev->block_reason))
        ? $dev->block_reason
        : 'Akun Anda ditangguhkan (Suspended) karena pelanggaran kuncian ujian. Harap segera melapor ke pengawas.';

    echo json_encode([
        'blocked' => true,
        'reason'  => $reason,
    ]);
    exit;
}

// Cek appstatus lock_status
$appstatus = $DB->get_record('local_dosman_ujian_appstatus', ['userid' => $userid], 'lock_status', IGNORE_MISSING);
if ($appstatus && (int)$appstatus->lock_status === 2) {
    echo json_encode([
        'blocked' => true,
        'reason'  => 'Akun Anda diblokir oleh pengawas ujian.',
    ]);
    exit;
}

// Cek devices blocked
$devBlocked = $DB->get_record('local_dosman_ujian_devices', ['userid' => $userid, 'status' => 'blocked'], 'block_reason', IGNORE_MISSING);
if ($devBlocked) {
    echo json_encode([
        'blocked' => true,
        'reason'  => $devBlocked->block_reason ?: 'Perangkat Anda diblokir oleh pengawas ujian.',
    ]);
    exit;
}

echo json_encode(['blocked' => false, 'reason' => '']);
