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

require_once __DIR__ . '/device_id_helper.inc.php';

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

    if ($lockStatus === 2 && dosman_is_protected_user($pdo, $prefix, $userid)) {
        echo json_encode([
            'success' => false,
            'error'   => 'Akun admin, manager, atau reviewer tidak dapat diblokir',
        ]);
        exit;
    }

    // Baca data baca-only sebelum transaksi
    $serviceIds = [];
    if ($lockStatus === 2) {
        $svcStmt = $pdo->prepare(
            "SELECT id FROM {$prefix}external_services
              WHERE shortname IN ('dosman_ujian_mobile', 'moodle_mobile_app')"
        );
        $svcStmt->execute();
        $serviceIds = array_map('intval', $svcStmt->fetchAll(PDO::FETCH_COLUMN) ?: []);
    }

    $pdo->beginTransaction();

    // Upsert lock_status
    $pdo->prepare(
        "INSERT INTO {$prefix}local_dosman_ujian_appstatus
            (userid, lastping, ipaddress, lock_status)
         VALUES (?, ?, '', ?)
         ON DUPLICATE KEY UPDATE lock_status = VALUES(lock_status)"
    )->execute([$userid, $now, $lockStatus]);

    if ($lockStatus === 2) {
        // Auto-suspend akun Moodle saat diblokir (admin/manager/reviewer sudah dicegah di atas)
        $pdo->prepare(
            "UPDATE {$prefix}user SET suspended = 1, timemodified = ? WHERE id = ?"
        )->execute([$now, $userid]);

        // Hapus token webservice mobile agar sesi app langsung tidak valid
        if (!empty($serviceIds)) {
            $placeholders = implode(',', array_fill(0, count($serviceIds), '?'));
            $delParams = array_merge([$userid], $serviceIds);
            $pdo->prepare(
                "DELETE FROM {$prefix}external_tokens
                  WHERE userid = ? AND externalserviceid IN ({$placeholders})"
            )->execute($delParams);
        }

        // Hapus sesi Moodle web → siswa logout dari browser
        $pdo->prepare(
            "DELETE FROM {$prefix}sessions WHERE userid = ?"
        )->execute([$userid]);

    } elseif ($lockStatus === 1) {
        // Pulihkan akun jika tersuspend & buka blokir perangkat serta sesi
        $pdo->prepare(
            "UPDATE {$prefix}user SET suspended = 0, timemodified = ? WHERE id = ?"
        )->execute([$now, $userid]);

        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_devices
                SET status = 'active', block_reason = NULL, blocked_at = NULL
              WHERE userid = ? AND status = 'blocked'"
        )->execute([$userid]);

        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_sessions
                SET status = 'released', blocked_reason = NULL, blocked_at = NULL, timemodified = ?
              WHERE userid = ? AND status = 'blocked'"
        )->execute([$now, $userid]);

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

    $pdo->commit();
    @unlink('/dev/shm/dosman_app_users_cache.json');
    echo json_encode(['success' => true]);

} catch (Throwable $e) {
    if (isset($pdo) && $pdo instanceof PDO && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    http_response_code(500);
    echo json_encode(['error' => 'Server error']);
}
