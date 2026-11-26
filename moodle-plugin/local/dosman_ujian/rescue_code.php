<?php
/**
 * Endpoint khusus proktor/guru/admin untuk membaca atau mengubah Kode Kirim Darurat Proktor.
 * Ditolak keras (HTTP 403) bila dipanggil memakai token siswa.
 *
 * POST body (JSON):
 *   { "token": "<wstoken_guru_atau_admin>", "action": "get" | "set", "code": "..." }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method not allowed']);
    exit;
}

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) {
        throw new RuntimeException('config.php tidak dapat dibaca');
    }

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $key) {
        if (preg_match('/\$CFG->' . $key . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$key] = $m[1];
        }
    }
    if (empty($cfg['dbname'])) {
        throw new RuntimeException('DB config tidak terbaca');
    }

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $pdo    = new PDO(
        'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4',
        $cfg['dbuser'],
        $cfg['dbpass'],
        [
            PDO::ATTR_TIMEOUT  => 3,
            PDO::ATTR_ERRMODE  => PDO::ERRMODE_EXCEPTION,
        ]
    );

    $body   = json_decode(file_get_contents('php://input'), true) ?: [];
    $token  = trim((string)($body['token'] ?? ''));
    $action = strtolower(trim((string)($body['action'] ?? 'get')));
    $code   = trim((string)($body['code'] ?? ''));

    if ($token === '') {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Token tidak boleh kosong.']);
        exit;
    }

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
        echo json_encode(['success' => false, 'message' => 'Token tidak valid atau kedaluwarsa.']);
        exit;
    }

    // Pastikan pemilik token adalah site admin atau guru/manager/proktor.
    $isAuthorized = false;
    $stmtAdmin = $pdo->prepare("SELECT value FROM {$prefix}config WHERE name = 'siteadmins' LIMIT 1");
    $stmtAdmin->execute();
    $siteadmins = (string)($stmtAdmin->fetchColumn() ?: '');
    $adminIds   = array_filter(array_map('trim', explode(',', $siteadmins)));
    if (in_array((string)$userid, $adminIds, true)) {
        $isAuthorized = true;
    }

    if (!$isAuthorized) {
        $stmtRole = $pdo->prepare(
            "SELECT COUNT(*) FROM {$prefix}role_assignments ra
               JOIN {$prefix}role r      ON r.id = ra.roleid
               JOIN {$prefix}context ctx ON ctx.id = ra.contextid
              WHERE ra.userid = ?
                AND r.archetype IN ('manager','coursecreator','editingteacher','teacher')
                AND ctx.contextlevel IN (10, 40, 50)"
        );
        $stmtRole->execute([$userid]);
        if ((int)$stmtRole->fetchColumn() > 0) {
            $isAuthorized = true;
        }
    }

    if (!$isAuthorized) {
        http_response_code(403);
        echo json_encode(['success' => false, 'message' => 'Hanya guru, proktor, atau admin yang dapat mengakses Kode Kirim Darurat.']);
        exit;
    }

    if ($action === 'set') {
        if (strlen($code) < 4) {
            http_response_code(400);
            echo json_encode(['success' => false, 'message' => 'Kode Kirim Darurat minimal 4 karakter dan tidak boleh kosong.']);
            exit;
        }
        if (strlen($code) > 32) {
            http_response_code(400);
            echo json_encode(['success' => false, 'message' => 'Kode Kirim Darurat maksimal 32 karakter.']);
            exit;
        }

        $pdo->prepare(
            "INSERT INTO {$prefix}config_plugins (plugin, name, value)
             VALUES ('local_dosman_ujian', 'admin_rescue_password', ?)
             ON DUPLICATE KEY UPDATE value = VALUES(value)"
        )->execute([$code]);

        echo json_encode([
            'success' => true,
            'code'    => $code,
            'message' => 'Kode Kirim Darurat Proktor berhasil diperbarui.',
        ]);
        exit;
    }

    // Default: get (auto-generate 6-digit kode jika belum diset)
    $stmtGet = $pdo->prepare(
        "SELECT value FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian' AND name = 'admin_rescue_password'
          LIMIT 1"
    );
    $stmtGet->execute();
    $existing      = $stmtGet->fetchColumn();
    $currentCode   = $existing !== false ? trim((string)$existing) : '';
    $autoGenerated = false;

    if ($currentCode === '') {
        $currentCode   = (string)random_int(100000, 999999);
        $autoGenerated = true;
        $pdo->prepare(
            "INSERT INTO {$prefix}config_plugins (plugin, name, value)
             VALUES ('local_dosman_ujian', 'admin_rescue_password', ?)
             ON DUPLICATE KEY UPDATE value = VALUES(value)"
        )->execute([$currentCode]);
    }

    echo json_encode([
        'success'        => true,
        'code'           => $currentCode,
        'auto_generated' => $autoGenerated,
    ]);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Terjadi kesalahan server.']);
}
