<?php
/**
 * Endpoint: cek apakah siswa diblokir atau disuspend (Lightweight Direct PDO — Hemat RAM untuk 800+ siswa).
 * Dipakai oleh Flutter app untuk mendeteksi status blokir/suspend.
 *
 * GET /local/dosman_ujian/check_blocked.php?userid=123
 * Response: { "blocked": bool, "reason": string }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');

$userid = (int)($_GET['userid'] ?? 0);
if ($userid <= 0) {
    echo json_encode(['blocked' => false, 'reason' => '']);
    exit;
}

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) {
        echo json_encode(['blocked' => false, 'reason' => '']);
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

    // Single lightweight query joining user, appstatus, and devices
    $stmt = $pdo->prepare("
        SELECT u.suspended,
               a.lock_status,
               d.status AS dev_status,
               d.block_reason
          FROM {$prefix}user u
          LEFT JOIN {$prefix}local_dosman_ujian_appstatus a ON a.userid = u.id
          LEFT JOIN {$prefix}local_dosman_ujian_devices d ON d.userid = u.id AND d.status = 'blocked'
         WHERE u.id = ? AND u.deleted = 0
         LIMIT 1
    ");
    $stmt->execute([$userid]);
    $row = $stmt->fetch(PDO::FETCH_OBJ);

    if (!$row) {
        echo json_encode(['blocked' => false, 'reason' => '']);
        exit;
    }

    if ((int)$row->suspended === 1) {
        $reason = !empty($row->block_reason)
            ? $row->block_reason
            : 'Akun Anda ditangguhkan (Suspended) karena pelanggaran kuncian ujian. Harap segera melapor ke pengawas.';
        echo json_encode(['blocked' => true, 'reason' => $reason]);
        exit;
    }

    if ($row->lock_status !== null && (int)$row->lock_status === 2) {
        echo json_encode([
            'blocked' => true,
            'reason'  => 'Akun Anda diblokir oleh pengawas ujian.',
        ]);
        exit;
    }

    if ($row->dev_status === 'blocked') {
        echo json_encode([
            'blocked' => true,
            'reason'  => !empty($row->block_reason) ? $row->block_reason : 'Perangkat Anda diblokir oleh pengawas ujian.',
        ]);
        exit;
    }

    echo json_encode(['blocked' => false, 'reason' => '']);
} catch (Throwable $e) {
    echo json_encode(['blocked' => false, 'reason' => '']);
}
