<?php
/**
 * Endpoint: hapus sesi siswa dan paksa login ulang.
 * Menghapus blokir + token Moodle + appstatus siswa.
 *
 * POST body (JSON): { token, userid }
 * Response: { success: bool }
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
    echo json_encode(['error' => 'Method not allowed']);
    exit;
}

$body   = json_decode(file_get_contents('php://input'), true) ?: [];
$token  = trim((string)($body['token']  ?? $_GET['token'] ?? ''));
$userid = (int)($body['userid'] ?? 0);

if ($token === '' || $userid <= 0) {
    http_response_code(400);
    echo json_encode(['error' => 'Parameter tidak lengkap']);
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

    // Validasi token admin
    $stmtTok = $pdo->prepare(
        "SELECT et.userid FROM {$prefix}external_tokens et
          WHERE et.token = ?
            AND (et.validuntil = 0 OR et.validuntil > UNIX_TIMESTAMP())
          LIMIT 1"
    );
    $stmtTok->execute([$token]);
    $adminId = $stmtTok->fetchColumn();
    if ($adminId === false) {
        http_response_code(401);
        echo json_encode(['error' => 'Token tidak valid']);
        exit;
    }

    // 1. Hapus catatan blokir
    $stmt = $pdo->prepare(
        "SELECT value FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian' AND name = 'blocked_students' LIMIT 1"
    );
    $stmt->execute();
    $existing = $stmt->fetchColumn();
    $blocked  = ($existing !== false) ? (json_decode($existing, true) ?: []) : [];
    unset($blocked[(string)$userid]);
    $pdo->prepare(
        "INSERT INTO {$prefix}config_plugins (plugin, name, value)
         VALUES ('local_dosman_ujian', 'blocked_students', ?)
         ON DUPLICATE KEY UPDATE value = VALUES(value)"
    )->execute([json_encode($blocked)]);

    // 2. Hapus semua token Moodle milik siswa untuk service dosman_ujian_mobile
    //    → app tidak bisa lakukan API call → dipaksa login ulang
    $svcStmt = $pdo->prepare(
        "SELECT id FROM {$prefix}external_services WHERE shortname = 'dosman_ujian_mobile' LIMIT 1"
    );
    $svcStmt->execute();
    $serviceId = $svcStmt->fetchColumn();
    if ($serviceId !== false) {
        $pdo->prepare(
            "DELETE FROM {$prefix}external_tokens
              WHERE externalserviceid = ? AND userid = ?"
        )->execute([$serviceId, $userid]);
    }

    // 3. Hapus appstatus → tampil "Tidak Pakai Aplikasi" di dashboard
    $pdo->prepare(
        "DELETE FROM {$prefix}local_dosman_ujian_appstatus WHERE userid = ?"
    )->execute([$userid]);

    // 4. Hapus record sesi → siswa hilang dari tabel Live Siswa
    $pdo->prepare(
        "DELETE FROM {$prefix}local_dosman_ujian_sessions
          WHERE userid = ?"
    )->execute([$userid]);

    // 5. Hapus sesi browser Moodle → siswa logout dari WebView juga
    $pdo->prepare(
        "DELETE FROM {$prefix}sessions WHERE userid = ?"
    )->execute([$userid]);

    @unlink('/dev/shm/dosman_app_users_cache.json');
    echo json_encode(['success' => true]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Server error']);
}
