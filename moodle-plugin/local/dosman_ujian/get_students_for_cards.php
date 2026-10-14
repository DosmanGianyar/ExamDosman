<?php
/**
 * Endpoint: ambil seluruh siswa (role student / cohort kelas) untuk pencetakan Kartu Peserta Ujian.
 *
 * GET ?token=XXX atau ?apikey=XXX
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');

$token  = trim((string)($_GET['token'] ?? ''));
$apiKey = trim((string)($_GET['apikey'] ?? ''));
$validApiKey = 'dosman-exam-sman1gianyar-2024';

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

    // Otorisasi
    $isAuthorized = false;
    if ($apiKey === $validApiKey) {
        $isAuthorized = true;
    } else if ($token !== '') {
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
        echo json_encode(['error' => 'Token atau API Key tidak valid']);
        exit;
    }

    // Ambil semua akun siswa yang terdaftar di kelas/cohort
    $sql = "SELECT u.id AS userid,
                   u.firstname,
                   u.lastname,
                   u.username,
                   u.email,
                   u.idnumber,
                   u.department,
                   GROUP_CONCAT(DISTINCT c.name SEPARATOR ', ') AS cohort_names
              FROM {$prefix}user u
              JOIN {$prefix}cohort_members cm ON cm.userid = u.id
              JOIN {$prefix}cohort c ON c.id = cm.cohortid
             WHERE u.deleted = 0 
               AND u.suspended = 0 
               AND (c.name LIKE 'Kelas%' OR u.lastname LIKE '| X%' OR u.lastname LIKE '| XI%')
             GROUP BY u.id
             ORDER BY u.lastname ASC, u.firstname ASC";

    $rows = $pdo->query($sql)->fetchAll(PDO::FETCH_OBJ);
    $students = [];

    foreach ($rows as $r) {
        $cnames = (string)($r->cohort_names ?? '');
        $lname  = (string)($r->lastname ?? '');

        // Ekstraksi Tingkat / Grade Moodle
        $grade = '';
        if (strpos($cnames, 'Kelas X ') !== false || preg_match('/\|\s*X\s+\d+/i', $lname)) {
            $grade = 'Kelas X';
        } else if (strpos($cnames, 'Kelas XI ') !== false || preg_match('/\|\s*XI\s+/i', $lname)) {
            $grade = 'Kelas XI';
        } else if (strpos($cnames, 'Kelas XII ') !== false || preg_match('/\|\s*XII\s+/i', $lname)) {
            $grade = 'Kelas XII';
        }

        // Ekstraksi Rombel / Kelas Moodle
        $className = '';
        foreach (explode(',', $cnames) as $cn) {
            $cn = trim($cn);
            if (preg_match('/^XI\s+[A-D]\d?$/i', $cn)) {
                $className = $cn;
                break;
            }
        }
        if ($className === '' && preg_match('/\|\s*([X|XI|XII][^|]+)\s*\|/i', $lname, $m)) {
            $className = trim($m[1]);
        }

        // Parse nomor absen jika ada di awal firstname
        $noAbsen = '';
        $cleanName = $r->firstname ?? '';
        if (preg_match('/^(\d+)\s+(.+)$/', (string)$r->firstname, $m)) {
            $noAbsen = $m[1];
            $cleanName = $m[2];
        }

        $students[] = [
            'userid'      => (int)$r->userid,
            'firstname'   => $r->firstname ?? '',
            'name'        => $cleanName,
            'no_absen'    => $noAbsen,
            'lastname'    => $r->lastname ?? '',
            'username'    => $r->username ?? '',
            'email'       => $r->email ?? '',
            'idnumber'    => $r->idnumber ?? '',
            'department'  => $r->department ?? '',
            'grade'       => $grade ?: 'Kelas X',
            'class_name'  => $className ?: 'X',
            'cohort_names'=> $cnames,
        ];
    }

    echo json_encode([
        'success'  => true,
        'count'    => count($students),
        'students' => $students,
    ]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Server error: ' . $e->getMessage()]);
}
