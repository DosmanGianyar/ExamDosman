<?php
/**
 * Endpoint publik: kembalikan exit password untuk aplikasi Dosman Exam.
 * Bypass bootstrap Moodle sepenuhnya — langsung query DB via PDO.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');

// Validasi API key statis — harus sama dengan AppConfig.exitPwdApiKey di aplikasi.
define('DOSMAN_EXIT_API_KEY', 'dosman-exam-sman1gianyar-2024');

$apikey = trim((string)($_GET['apikey'] ?? $_SERVER['HTTP_X_DOSMAN_APIKEY'] ?? ''));
if (!hash_equals(DOSMAN_EXIT_API_KEY, $apikey)) {
    http_response_code(401);
    echo json_encode(['error' => 'Unauthorized']);
    exit;
}

// Khusus akun reviewer Play Store & App Store: kunci password keluar di 123456 agar reviewer tidak terkunci
$username = strtolower(trim((string)($_GET['username'] ?? '')));
if (in_array($username, ['playstore.review', 'appstore.review'], true)) {
    echo json_encode(['password' => '123456']);
    exit;
}

// Tidak ada fallback hardcoded — jika DB gagal, kembalikan error agar app blokir keluar.
try {
    // Temukan config.php Moodle (2 level di atas: dosman_ujian/ → local/ → moodle root)
    $configfile = __DIR__ . '/../../config.php';

    if (!is_readable($configfile)) {
        throw new RuntimeException('config.php not found');
    }

    $src = file_get_contents($configfile);

    // Ekstrak variabel DB dari config.php dengan regex
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

    $stmt = $pdo->prepare(
        'SELECT value FROM ' . $prefix . 'config_plugins
          WHERE plugin = :plugin AND name = :name
          LIMIT 1'
    );
    $stmt->execute([':plugin' => 'local_dosman_ujian', ':name' => 'admin_exit_password']);
    $row = $stmt->fetchColumn();

    // empty string = tidak perlu password; false = belum pernah diset
    $password = ($row !== false) ? trim((string)$row) : '';
    echo json_encode(['password' => $password]);

} catch (Throwable $e) {
    // Jangan ekspos detail error ke client
    http_response_code(500);
    echo json_encode(['error' => 'Server error']);
}
