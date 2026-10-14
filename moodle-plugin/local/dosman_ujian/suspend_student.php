<?php
/**
 * Endpoint: paksa logout siswa DAN suspend akun Moodle mereka.
 * Digunakan untuk siswa yang terbukti curang / melanggar.
 *
 * POST body (JSON): { token, userid }
 * Response: { success: bool, message: string }
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

define('DOSMAN_EXIT_API_KEY', 'dosman-exam-sman1gianyar-2024');

$body   = json_decode(file_get_contents('php://input'), true) ?: [];
$token  = trim((string)($body['token']  ?? ''));
$apikey = trim((string)($body['apikey'] ?? ''));
$userid = (int)($body['userid'] ?? 0);
$reason = trim((string)($body['reason'] ?? 'Siswa memaksa melepas pinned screen (alarm aktif)'));

$isApiKeyValid = ($apikey !== '' && hash_equals(DOSMAN_EXIT_API_KEY, $apikey));

if (($token === '' && !$isApiKeyValid) || $userid <= 0) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap atau tidak valid']);
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

    if (!$isApiKeyValid) {
        // Validasi token admin / guru
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
    }

    // Pastikan target bukan site admin Moodle (dicatat di mdl_config, bukan role_assignments)
    $stmtSiteAdmins = $pdo->prepare(
        "SELECT value FROM {$prefix}config WHERE name = 'siteadmins' LIMIT 1"
    );
    $stmtSiteAdmins->execute();
    $siteAdminList = array_map('trim', explode(',', (string)($stmtSiteAdmins->fetchColumn() ?: '')));
    if (in_array((string)$userid, $siteAdminList, true)) {
        echo json_encode(['success' => false, 'message' => 'Tidak dapat suspend akun site admin']);
        exit;
    }

    // Pastikan target bukan manager
    $roleCheck = $pdo->prepare(
        "SELECT COUNT(*) FROM {$prefix}role_assignments ra
          JOIN {$prefix}role r ON r.id = ra.roleid
         WHERE ra.userid = ? AND r.shortname = 'manager'"
    );
    $roleCheck->execute([$userid]);
    if ((int)$roleCheck->fetchColumn() > 0) {
        echo json_encode(['success' => false, 'message' => 'Tidak dapat suspend akun manager']);
        exit;
    }

    // Ambil service id sebelum transaksi (baca-only, aman di luar)
    $svcStmt = $pdo->prepare(
        "SELECT id FROM {$prefix}external_services
          WHERE shortname = 'dosman_ujian_mobile' LIMIT 1"
    );
    $svcStmt->execute();
    $serviceId = $svcStmt->fetchColumn();

    // Ambil data blocked_students sebelum transaksi (baca-only)
    $stmt = $pdo->prepare(
        "SELECT value FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian' AND name = 'blocked_students' LIMIT 1"
    );
    $stmt->execute();
    $existing = $stmt->fetchColumn();
    $blocked  = ($existing !== false) ? (json_decode($existing, true) ?: []) : [];
    unset($blocked[(string)$userid]);

    $pdo->beginTransaction();

    // 1. Suspend akun Moodle → tidak bisa login sama sekali
    $pdo->prepare(
        "UPDATE {$prefix}user
            SET suspended = 1, timemodified = UNIX_TIMESTAMP()
          WHERE id = ?"
    )->execute([$userid]);

    // 2. Hapus semua token webservice siswa → sesi app langsung tidak valid
    if ($serviceId !== false) {
        $pdo->prepare(
            "DELETE FROM {$prefix}external_tokens
              WHERE externalserviceid = ? AND userid = ?"
        )->execute([$serviceId, $userid]);
    }

    // 3. Hapus sesi Moodle web (browser) milik siswa
    $pdo->prepare(
        "DELETE FROM {$prefix}sessions WHERE userid = ?"
    )->execute([$userid]);

    // 4. Hapus catatan blokir manual
    $pdo->prepare(
        "INSERT INTO {$prefix}config_plugins (plugin, name, value)
         VALUES ('local_dosman_ujian', 'blocked_students', ?)
         ON DUPLICATE KEY UPDATE value = VALUES(value)"
    )->execute([json_encode($blocked)]);

    // 5. Hapus appstatus & browser heartbeat → hilang dari dashboard
    $pdo->prepare(
        "DELETE FROM {$prefix}local_dosman_ujian_appstatus WHERE userid = ?"
    )->execute([$userid]);

    $pdo->prepare(
        "DELETE FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian' AND name = ?"
    )->execute(['browser_hb_' . $userid]);

    // 6. Tandai semua sesi dosman sebagai released
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_sessions
            SET status = 'released', timemodified = UNIX_TIMESTAMP()
          WHERE userid = ? AND status IN ('active','blocked','paused')"
    )->execute([$userid]);

    // 7. Blokir semua device yang terdaftar atas nama siswa ini
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_devices
            SET status = 'blocked',
                block_reason = ?,
                blocked_at = UNIX_TIMESTAMP()
          WHERE userid = ? AND status = 'active'"
    )->execute([$reason, $userid]);

    $pdo->commit();

    echo json_encode(['success' => true, 'message' => 'Akun berhasil di-suspend dan di-logout']);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
