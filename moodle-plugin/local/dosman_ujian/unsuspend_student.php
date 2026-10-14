<?php
/**
 * Endpoint: aktifkan kembali akun siswa yang telah di-suspend.
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

$body   = json_decode(file_get_contents('php://input'), true) ?: [];
$token  = trim((string)($body['token']  ?? ''));
$userid = (int)($body['userid'] ?? 0);

if ($token === '' || $userid <= 0) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap']);
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

    $pdo->beginTransaction();

    // Aktifkan kembali akun Moodle
    $pdo->prepare(
        "UPDATE {$prefix}user
            SET suspended = 0, timemodified = UNIX_TIMESTAMP()
          WHERE id = ?"
    )->execute([$userid]);

    // Hapus record appstatus agar siswa tidak muncul sebagai 'aktif di aplikasi'
    // sebelum ia benar-benar membuka aplikasi dan login kembali.
    $pdo->prepare(
        "DELETE FROM {$prefix}local_dosman_ujian_appstatus
          WHERE userid = ?"
    )->execute([$userid]);

    // Buka blokir semua device milik siswa ini
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_devices
            SET status       = 'active',
                block_reason = NULL,
                blocked_at   = NULL
          WHERE userid = ? AND status = 'blocked'"
    )->execute([$userid]);

    // Tandai sesi lama sebagai 'released' — bukan 'active' — agar siswa tidak
    // muncul sebagai peserta aktif di monitor. Siswa harus login ulang untuk
    // memulai sesi baru. Riwayat sesi tetap tersimpan untuk audit.
    $pdo->prepare(
        "UPDATE {$prefix}local_dosman_ujian_sessions
            SET status         = 'released',
                blocked_reason = NULL,
                blocked_at     = NULL,
                timemodified   = UNIX_TIMESTAMP()
          WHERE userid = ? AND status IN ('blocked', 'active')"
    )->execute([$userid]);

    $pdo->commit();

    echo json_encode(['success' => true, 'message' => 'Akun berhasil diaktifkan kembali']);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
