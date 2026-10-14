<?php
/**
 * Endpoint: ubah lock_status akun siswa secara global.
 *
 * POST body (JSON): { token, userid, lock_status }
 *   lock_status: 1 = aktif (buka blokir), 2 = blokir global
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

$body       = json_decode(file_get_contents('php://input'), true) ?: [];
$token      = trim((string)($body['token'] ?? ''));
$userid     = (int)($body['userid'] ?? 0);
$lockStatus = (int)($body['lock_status'] ?? 1);

if ($token === '' || $userid <= 0) {
    http_response_code(400);
    echo json_encode(['error' => 'Parameter tidak lengkap']);
    exit;
}
if (!in_array($lockStatus, [1, 2, 3], true)) {
    http_response_code(400);
    echo json_encode(['error' => 'lock_status harus 1 (aktif), 2 (blokir), atau 3 (jeda)']);
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
    $st = $pdo->prepare(
        "SELECT userid FROM {$prefix}external_tokens
          WHERE token = ? AND (validuntil = 0 OR validuntil > ?) LIMIT 1"
    );
    $st->execute([$token, time()]);
    if ($st->fetchColumn() === false) {
        http_response_code(401);
        echo json_encode(['error' => 'Token tidak valid']);
        exit;
    }

    $now = time();

    // Upsert lock_status
    $pdo->prepare(
        "INSERT INTO {$prefix}local_dosman_ujian_appstatus
            (userid, lastping, ipaddress, lock_status)
         VALUES (?, ?, '', ?)
         ON DUPLICATE KEY UPDATE lock_status = VALUES(lock_status)"
    )->execute([$userid, $now, $lockStatus]);

    if ($lockStatus === 2) {
        // Auto-suspend akun Moodle saat diblokir
        $pdo->prepare(
            "UPDATE {$prefix}user SET suspended = 1, timemodified = ? WHERE id = ?"
        )->execute([$now, $userid]);

        // Hapus sesi Moodle web → siswa logout dari browser
        $pdo->prepare(
            "DELETE FROM {$prefix}sessions WHERE userid = ?"
        )->execute([$userid]);

    } elseif ($lockStatus === 1) {
        // Pulihkan akun jika tersuspend
        $pdo->prepare(
            "UPDATE {$prefix}user SET suspended = 0 WHERE id = ?"
        )->execute([$userid]);

        // Hapus dari blocked_students jika ada
        $stmtBlocked = $pdo->prepare(
            "SELECT value FROM {$prefix}config_plugins
              WHERE plugin = 'local_dosman_ujian' AND name = 'blocked_students' LIMIT 1"
        );
        $stmtBlocked->execute();
        $existing = $stmtBlocked->fetchColumn();
        $blocked  = ($existing !== false) ? (json_decode($existing, true) ?: []) : [];
        if (isset($blocked[(string)$userid])) {
            unset($blocked[(string)$userid]);
            $pdo->prepare(
                "INSERT INTO {$prefix}config_plugins (plugin, name, value)
                 VALUES ('local_dosman_ujian', 'blocked_students', ?)
                 ON DUPLICATE KEY UPDATE value = VALUES(value)"
            )->execute([json_encode($blocked)]);
        }
    }

    echo json_encode(['success' => true]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Server error']);
}
