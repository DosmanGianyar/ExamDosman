<?php
/**
 * Endpoint: ambil daftar semua siswa yang sedang di-suspend.
 *
 * GET  ?token=XXX
 * Response: { students: [ {userid, firstname, lastname, username, email, department, timemodified} ] }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');

$token = trim((string)($_GET['token'] ?? ''));
if ($token === '') {
    http_response_code(400);
    echo json_encode(['error' => 'Token diperlukan']);
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

    // Ambil semua siswa yang di-suspend (kecuali admin/guest, id > 2)
    // Sertakan alasan blokir terbaru dari tabel devices atau sessions
    $sql = "SELECT u.id AS userid, u.firstname, u.lastname, u.username, u.email,
                   u.department, u.timemodified,
                   COALESCE(
                       NULLIF((SELECT d.block_reason FROM {$prefix}local_dosman_ujian_devices d
                                WHERE d.userid = u.id AND d.block_reason IS NOT NULL AND d.block_reason <> ''
                                ORDER BY d.blocked_at DESC, d.id DESC LIMIT 1), ''),
                       NULLIF((SELECT s.blocked_reason FROM {$prefix}local_dosman_ujian_sessions s
                                WHERE s.userid = u.id AND s.blocked_reason IS NOT NULL AND s.blocked_reason <> ''
                                ORDER BY s.blocked_at DESC, s.id DESC LIMIT 1), ''),
                       ''
                   ) AS reason,
                   COALESCE(
                       (SELECT d2.platform FROM {$prefix}local_dosman_ujian_devices d2
                         WHERE d2.userid = u.id
                         ORDER BY d2.last_seen DESC, d2.id DESC LIMIT 1),
                       ''
                   ) AS platform
              FROM {$prefix}user u
             WHERE u.suspended = 1
               AND u.deleted  = 0
               AND u.id > 2
          ORDER BY u.timemodified DESC";

    $rows     = $pdo->query($sql)->fetchAll(PDO::FETCH_OBJ);
    $students = [];
    foreach ($rows as $r) {
        $students[] = [
            'userid'       => (int)$r->userid,
            'firstname'    => $r->firstname,
            'lastname'     => $r->lastname,
            'username'     => $r->username ?? '',
            'email'        => $r->email ?? '',
            'department'   => $r->department ?? '',
            'timemodified' => (int)$r->timemodified,
            'reason'       => $r->reason ?? '',
            'platform'     => $r->platform ?? '',
        ];
    }

    echo json_encode(['students' => $students]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Server error']);
}
