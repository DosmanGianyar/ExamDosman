<?php
/**
 * Endpoint: blokir perangkat siswa tanpa suspend akun Moodle.
 * Tier 1 anti-kecurangan — guru bisa buka blokir sebelum cron escalate ke suspend penuh.
 *
 * POST body (JSON): { token, device_id, reason }
 * token = token siswa sendiri (bukan guru)
 * Response: { success: bool, message: string }
 *
 * @package    local_dosman_ujian
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

require_once __DIR__ . '/device_id_helper.inc.php';

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method not allowed']);
    exit;
}

$body     = json_decode(file_get_contents('php://input'), true) ?: [];
$token    = trim((string)($body['token']     ?? ''));
$deviceId = trim((string)($body['device_id'] ?? ''));
$reason   = trim((string)($body['reason']    ?? ''));

if ($token === '' || $deviceId === '') {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap']);
    exit;
}

// Validasi format device_id (alphanumeric, titik, dash, underscore; mendukung Android Build.ID)
if (!dosman_is_valid_device_id_format($deviceId)) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Format device_id tidak valid']);
    exit;
}

// Batasi panjang reason
if (mb_strlen($reason) > 255) {
    $reason = mb_substr($reason, 0, 255);
}

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) throw new RuntimeException('config.php not found');

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $key) {
        if (preg_match('/\$CFG->' . $key . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$key] = $m[1];
        }
    }
    if (empty($cfg['dbname'])) throw new RuntimeException('DB config not parseable');

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    // Validasi token siswa → dapatkan userid
    $stmtTok = $pdo->prepare(
        "SELECT userid FROM {$prefix}external_tokens
          WHERE token = ?
            AND (validuntil = 0 OR validuntil > UNIX_TIMESTAMP())
          LIMIT 1"
    );
    $stmtTok->execute([$token]);
    $userid = $stmtTok->fetchColumn();
    if ($userid === false) {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Token tidak valid']);
        exit;
    }
    $userid = (int)$userid;

    // Akun reviewer kebal dari blokir perangkat
    $stmtUser = $pdo->prepare("SELECT username FROM {$prefix}user WHERE id = ? LIMIT 1");
    $stmtUser->execute([$userid]);
    $targetUsername = (string)($stmtUser->fetchColumn() ?: '');
    if (dosman_is_reviewer_username($targetUsername)) {
        echo json_encode(['success' => false, 'message' => 'Akun reviewer kebal dari blokir perangkat']);
        exit;
    }

    if (dosman_is_legacy_ignored_violation_reason($reason)) {
        echo json_encode(['success' => false, 'ignored' => true, 'message' => 'Aturan legacy dinonaktifkan, blokir perangkat diabaikan']);
        exit;
    }

    if (dosman_get_active_quiz_id($pdo, $prefix, $userid) <= 0) {
        echo json_encode(['success' => false, 'ignored' => true, 'message' => 'Siswa tidak sedang mengerjakan ujian aktif, blokir perangkat diabaikan']);
        exit;
    }

    $storageDeviceId = dosman_normalize_storage_device_id($deviceId, $userid);

    $now = time();

    $pdo->beginTransaction();

    // Step 1: Upsert device record
    $pdo->prepare(
        "INSERT INTO {$prefix}local_dosman_ujian_devices
             (device_id, userid, platform, status, block_reason, blocked_at, registered_at, last_seen)
         VALUES (?, ?, 'android', 'blocked', ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE
             userid       = VALUES(userid),
             status       = 'blocked',
             block_reason = VALUES(block_reason),
             blocked_at   = VALUES(blocked_at),
             last_seen    = VALUES(last_seen)"
    )->execute([$storageDeviceId, $userid, $reason, $now, $now, $now]);

    // Step 2: Set appstatus lock_status=2
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_appstatus
            SET lock_status = 2
          WHERE userid = ?"
    )->execute([$userid]);

    // Step 3: Block active/paused dosman sessions
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_sessions
            SET status         = 'blocked',
                blocked_reason = ?,
                blocked_at     = ?,
                timemodified   = ?
          WHERE userid = ? AND status IN ('active','paused')"
    )->execute([$reason, $now, $now, $userid]);

    // Step 4: Log the violation
    $pdo->prepare(
        "INSERT INTO {$prefix}local_dosman_ujian_logs
             (userid, courseid, quizid, eventtype, eventdata, suspicious, timecreated)
         VALUES (?, 1, 0, 'device_blocked_tier1', ?, 1, ?)"
    )->execute([
        $userid,
        json_encode(
            ['device_id' => $storageDeviceId, 'reason' => $reason, 'escalates_at' => $now + 30],
            JSON_UNESCAPED_UNICODE
        ),
        $now,
    ]);

    $pdo->commit();

    echo json_encode(['success' => true, 'message' => 'Perangkat diblokir. Akun masih aktif.']);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
