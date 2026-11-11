<?php
/**
 * Endpoint: cek apakah username sedang disuspend (Lightweight Direct PDO — Hemat RAM untuk 800+ siswa).
 * Dipakai oleh halaman login untuk menampilkan notifikasi SweetAlert2 yang lebih jelas.
 *
 * Query param:
 *   - username (string)
 *
 * Response:
 *   { "success": true, "suspended": bool }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');

$username = strtolower(trim((string)($_GET['username'] ?? '')));
if ($username === '' || in_array($username, ['appstore.review', 'playstore.review'], true)) {
    echo json_encode(['success' => true, 'suspended' => false]);
    exit;
}

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) {
        echo json_encode(['success' => true, 'suspended' => false]);
        exit;
    }

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $k) {
        if (preg_match('/\$CFG->' . $k . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$k] = $m[1];
        }
    }
    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    $stmt = $pdo->prepare("SELECT suspended FROM {$prefix}user WHERE username = ? AND deleted = 0 LIMIT 1");
    $stmt->execute([$username]);
    $susp = $stmt->fetchColumn();

    echo json_encode([
        'success'   => true,
        'suspended' => ($susp !== false && (int)$susp === 1),
    ]);
} catch (Throwable $e) {
    echo json_encode(['success' => true, 'suspended' => false]);
}
