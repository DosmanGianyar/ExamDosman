<?php
/**
 * Endpoint khusus guru/proktor/admin untuk membaca atau mengatur Mode Akses Jaringan Ujian:
 *   - 'local_only' : Paksa akses siswa hanya dari jaringan lokal sekolah (Wi-Fi EXAM DOSMAN / LAN)
 *   - 'both'       : Izinkan akses dari lokal Wi-Fi sekolah maupun Internet / Kuota (Online)
 *
 * Ditolak keras (HTTP 403) bila dipanggil memakai token siswa.
 *
 * POST body (JSON):
 *   { "token": "<wstoken_guru_atau_admin>", "action": "get" | "set", "mode": "local_only" | "both", "allowed_cidrs": "..." }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

require_once __DIR__ . '/device_id_helper.inc.php';

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

    $body         = json_decode(file_get_contents('php://input'), true) ?: [];
    $token        = trim((string)($body['token'] ?? ''));
    $action       = strtolower(trim((string)($body['action'] ?? 'get')));
    $mode         = strtolower(trim((string)($body['mode'] ?? '')));
    $allowedCidrs = trim((string)($body['allowed_cidrs'] ?? ''));

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
    if (!dosman_is_teacher_or_admin_pdo($pdo, $prefix, (int)$userid)) {
        http_response_code(403);
        echo json_encode(['success' => false, 'message' => 'Hanya guru, proktor, atau admin yang dapat mengubah Mode Akses Jaringan Ujian.']);
        exit;
    }

    if ($action === 'set') {
        if ($mode !== 'local_only' && $mode !== 'both') {
            http_response_code(400);
            echo json_encode(['success' => false, 'message' => 'Mode harus bernilai local_only atau both.']);
            exit;
        }

        $pdo->prepare(
            "INSERT INTO {$prefix}config_plugins (plugin, name, value)
             VALUES ('local_dosman_ujian', 'network_access_mode', ?)
             ON DUPLICATE KEY UPDATE value = VALUES(value)"
        )->execute([$mode]);

        if ($allowedCidrs !== '') {
            $pdo->prepare(
                "INSERT INTO {$prefix}config_plugins (plugin, name, value)
                 VALUES ('local_dosman_ujian', 'allowed_local_cidrs', ?)
                 ON DUPLICATE KEY UPDATE value = VALUES(value)"
            )->execute([$allowedCidrs]);
        }

        @unlink('/dev/shm/dosman_app_users_cache.json');
        $policy = dosman_get_network_access_policy($pdo, $prefix);

        echo json_encode([
            'success'       => true,
            'mode'          => $policy['mode'],
            'allowed_cidrs' => $policy['allowed_cidrs'],
            'message'       => $policy['mode'] === 'local_only'
                ? 'Mode dikunci ke Lokal / Offline Saja (hanya Wi-Fi sekolah EXAM DOSMAN).'
                : 'Mode dibuka untuk Lokal Wi-Fi & Online Internet.',
        ]);
        exit;
    }

    $policy = dosman_get_network_access_policy($pdo, $prefix);
    echo json_encode([
        'success'       => true,
        'mode'          => $policy['mode'],
        'allowed_cidrs' => $policy['allowed_cidrs'],
        'client_ip'     => $_SERVER['REMOTE_ADDR'] ?? '',
    ]);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Terjadi kesalahan server.']);
}
