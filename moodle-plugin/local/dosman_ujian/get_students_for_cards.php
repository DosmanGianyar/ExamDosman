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

    // Ambil semua akun siswa (baik yang terdaftar di cohort, role student, maupun akun khusus seperti daput1)
    $sql = "SELECT u.id AS userid,
                   u.firstname,
                   u.lastname,
                   u.username,
                   u.email,
                   u.idnumber,
                   u.department,
                   GROUP_CONCAT(DISTINCT c.name SEPARATOR ', ') AS cohort_names,
                   IFNULL(sc.plain_password, '') AS plain_password,
                   IFNULL(sc.no_peserta, '') AS no_peserta,
                   IFNULL(sc.ruang, '') AS ruang,
                   IFNULL(sc.sesi, '') AS sesi,
                   IFNULL(sc.meja, '') AS meja
              FROM {$prefix}user u
              LEFT JOIN {$prefix}cohort_members cm ON cm.userid = u.id
              LEFT JOIN {$prefix}cohort c ON c.id = cm.cohortid
              LEFT JOIN {$prefix}local_dosman_student_cards sc ON sc.username COLLATE utf8mb4_general_ci = u.username COLLATE utf8mb4_general_ci
              LEFT JOIN {$prefix}role_assignments ra ON ra.userid = u.id
              LEFT JOIN {$prefix}role r ON r.id = ra.roleid AND r.shortname = 'student'
             WHERE u.deleted = 0 
               AND u.suspended = 0 
               AND u.id > 1 
               AND u.username NOT IN ('guest', 'admin')
               AND u.id NOT IN (2, 580)
               AND (u.lastname IS NULL OR u.lastname != 'Guru')
               AND u.username NOT LIKE 'smp%'
               AND (c.name IS NULL OR (c.name NOT LIKE '%Guru%' AND c.name NOT LIKE '%Tim IT%'))
               AND (
                   u.lastname LIKE '| %'
                   OR c.name LIKE 'Kelas %'
                   OR c.name LIKE 'XI %'
                   OR c.name LIKE 'XII %'
                   OR u.username LIKE 'daput%'
                   OR sc.id IS NOT NULL
               )
             GROUP BY u.id
             ORDER BY u.lastname ASC, u.firstname ASC";

    $rows = $pdo->query($sql)->fetchAll(PDO::FETCH_OBJ);
    $students = [];

    foreach ($rows as $r) {
        $fname  = trim((string)($r->firstname ?? ''));
        $lname  = trim((string)($r->lastname ?? ''));
        $cnames = trim((string)($r->cohort_names ?? ''));

        // 1. Ekstraksi Nomor Absen & Nama Bersih Siswa
        $noAbsen = '';
        $cleanName = $fname;
        if (preg_match('/^(\d{1,2})\s+(.+)$/', $fname, $m)) {
            $noAbsen = str_pad($m[1], 2, '0', STR_PAD_LEFT);
            $cleanName = trim($m[2]);
        }
        if (preg_match('/^([^|]+?)\s*\|/i', $cleanName, $m)) {
            $cleanName = trim($m[1]);
        }

        // 2. Ekstraksi Rombel / Kelas & Tahun Penerimaan (Angkatan)
        $full = $fname . ' ' . $lname;
        $className = '';
        $tahunMasuk = '';
        if (preg_match('/\|\s*([^|]+?)\s*\|\s*(\d{4})/i', $full, $m)) {
            $className = trim($m[1]);
            $tahunMasuk = trim($m[2]);
        } else if (preg_match('/\|\s*([^|]+)/i', $full, $m)) {
            $className = trim($m[1]);
        }

        if (empty($className)) {
            foreach (explode(',', $cnames) as $cn) {
                $cn = trim($cn);
                if (preg_match('/^(X|XI|XII)\s+[A-Za-z0-9]+/i', $cn)) {
                    $className = $cn;
                    break;
                }
            }
        }

        // 3. Ekstraksi Tingkat / Grade Moodle
        $grade = '';
        if (preg_match('/\bKelas XII\b/i', $cnames) || preg_match('/\|\s*XII\b/i', $lname) || $tahunMasuk === '2023') {
            $grade = 'Kelas XII';
        } else if (preg_match('/\bKelas XI\b/i', $cnames) || preg_match('/\|\s*XI\b/i', $lname) || $tahunMasuk === '2024') {
            $grade = 'Kelas XI';
        } else if (preg_match('/\bKelas X\b/i', $cnames) || preg_match('/\|\s*X\b/i', $lname) || $tahunMasuk === '2025') {
            $grade = 'Kelas X';
        }

        $students[] = [
            'userid'      => (int)$r->userid,
            'firstname'   => $r->firstname ?? '',
            'name'        => $cleanName,
            'student_name'=> $cleanName,
            'no_absen'    => $noAbsen,
            'class_name'  => $className ?: 'X',
            'tahun_masuk' => $tahunMasuk,
            'lastname'    => $r->lastname ?? '',
            'username'    => $r->username ?? '',
            'email'       => $r->email ?? '',
            'idnumber'    => $r->idnumber ?? '',
            'department'  => $r->department ?? '',
            'grade'       => $grade ?: 'Kelas X',
            'cohort_names'=> $cnames,
            'password'    => (string)($r->plain_password ?? ''),
            'no_peserta'  => (string)($r->no_peserta ?? ''),
            'ruang'       => (string)($r->ruang ?? ''),
            'sesi'        => (string)($r->sesi ?? ''),
            'meja'        => (string)($r->meja ?? ''),
        ];
    }

    // Urutkan siswa berdasarkan Tingkat -> Kelas / Rombel -> No Absen -> Nama
    usort($students, function($a, $b) {
        $gradeOrder = ['Kelas X' => 1, 'Kelas XI' => 2, 'Kelas XII' => 3];
        $ga = $gradeOrder[$a['grade']] ?? 99;
        $gb = $gradeOrder[$b['grade']] ?? 99;
        if ($ga !== $gb) {
            return $ga <=> $gb;
        }

        $cmpClass = strnatcasecmp($a['class_name'], $b['class_name']);
        if ($cmpClass !== 0) {
            return $cmpClass;
        }

        $na = (int)($a['no_absen'] ?: 999);
        $nb = (int)($b['no_absen'] ?: 999);
        if ($na !== $nb) {
            return $na <=> $nb;
        }

        return strcasecmp($a['name'], $b['name']);
    });

    echo json_encode([
        'success'  => true,
        'count'    => count($students),
        'students' => $students,
    ]);

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => 'Server error: ' . $e->getMessage()]);
}
