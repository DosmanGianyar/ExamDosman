<?php
/**
 * Endpoint Pengaturan Kartu Peserta Ujian (Server Persistence)
 *
 * GET: Mengambil pengaturan kartu ujian dari server
 * POST: Menyimpan pengaturan kartu ujian ke server secara permanen
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'OPTIONS') {
    http_response_code(200);
    exit;
}

$validApiKey = 'dosman-exam-sman1gianyar-2024';

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) {
        throw new RuntimeException('config.php not found');
    }

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $key) {
        if (preg_match('/\$CFG->' . $key . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$key] = $m[1];
        }
    }
    if (empty($cfg['dbname'])) {
        throw new RuntimeException('DB config not parseable');
    }

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    // Pastikan tabel isolasi pengaturan kartu ada (tanpa menyentuh tabel inti Moodle)
    $tableName = "{$prefix}local_dosman_card_settings";
    $pdo->exec("
        CREATE TABLE IF NOT EXISTS {$tableName} (
            id BIGINT AUTO_INCREMENT PRIMARY KEY,
            setting_key VARCHAR(100) NOT NULL UNIQUE,
            setting_value TEXT NOT NULL,
            updated_at INT NOT NULL,
            INDEX idx_key (setting_key)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ");

    // ─── METHOD GET: Ambil Semua Pengaturan ───
    if ($method === 'GET') {
        $stmt = $pdo->query("SELECT setting_key, setting_value FROM {$tableName}");
        $settings = [];
        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            $settings[$row['setting_key']] = $row['setting_value'];
        }

        echo json_encode([
            'success'  => true,
            'settings' => $settings,
        ]);
        exit;
    }

    // ─── METHOD POST: Simpan Pengaturan Baru ke Server ───
    if ($method === 'POST') {
        $raw = file_get_contents('php://input');
        $payload = json_decode($raw, true) ?: $_POST;

        $apiKey = trim((string)($payload['apikey'] ?? ''));
        $token  = trim((string)($payload['token'] ?? ''));

        $isAuthorized = false;
        if ($apiKey === $validApiKey) {
            $isAuthorized = true;
        } else if (!empty($token)) {
            $st = $pdo->prepare(
                "SELECT userid FROM {$prefix}external_tokens
                  WHERE token = ? AND (validuntil = 0 OR validuntil > ?) LIMIT 1"
            );
            $st->execute([$token, time()]);
            if ($st->fetchColumn() !== false) {
                $isAuthorized = true;
            }
        }

        if (!$isAuthorized) {
            http_response_code(401);
            echo json_encode(['error' => 'API Key atau Token tidak valid']);
            exit;
        }

        $items = $payload['settings'] ?? [];
        if (!is_array($items) || empty($items)) {
            echo json_encode(['success' => true, 'message' => 'Tidak ada pengaturan yang diubah']);
            exit;
        }

        $now = time();
        $upsertSql = "
            INSERT INTO {$tableName} (setting_key, setting_value, updated_at)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE
                setting_value = VALUES(setting_value),
                updated_at    = VALUES(updated_at)
        ";

        $stmt = $pdo->prepare($upsertSql);
        $pdo->beginTransaction();

        $savedKeys = [];
        foreach ($items as $k => $v) {
            $k = trim((string)$k);
            $v = trim((string)$v);
            if ($k === '') continue;

            $stmt->execute([$k, $v, $now]);
            $savedKeys[] = $k;
        }

        $pdo->commit();

        echo json_encode([
            'success'    => true,
            'saved_keys' => $savedKeys,
            'message'    => 'Pengaturan kartu berhasil disimpan permanen ke server database.',
        ]);
        exit;
    }

    http_response_code(405);
    echo json_encode(['error' => 'Method not allowed']);

} catch (Throwable $e) {
    if (isset($pdo) && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    http_response_code(500);
    echo json_encode(['error' => 'Server error: ' . $e->getMessage()]);
}
