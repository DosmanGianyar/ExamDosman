<?php
/**
 * Endpoint publik: cek apakah device_id diblokir.
 * Tidak memerlukan token — dipanggil sebelum proses login.
 *
 * Method: GET atau POST
 * Param:  device_id (string, alphanumeric + titik/dash/underscore, maks 128 karakter)
 *
 * Response:
 *   { "blocked": false, "reason": "" }          → device tidak diblokir / tidak ditemukan
 *   { "blocked": true,  "reason": "<alasan>" }  → device diblokir
 *
 * Prinsip fail-open: jika terjadi error DB atau error apapun, kembalikan
 * blocked=false agar siswa tidak terhalang karena masalah server.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

require_once __DIR__ . '/device_id_helper.inc.php';

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }

// Terima device_id dari GET atau POST (JSON body)
$deviceId = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $body     = json_decode(file_get_contents('php://input'), true) ?: [];
    $deviceId = trim((string)($body['device_id'] ?? $_POST['device_id'] ?? ''));
} else {
    $deviceId = trim((string)($_GET['device_id'] ?? ''));
}

// Validasi format device_id: alphanumeric, titik, dash, underscore; maks 128 karakter (mendukung Android Build.ID)
if (!dosman_is_valid_device_id_format($deviceId)) {
    // Format tidak valid → treat sebagai tidak ditemukan (fail-open)
    echo json_encode(['blocked' => false, 'reason' => '', 'blocked_at' => 0]);
    exit;
}

// Device ID tidak unik (shared Android Build.ID sebelum login): jangan pernah blokir lintas siswa
if (!dosman_is_unique_device_id($deviceId) && !dosman_is_user_scoped_device_id($deviceId)) {
    echo json_encode(['blocked' => false, 'reason' => '', 'blocked_at' => 0]);
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

    $stmt = $pdo->prepare(
        "SELECT status, block_reason, blocked_at
           FROM {$prefix}local_dosman_ujian_devices
          WHERE device_id = ?
          LIMIT 1"
    );
    $stmt->execute([$deviceId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if ($row === false) {
        // Device tidak ditemukan di tabel → tidak diblokir
        echo json_encode(['blocked' => false, 'reason' => '', 'blocked_at' => 0]);
        exit;
    }

    if ((string)$row['status'] === 'blocked') {
        echo json_encode([
            'blocked'    => true,
            'reason'     => (string)($row['block_reason'] ?? ''),
            'blocked_at' => (int)($row['blocked_at'] ?? 0),
        ]);
        exit;
    }

    echo json_encode(['blocked' => false, 'reason' => '', 'blocked_at' => 0]);

} catch (Throwable $e) {
    // Fail-open: jangan blokir siswa karena error server
    echo json_encode(['blocked' => false, 'reason' => '']);
}
