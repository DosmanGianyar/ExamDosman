<?php
/**
 * Endpoint: buka blokir perangkat dari dashboard guru/admin.
 * Mengubah status device menjadi 'active' dan menghapus alasan blokir.
 *
 * POST body (JSON): { token, device_id }
 *   - token     : Moodle webservice token guru/admin (wajib)
 *   - device_id : ID perangkat yang akan dibuka blokirnya (wajib)
 *
 * Response sukses:
 *   { "success": true, "message": "Perangkat berhasil dibuka blokirnya." }
 * Response error:
 *   { "success": false, "message": "<pesan generik>" }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
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

if ($token === '' || $deviceId === '') {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap']);
    exit;
}

// Validasi format device_id: alphanumeric, titik, dash, underscore; maks 128 karakter (mendukung Android Build.ID)
if (!preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deviceId)) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Format device_id tidak valid']);
    exit;
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

    // Validasi token guru/admin
    $stmtTok = $pdo->prepare(
        "SELECT userid FROM {$prefix}external_tokens
          WHERE token = ?
            AND (validuntil = 0 OR validuntil > UNIX_TIMESTAMP())
          LIMIT 1"
    );
    $stmtTok->execute([$token]);
    $adminId = $stmtTok->fetchColumn();

    if ($adminId === false) {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Token tidak valid']);
        exit;
    }

    $pdo->beginTransaction();

    // Ambil userid dari device sebelum update
    $stmtDev = $pdo->prepare(
        "SELECT userid FROM {$prefix}local_dosman_ujian_devices
          WHERE device_id = ? LIMIT 1"
    );
    $stmtDev->execute([$deviceId]);
    $uid = $stmtDev->fetchColumn();

    // Reset device ke active
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_devices
            SET status       = 'active',
                block_reason = NULL,
                blocked_at   = NULL
          WHERE device_id    = ?"
    )->execute([$deviceId]);

    if ($uid !== false) {
        $uid = (int)$uid;

        // Reset lock_status ke 1 (hanya dari status diblokir=2, bukan dijeda=3)
        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_appstatus
                SET lock_status = 1
              WHERE userid = ? AND lock_status = 2"
        )->execute([$uid]);

        // Unsuspend akun jika terkena suspend otomatis (eskalasi Tier 2)
        $pdo->prepare(
            "UPDATE {$prefix}user
                SET suspended = 0, timemodified = UNIX_TIMESTAMP()
              WHERE id = ? AND suspended = 1"
        )->execute([$uid]);

        // Reset sesi yang diblokir agar siswa bisa lanjut ujian
        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_sessions
                SET status         = 'active',
                    blocked_reason = NULL,
                    blocked_at     = NULL,
                    timemodified   = UNIX_TIMESTAMP()
              WHERE userid = ? AND status = 'blocked'"
        )->execute([$uid]);

        dosman_record_unsuspend_log($pdo, $prefix, $uid, (int)$adminId, 'unblock_device');
    }

    $pdo->commit();
    @unlink('/dev/shm/dosman_app_users_cache.json');

    echo json_encode(['success' => true, 'message' => 'Perangkat berhasil dibuka blokirnya.']);

} catch (Throwable $e) {
    if (isset($pdo) && $pdo instanceof PDO && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
