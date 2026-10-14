<?php
/**
 * Endpoint: ambil semua siswa yang terdaftar di ujian Moodle (Grade X, XI, XII)
 * beserta status real-time aplikasi CBT (Android & iOS).
 *
 * GET  ?token=XXX  atau  ?apikey=XXX
 * Response: {
 *   users: [
 *     {
 *       userid, firstname, lastname, username, email, idnumber, department,
 *       grade, class_name, cohort_names, lock_status, lastping, is_online,
 *       ipaddress, current_quizid, quiz_name, client_type
 *     }
 *   ]
 * }
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

    // Validasi otorisasi: token admin Moodle atau API Key
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

    // Jalankan stale-check jika diperlukan
    $now = time();
    $staleInc = __DIR__ . '/stale_app_ping_suspend.inc.php';
    if (file_exists($staleInc)) {
        require_once $staleInc;
        if (function_exists('dosman_ujian_suspend_stale_app_ping_users')) {
            dosman_ujian_suspend_stale_app_ping_users($pdo, $prefix, $now);
        }
    }

    // Query data siswa Moodle & status aplikasi CBT
    // Siswa yang sedang online/ujian berada di paling atas, disusul seluruh siswa Moodle.
    $sql = "SELECT u.id AS userid,
                   u.firstname,
                   u.lastname,
                   u.username,
                   u.email,
                   u.idnumber,
                   u.department,
                   IFNULL(a.lastping, 0) AS lastping,
                   IFNULL(a.ipaddress, '') AS ipaddress,
                   IFNULL(a.lock_status, -1) AS lock_status,
                   IFNULL(a.current_quizid, 0) AS current_quizid,
                   IFNULL(q.name, '') AS quiz_name,
                   CASE 
                     WHEN (a.lastping IS NOT NULL AND a.lastping > UNIX_TIMESTAMP() - 300 AND a.lock_status IN (1, 2, 3)) THEN
                       CASE 
                         WHEN a.platform = 'ios' THEN 'ios'
                         WHEN a.platform = 'android' THEN 'android'
                         ELSE 'cbt_app'
                       END
                     ELSE 'none'
                   END AS client_type,
                   GROUP_CONCAT(DISTINCT c.name SEPARATOR ', ') AS cohort_names,
                   CASE
                     WHEN (a.lastping IS NOT NULL AND a.lastping > UNIX_TIMESTAMP() - 300 AND a.lock_status IN (1, 2, 3)) THEN 1
                     ELSE 0
                   END AS is_online
              FROM {$prefix}user u
              LEFT JOIN {$prefix}local_dosman_ujian_appstatus a ON a.userid = u.id
              LEFT JOIN {$prefix}quiz q ON q.id = a.current_quizid AND a.current_quizid > 0
              LEFT JOIN {$prefix}cohort_members cm ON cm.userid = u.id
              LEFT JOIN {$prefix}cohort c ON c.id = cm.cohortid
             WHERE u.deleted = 0 
               AND u.suspended = 0
               AND (a.id IS NOT NULL OR c.name LIKE 'Kelas%' OR u.id = 580 OR u.id IN (2002, 2003, 2004, 2005))
             GROUP BY u.id
             ORDER BY is_online DESC, a.lock_status DESC, a.lastping DESC, u.firstname ASC";

    $rows  = $pdo->query($sql)->fetchAll(PDO::FETCH_OBJ);
    $users = [];
    foreach ($rows as $r) {
        $fname  = trim((string)($r->firstname ?? ''));
        $lname  = trim((string)($r->lastname ?? ''));
        $cnames = trim((string)($r->cohort_names ?? ''));

        // 1. Ekstraksi Nomor Absen & Nama Bersih Siswa
        // Contoh firstname: "08 I Putu Darma Putra" -> no_absen: "08", student_name: "I Putu Darma Putra"
        $noAbsen = '';
        $cleanName = $fname;
        if (preg_match('/^(\d{1,2})\s+(.+)$/', $fname, $m)) {
            $noAbsen = str_pad($m[1], 2, '0', STR_PAD_LEFT);
            $cleanName = trim($m[2]);
        }
        // Bersihkan jika nama masih ada separator pipe (|)
        if (preg_match('/^([^|]+?)\s*\|/i', $cleanName, $m)) {
            $cleanName = trim($m[1]);
        }

        // 2. Ekstraksi Rombel / Kelas & Tahun Penerimaan (Angkatan)
        // Contoh format Moodle: "| XI A | 2024" atau "| X 1 | 2025"
        $full = $fname . ' ' . $lname;
        $className = '';
        $tahunMasuk = '';
        if (preg_match('/\|\s*([^|]+?)\s*\|\s*(\d{4})/i', $full, $m)) {
            $className = trim($m[1]);
            $tahunMasuk = trim($m[2]);
        } else if (preg_match('/\|\s*([^|]+)/i', $full, $m)) {
            $className = trim($m[1]);
        }

        // Fallback nama kelas dari cohort jika belum didapat dari pipe
        if (empty($className)) {
            foreach (explode(',', $cnames) as $cn) {
                $cn = trim($cn);
                if (preg_match('/^(X|XI|XII)\s+[A-Za-z0-9]+/i', $cn)) {
                    $className = $cn;
                    break;
                }
            }
        }
        if (empty($className) && (stripos($cnames, 'Guru') !== false || stripos($lname, 'Guru') !== false)) {
            $className = 'Guru';
        }

        // 3. Ekstraksi Tingkat / Grade Moodle yang akurat
        $grade = '';
        if (preg_match('/\bKelas XII\b/i', $cnames) || preg_match('/\|\s*XII\b/i', $lname) || $tahunMasuk === '2023') {
            $grade = 'Kelas XII';
        } else if (preg_match('/\bKelas XI\b/i', $cnames) || preg_match('/\|\s*XI\b/i', $lname) || $tahunMasuk === '2024') {
            $grade = 'Kelas XI';
        } else if (preg_match('/\bKelas X\b/i', $cnames) || preg_match('/\|\s*X\b/i', $lname) || $tahunMasuk === '2025') {
            $grade = 'Kelas X';
        } else if (stripos($cnames, 'Guru') !== false || stripos($lname, 'Guru') !== false || stripos($lname, 'TIM IT') !== false) {
            $grade = 'Guru / Staf';
        } else {
            $grade = 'Lainnya';
        }

        $users[] = [
            'userid'          => (int)$r->userid,
            'firstname'       => $r->firstname ?? '',
            'lastname'        => $r->lastname ?? '',
            'student_name'    => $cleanName,
            'no_absen'        => $noAbsen,
            'class_name'      => $className,
            'tahun_masuk'     => $tahunMasuk,
            'username'        => $r->username ?? '',
            'email'           => $r->email ?? '',
            'idnumber'        => $r->idnumber ?? '',
            'department'      => $r->department ?? '',
            'grade'           => $grade,
            'cohort_names'    => $cnames,
            'lock_status'     => (int)$r->lock_status,
            'lastping'        => (int)$r->lastping,
            'is_online'       => (int)$r->is_online,
            'ipaddress'       => $r->ipaddress ?? '',
            'current_quizid'  => (int)$r->current_quizid,
            'quiz_name'       => $r->quiz_name ?? '',
            'client_type'     => $r->client_type,
        ];
    }

    echo json_encode(['users' => $users]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Server error: ' . $e->getMessage()]);
}
