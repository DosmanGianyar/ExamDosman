<?php
/**
 * Endpoint: ambil daftar siswa yang perangkatnya diblokir tapi akun belum di-suspend.
 *
 * GET ?token=... → { students: [...] }
 * Returns students where device status='blocked' AND user.suspended=0
 *
 * @package    local_dosman_ujian
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, X-Dosman-Token');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }
if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    http_response_code(405);
    echo json_encode(['students' => [], 'error' => 'Method not allowed']);
    exit;
}

$token = trim((string)($_GET['token'] ?? $_SERVER['HTTP_X_DOSMAN_TOKEN'] ?? ''));
if ($token === '') {
    http_response_code(400);
    echo json_encode(['students' => [], 'error' => 'Token diperlukan']);
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

    // Validasi token
    $stmtTok = $pdo->prepare(
        "SELECT userid FROM {$prefix}external_tokens
          WHERE token = ?
            AND (validuntil = 0 OR validuntil > UNIX_TIMESTAMP())
          LIMIT 1"
    );
    $stmtTok->execute([$token]);
    if ($stmtTok->fetchColumn() === false) {
        http_response_code(401);
        echo json_encode(['students' => [], 'error' => 'Token tidak valid']);
        exit;
    }

    $now = time();

    $sql = "SELECT d.device_id, d.userid, d.platform, d.block_reason, d.blocked_at, d.model,
                   IFNULL(d.app_version, '') AS app_version,
                   IFNULL(d.app_build, 0) AS app_build,
                   u.firstname, u.lastname, u.username, u.department
              FROM {$prefix}local_dosman_ujian_devices d
              JOIN {$prefix}user u ON u.id = d.userid AND u.deleted = 0 AND u.suspended = 0
             WHERE d.status = 'blocked'
             ORDER BY d.blocked_at DESC";

    $rows = $pdo->query($sql)->fetchAll(PDO::FETCH_ASSOC);

    $students = [];
    foreach ($rows as $row) {
        $blockedAt = (int)$row['blocked_at'];
        $row['blocked_at']             = $blockedAt;
        $row['userid']                 = (int)$row['userid'];
        $row['app_build']              = (int)($row['app_build'] ?? 0);
        $row['seconds_since_blocked']  = $now - $blockedAt;
        $row['seconds_until_escalation'] = max(0, 300 - ($now - $blockedAt));
        $students[] = $row;
    }

    echo json_encode(['students' => $students]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['students' => [], 'error' => 'Server error']);
}
