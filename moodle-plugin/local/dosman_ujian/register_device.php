<?php
/**
 * Endpoint: daftarkan atau perbarui device siswa setelah login.
 * Dipanggil Flutter app tepat setelah login berhasil.
 *
 * POST body (JSON): { token, device_id, platform, model }
 *   - token     : Moodle webservice token (wajib)
 *   - device_id : ID unik perangkat, alphanumeric + dash/underscore, maks 128 karakter (wajib)
 *   - platform  : 'android' atau 'ios', default 'android'
 *   - model     : nama model perangkat, dipotong maks 100 karakter
 *
 * Response (device tidak diblokir):
 *   { "success": true, "device_blocked": false }
 * Response (device diblokir):
 *   { "success": true, "device_blocked": true, "block_reason": "<alasan>" }
 * Response error:
 *   { "success": false, "message": "Server error" }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method not allowed']);
    exit;
}

$body     = json_decode(file_get_contents('php://input'), true) ?: [];
$token    = trim((string)($body['token']     ?? ''));
$deviceId = trim((string)($body['device_id'] ?? ''));
$platform = trim((string)($body['platform']  ?? 'android'));
$model    = trim((string)($body['model']     ?? ''));

if ($token === '') {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap']);
    exit;
}

// Validasi format device_id: hanya alphanumeric, dash, underscore; maks 128 karakter
if ($deviceId === '' || !preg_match('/^[A-Za-z0-9_-]{1,128}$/', $deviceId)) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Format device_id tidak valid']);
    exit;
}

// Normalisasi platform
if (!in_array($platform, ['android', 'ios'], true)) {
    $platform = 'android';
}

// Potong model maks 100 karakter
$model = mb_substr($model, 0, 100);

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

    // Validasi token → ambil userid
    $stmtTok = $pdo->prepare(
        "SELECT userid FROM {$prefix}external_tokens
          WHERE token = ?
            AND (validuntil = 0 OR validuntil > UNIX_TIMESTAMP())
          LIMIT 1"
    );
    $stmtTok->execute([$token]);
    $userid = (int)($stmtTok->fetchColumn() ?: 0);

    if ($userid <= 0) {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Token tidak valid']);
        exit;
    }

    $now = time();

    // Cek apakah device_id sudah ada di tabel
    $stmtCheck = $pdo->prepare(
        "SELECT status FROM {$prefix}local_dosman_ujian_devices
          WHERE device_id = ?
          LIMIT 1"
    );
    $stmtCheck->execute([$deviceId]);
    $existingStatus = $stmtCheck->fetchColumn();

    if ($existingStatus === false) {
        // Belum ada → INSERT baru dengan status='active'
        $pdo->prepare(
            "INSERT INTO {$prefix}local_dosman_ujian_devices
                (device_id, userid, platform, model, status, registered_at, last_seen)
             VALUES (?, ?, ?, ?, 'active', ?, ?)"
        )->execute([$deviceId, $userid, $platform, $model, $now, $now]);
    } else {
        // Sudah ada → UPDATE userid, model, last_seen
        // Jangan ubah status jika sedang diblokir
        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_devices
                SET userid    = ?,
                    model     = ?,
                    last_seen = ?
              WHERE device_id = ?"
        )->execute([$userid, $model, $now, $deviceId]);
    }

    // Setelah upsert: pastikan akun reviewer tidak pernah terkena blokir perangkat
    $stmtUser = $pdo->prepare("SELECT username FROM {$prefix}user WHERE id = ? LIMIT 1");
    $stmtUser->execute([$userid]);
    $uname = strtolower(trim((string)$stmtUser->fetchColumn()));
    if (in_array($uname, ['appstore.review', 'playstore.review', 'admin.reviewer'], true)) {
        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_devices
                SET status = 'active', block_reason = NULL, blocked_at = NULL
              WHERE device_id = ?"
        )->execute([$deviceId]);
        echo json_encode(['success' => true, 'device_blocked' => false]);
        exit;
    }

    // Setelah upsert: baca status terkini untuk cek blokir
    $stmtFinal = $pdo->prepare(
        "SELECT status, block_reason, blocked_at
           FROM {$prefix}local_dosman_ujian_devices
          WHERE device_id = ?
          LIMIT 1"
    );
    $stmtFinal->execute([$deviceId]);
    $finalRow = $stmtFinal->fetch(PDO::FETCH_ASSOC);

    if ($finalRow !== false && (string)$finalRow['status'] === 'blocked') {
        echo json_encode([
            'success'        => true,
            'device_blocked' => true,
            'block_reason'   => (string)($finalRow['block_reason'] ?? ''),
            'blocked_at'     => (int)($finalRow['blocked_at'] ?? 0),
        ]);
        exit;
    }

    echo json_encode(['success' => true, 'device_blocked' => false]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
