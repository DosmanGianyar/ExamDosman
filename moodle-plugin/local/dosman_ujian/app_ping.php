<?php
/**
 * Endpoint: daftarkan/perbarui kehadiran siswa di appstatus saat login atau aktif.
 * Dipanggil Flutter app segera setelah login dan setiap 60 detik selama app terbuka.
 *
 * POST body (JSON): { token }
 * Response: { success: bool, lock_status: int }
 *   lock_status: 1=aktif, 2=diblokir, 3=dijeda
 *
 * Setelah ping valid: menjalankan pembersihan — siswa lock_status=1 dengan lastping
 * terlalu lama (tidak ada app_ping, dianggap keluar aplikasi) di-suspend otomatis.
 * Ambang waktu: lihat DOSMAN_UJIAN_STALE_APP_PING_SEC di stale_app_ping_suspend.inc.php
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
    echo json_encode(['success' => false]);
    exit;
}

$body  = json_decode(file_get_contents('php://input'), true) ?: [];
$token = trim((string)($body['token'] ?? ''));

if ($token === '') {
    http_response_code(400);
    echo json_encode(['success' => false]);
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

    // Resolusi userid dari token siswa
    $stmtTok = $pdo->prepare(
        "SELECT userid FROM {$prefix}external_tokens
          WHERE token = ?
            AND (validuntil = 0 OR validuntil > UNIX_TIMESTAMP())
          LIMIT 1"
    );
    $stmtTok->execute([$token]);
    $userid = (int)($stmtTok->fetchColumn() ?: 0);

    if ($userid <= 0) {
        // Token tidak ditemukan — akun mungkin sudah disuspend dan tokennya dihapus
        http_response_code(401);
        echo json_encode(['success' => false, 'suspended' => true]);
        exit;
    }

    // Cek apakah akun Moodle sudah disuspend
    $stmtSusp = $pdo->prepare("SELECT suspended FROM {$prefix}user WHERE id = ? LIMIT 1");
    $stmtSusp->execute([$userid]);
    $isSuspended = (int)($stmtSusp->fetchColumn() ?: 0);
    if ($isSuspended) {
        echo json_encode(['success' => false, 'suspended' => true]);
        exit;
    }

    $now = time();
    $ip  = $_SERVER['REMOTE_ADDR'] ?? '';

    // Ambil lock_status saat ini (jika ada)
    $stmtCur = $pdo->prepare(
        "SELECT lock_status FROM {$prefix}local_dosman_ujian_appstatus
          WHERE userid = ? LIMIT 1"
    );
    $stmtCur->execute([$userid]);
    $currentStatus = $stmtCur->fetchColumn();

    if ($currentStatus === false) {
        // Belum ada record → insert baru dengan lock_status = 1
        $pdo->prepare(
            "INSERT INTO {$prefix}local_dosman_ujian_appstatus
                (userid, lastping, ipaddress, lock_status, current_quizid)
             VALUES (?, ?, ?, 1, 0)"
        )->execute([$userid, $now, $ip]);
        $finalStatus = 1;
    } else {
        $currentStatus = (int)$currentStatus;
        if (in_array($currentStatus, [2, 3], true)) {
            // Diblokir atau dijeda — hanya update lastping, jangan ubah lock_status
            $pdo->prepare(
                "UPDATE {$prefix}local_dosman_ujian_appstatus
                    SET lastping = ?, ipaddress = ?
                  WHERE userid = ?"
            )->execute([$now, $ip, $userid]);
            $finalStatus = $currentStatus;
        } else {
            // Normal → set lock_status = 1 (aktif), update lastping
            $pdo->prepare(
                "UPDATE {$prefix}local_dosman_ujian_appstatus
                    SET lastping = ?, ipaddress = ?, lock_status = 1
                  WHERE userid = ?"
            )->execute([$now, $ip, $userid]);
            $finalStatus = 1;
        }
    }

    require_once __DIR__ . '/stale_app_ping_suspend.inc.php';
    dosman_ujian_suspend_stale_app_ping_users($pdo, $prefix, $now);

    // Cek pengumuman broadcast aktif dari pengawas
    $activeBroadcast = null;
    $stmtBc = $pdo->prepare(
        "SELECT value FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian' AND name = 'active_broadcast' LIMIT 1"
    );
    $stmtBc->execute();
    $rawBc = $stmtBc->fetchColumn();
    if ($rawBc) {
        $bcArr = json_decode($rawBc, true);
        if (!empty($bcArr) && ($bcArr['expires_at'] ?? 0) > $now) {
            $activeBroadcast = $bcArr;
        }
    }

    echo json_encode([
        'success'     => true,
        'lock_status' => $finalStatus,
        'broadcast'   => $activeBroadcast,
    ]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false]);
}
