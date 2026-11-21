<?php
/**
 * Endpoint: verifikasi kode 6 digit dari siswa untuk membuka blokir perangkat.
 * Tidak memerlukan auth token — dipanggil dari DeviceBlockedScreen di app siswa.
 *
 * POST { device_id, code } → { success: bool, message: string }
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
$deviceId = trim((string)($body['device_id'] ?? ''));
$code     = trim((string)($body['code']      ?? ''));

// Validasi device_id (mendukung Android Build.ID dengan titik)
if (!dosman_is_valid_device_id_format($deviceId)) {
    echo json_encode(['success' => false, 'message' => 'Parameter tidak valid']);
    exit;
}

// Legacy shared Android Build.ID tidak boleh melakukan unblock anonim lintas akun
if (!dosman_is_unique_device_id($deviceId) && !dosman_is_user_scoped_device_id($deviceId)) {
    echo json_encode([
        'success' => false,
        'message' => 'Perangkat ini menggunakan ID lama. Minta pengawas membuka blokir langsung dari akun Anda di dashboard.',
    ]);
    exit;
}

// Validasi code
if (!preg_match('/^\d{6}$/', $code)) {
    echo json_encode(['success' => false, 'message' => 'Kode harus 6 digit angka']);
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

    // Get secret
    $stmtSecret = $pdo->prepare("SELECT value FROM {$prefix}config_plugins WHERE plugin = 'local_dosman_ujian' AND name = 'device_unblock_secret' LIMIT 1");
    $stmtSecret->execute();
    $secret = (string)($stmtSecret->fetchColumn() ?: '');
    if ($secret === '') {
        echo json_encode(['success' => false, 'message' => 'Sistem belum dikonfigurasi']);
        exit;
    }

    // Verify token — accept current AND previous period for grace window
    $period = (int)floor(time() / 600);
    $valid = false;
    for ($offset = 0; $offset <= 1; $offset++) {
        $hash = hash_hmac('sha256', (string)($period - $offset), $secret);
        $expected = str_pad((int)hexdec(substr($hash, 0, 8)) % 1000000, 6, '0', STR_PAD_LEFT);
        if (hash_equals($expected, $code)) { $valid = true; break; }
    }
    if (!$valid) {
        echo json_encode(['success' => false, 'message' => 'Kode salah atau sudah kedaluwarsa. Minta kode terbaru dari pengawas.']);
        exit;
    }

    // Cek apakah akun sudah di-suspend (escalation sudah terjadi)
    $stmtUid = $pdo->prepare(
        "SELECT d.userid, u.suspended
           FROM {$prefix}local_dosman_ujian_devices d
           JOIN {$prefix}user u ON u.id = d.userid
          WHERE d.device_id = ?
          LIMIT 1"
    );
    $stmtUid->execute([$deviceId]);
    $uidRow = $stmtUid->fetch(PDO::FETCH_ASSOC);
    $uid = $uidRow !== false ? (int)$uidRow['userid'] : false;
    $isSuspended = $uidRow !== false && (int)$uidRow['suspended'] === 1;

    if ($isSuspended) {
        // Akun sudah di-suspend — tetap unblock device agar pesan menjadi jelas
        $pdo->prepare("UPDATE {$prefix}local_dosman_ujian_devices SET status = 'active', block_reason = NULL, blocked_at = NULL WHERE device_id = ?")->execute([$deviceId]);
        echo json_encode([
            'success' => false,
            'message' => 'Akun Anda telah di-suspend oleh sistem pengawas ujian. Hubungi pengawas ruangan atau tim IT untuk pemulihan akun.',
        ]);
        exit;
    }

    // Valid → unblock device
    $pdo->prepare("UPDATE {$prefix}local_dosman_ujian_devices SET status = 'active', block_reason = NULL, blocked_at = NULL WHERE device_id = ?")->execute([$deviceId]);

    if ($uid !== false) {
        $pdo->prepare("UPDATE {$prefix}local_dosman_ujian_appstatus SET lock_status = 1 WHERE userid = ? AND lock_status = 2")->execute([$uid]);
        $pdo->prepare("UPDATE {$prefix}local_dosman_ujian_sessions SET status = 'active', blocked_reason = NULL, blocked_at = NULL, timemodified = ? WHERE userid = ? AND status = 'blocked'")->execute([time(), $uid]);
    }
    echo json_encode(['success' => true, 'message' => 'Perangkat berhasil dibuka. Silakan login kembali.']);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
