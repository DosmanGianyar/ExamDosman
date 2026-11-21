<?php
/**
 * Heartbeat endpoint untuk siswa yang mengakses ujian via WebView (browser dalam app).
 * Dipanggil oleh JavaScript yang diinjeksi ke halaman kuis setiap 15 detik.
 *
 * GET  ?quizid=X
 * Response: { status: 'active'|'blocked'|'paused'|'error' }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

define('AJAX_SCRIPT', true);
require_once(__DIR__ . '/../../config.php');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');

// Hanya untuk Dosman Exam app (Android & iOS)
$ua = $_SERVER['HTTP_USER_AGENT'] ?? '';
if (strpos($ua, 'ExamDosmanAndroid') === false && strpos($ua, 'ExamDosmanIOS') === false) {
    echo json_encode(['status' => 'ignored']);
    exit;
}

require_login(null, false);

if (empty($USER->id) || \isguestuser($USER)) {
    echo json_encode(['status' => 'error', 'reason' => 'not_logged_in']);
    exit;
}

$userid = (int)$USER->id;
// Lepaskan session lock Redis seketika agar klik soal / autosave kuis 800 siswa tidak pernah mengantre!
\core\session\manager::write_close();

$quizid = (int)($_GET['quizid'] ?? 0);
if ($quizid <= 0) {
    echo json_encode(['status' => 'error', 'reason' => 'missing_quizid']);
    exit;
}

$now = time();

// Hormati status suspend / blokir global / jeda agar AJAX heartbeat tidak menimpa blokir pengawas.
$isSuspended = !empty($USER->suspended)
    || (int)$DB->get_field('user', 'suspended', ['id' => $userid]) === 1;
$appStatusRow = $DB->get_record('local_dosman_ujian_appstatus', ['userid' => $userid], 'lock_status');
$curLockStatus = $appStatusRow ? (int)$appStatusRow->lock_status : 0;

if ($isSuspended || $curLockStatus === 2) {
    if ($appStatusRow) {
        $DB->execute(
            'UPDATE {local_dosman_ujian_appstatus} SET current_quizid = 0, lastping = ? WHERE userid = ?',
            [$now, $userid]
        );
    }
    echo json_encode(['status' => 'blocked', 'reason' => 'Akun Anda diblokir oleh pengawas ujian.']);
    exit;
}

if ($curLockStatus === 3) {
    echo json_encode(['status' => 'paused', 'reason' => 'Ujian Anda sedang dijeda oleh pengawas.']);
    exit;
}

$quiz = $DB->get_record('quiz', ['id' => $quizid], 'id,course');
if (!$quiz) {
    echo json_encode(['status' => 'error', 'reason' => 'quiz_not_found']);
    exit;
}
$courseid = (int)$quiz->course;

$clientip = $_SERVER['REMOTE_ADDR'] ?? '';

$existing = $DB->get_record('local_dosman_ujian_sessions', ['userid' => $userid, 'quizid' => $quizid]);

if ($existing) {
    if ($existing->status === 'blocked') {
        // Siswa diblokir: reset current_quizid di appstatus (tidak sedang mengerjakan)
        $DB->execute(
            'UPDATE {local_dosman_ujian_appstatus} SET current_quizid = 0, lastping = ? WHERE userid = ?',
            [$now, $userid]
        );
        echo json_encode(['status' => 'blocked', 'reason' => $existing->blocked_reason ?? '']);
        exit;
    }
    // Optimasi 800 siswa: hanya update jika last_heartbeat sudah >= 15 detik
    if (($now - (int)$existing->last_heartbeat) >= 15) {
        $DB->update_record('local_dosman_ujian_sessions', (object)[
            'id'             => $existing->id,
            'last_heartbeat' => $now,
            'timemodified'   => $now,
        ]);
    }
} else {
    $uaStr = substr($ua, 0, 512);
    $DB->insert_record('local_dosman_ujian_sessions', (object)[
        'userid'            => $userid,
        'quizid'            => $quizid,
        'courseid'          => $courseid,
        'status'            => 'active',
        'last_heartbeat'    => $now,
        'useragent'         => $uaStr,
        'blocked_reason'    => null,
        'blocked_at'        => null,
        'pause_granted_at'  => null,
        'reset_count'       => 0,
        'exit_request'      => 'none',
        'exit_requested_at' => null,
        'exit_processed_at' => null,
        'timecreated'       => $now,
        'timemodified'      => $now,
    ]);
}

// UPSERT appstatus tanpa menimpa lock_status = 2 (blokir) atau 3 (jeda).
$DB->execute(
    "INSERT INTO {local_dosman_ujian_appstatus}
        (userid, lock_status, current_quizid, lastping, ipaddress)
     VALUES (?, 1, ?, ?, ?)
     ON DUPLICATE KEY UPDATE
        lock_status    = IF(lock_status IN (2, 3), lock_status, 1),
        current_quizid = VALUES(current_quizid),
        lastping       = VALUES(lastping),
        ipaddress      = VALUES(ipaddress)",
    [$userid, $quizid, $now, $clientip]
);

echo json_encode(['status' => $existing->status ?? 'active']);
