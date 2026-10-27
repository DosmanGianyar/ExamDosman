<?php
/**
 * Helper endpoint untuk menginisialisasi / memulihkan akun reviewer (App Store & Play Store):
 * 1. Membuat atau mereset password akun siswa reviewer:
 *    - 'appstore.review' (iOS App Store)
 *    - 'playstore.review' (Android Play Store)
 *    Password: 'DosmanReviewer2026!'
 * 2. Meng-unsuspend akun dan membersihkan status sesi/perangkat lama.
 * 3. Mendaftarkan (enroll) kedua akun siswa tersebut ke kursus kuis aktif agar saat login, kuis langsung muncul di aplikasi.
 * 4. Membuat atau mereset password akun admin/guru:
 *    - 'admin.reviewer'
 *    Password: 'DosmanReviewer2026!'
 *    Role: Site Admin (bisa membuka Web Dashboard di /dashboard/).
 *
 * Query / POST param:
 *   apikey = 'dosman-exam-sman1gianyar-2024'
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

define('NO_MOODLE_COOKIES', true);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');

define('DOSMAN_EXIT_API_KEY', 'dosman-exam-sman1gianyar-2024');

$apikey = trim((string)($_GET['apikey'] ?? $_POST['apikey'] ?? ''));
if ($apikey === '') {
    $rawInput = file_get_contents('php://input');
    $body = json_decode($rawInput, true) ?: [];
    $apikey = trim((string)($body['apikey'] ?? ''));
}

if (!hash_equals(DOSMAN_EXIT_API_KEY, $apikey)) {
    http_response_code(403);
    echo json_encode(['success' => false, 'message' => 'API Key tidak valid']);
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
    if (empty($cfg['dbname'])) throw new RuntimeException('DB config tidak terbaca');

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 5,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    $pdo->beginTransaction();

    $now = time();
    $sharedPasswordPlain = 'DosmanReviewer2026!';
    $sharedPasswordHash  = password_hash($sharedPasswordPlain, PASSWORD_DEFAULT);

    // Ambil mnethostid default
    $stmtMnet = $pdo->prepare("SELECT id FROM {$prefix}mnet_host WHERE wwwroot != '' ORDER BY id ASC LIMIT 1");
    $stmtMnet->execute();
    $mnethostid = $stmtMnet->fetchColumn() ?: 1;

    // Temukan kursus aktif yang bisa digunakan untuk demo (bukan site home id=1)
    $stmtCourse = $pdo->prepare("SELECT id, fullname FROM {$prefix}course WHERE id != 1 AND visible = 1 ORDER BY id ASC LIMIT 1");
    $stmtCourse->execute();
    $demoCourse = $stmtCourse->fetch(PDO::FETCH_ASSOC);
    $demoCourseId = $demoCourse ? (int)$demoCourse['id'] : 0;

    $demoEnrolId = 0;
    if ($demoCourseId > 0) {
        $stmtEnrol = $pdo->prepare("SELECT id FROM {$prefix}enrol WHERE courseid = ? AND enrol = 'manual' AND status = 0 LIMIT 1");
        $stmtEnrol->execute([$demoCourseId]);
        $demoEnrolId = (int)$stmtEnrol->fetchColumn();
    }

    $demoContextId = 0;
    if ($demoCourseId > 0) {
        $stmtCtx = $pdo->prepare("SELECT id FROM {$prefix}context WHERE contextlevel = 50 AND instanceid = ? LIMIT 1");
        $stmtCtx->execute([$demoCourseId]);
        $demoContextId = (int)$stmtCtx->fetchColumn();
    }

    // Role id untuk student (biasanya 5 di Moodle standar)
    $stmtRole = $pdo->prepare("SELECT id FROM {$prefix}role WHERE shortname = 'student' LIMIT 1");
    $stmtRole->execute();
    $studentRoleId = (int)$stmtRole->fetchColumn() ?: 5;

    // ─── 1. INISIALISASI AKUN SISWA REVIEWER (iOS & Android) ────────────────
    $studentConfigs = [
        'appstore.review' => [
            'firstname' => 'App Store',
            'lastname'  => 'Reviewer',
            'email'     => 'appstore.review@sman1-gianyar.sch.id',
            'platform'  => 'iOS (Apple App Store)',
        ],
        'playstore.review' => [
            'firstname' => 'Play Store',
            'lastname'  => 'Reviewer',
            'email'     => 'playstore.review@sman1-gianyar.sch.id',
            'platform'  => 'Android (Google Play Store)',
        ],
    ];

    $studentResults = [];

    foreach ($studentConfigs as $uname => $meta) {
        $stmtCheck = $pdo->prepare("SELECT id, suspended FROM {$prefix}user WHERE username = ? AND deleted = 0 LIMIT 1");
        $stmtCheck->execute([$uname]);
        $existing = $stmtCheck->fetch(PDO::FETCH_ASSOC);

        if ($existing) {
            $userId = (int)$existing['id'];
            $pdo->prepare("UPDATE {$prefix}user SET password = ?, suspended = 0, timemodified = ? WHERE id = ?")
                ->execute([$sharedPasswordHash, $now, $userId]);
            $action = 'unsuspended_and_password_reset';
        } else {
            $pdo->prepare(
                "INSERT INTO {$prefix}user
                    (auth, confirmed, policyagreed, deleted, suspended, mnethostid, username, password,
                     firstname, lastname, email, city, country, lang, timecreated, timemodified)
                 VALUES
                    ('manual', 1, 1, 0, 0, ?, ?, ?,
                     ?, ?, ?, 'Gianyar', 'ID', 'id', ?, ?)"
            )->execute([
                $mnethostid, $uname, $sharedPasswordHash,
                $meta['firstname'], $meta['lastname'], $meta['email'], $now, $now
            ]);
            $userId = (int)$pdo->lastInsertId();
            $action = 'created';
        }

        // Bersihkan status blokir dan session lama
        $pdo->prepare("DELETE FROM {$prefix}local_dosman_ujian_appstatus WHERE userid = ?")->execute([$userId]);
        $pdo->prepare("UPDATE {$prefix}local_dosman_ujian_devices SET status = 'active', block_reason = NULL, blocked_at = NULL WHERE userid = ?")->execute([$userId]);
        $pdo->prepare("UPDATE {$prefix}local_dosman_ujian_sessions SET status = 'released', blocked_reason = NULL, blocked_at = NULL, timemodified = ? WHERE userid = ? AND status IN ('blocked', 'active')")->execute([$now, $userId]);

        // Enroll ke demo course jika ada
        $enrolled = false;
        if ($demoCourseId > 0 && $demoEnrolId > 0) {
            // User enrolment
            $stmtUe = $pdo->prepare("SELECT id FROM {$prefix}user_enrolments WHERE enrolid = ? AND userid = ? LIMIT 1");
            $stmtUe->execute([$demoEnrolId, $userId]);
            if (!$stmtUe->fetchColumn()) {
                $pdo->prepare(
                    "INSERT INTO {$prefix}user_enrolments
                        (status, enrolid, userid, timestart, timeend, modifierid, timecreated, timemodified)
                     VALUES
                        (0, ?, ?, ?, 0, 2, ?, ?)"
                )->execute([$demoEnrolId, $userId, $now, $now, $now]);
            }

            // Role assignment
            if ($demoContextId > 0) {
                $stmtRa = $pdo->prepare("SELECT id FROM {$prefix}role_assignments WHERE roleid = ? AND contextid = ? AND userid = ? LIMIT 1");
                $stmtRa->execute([$studentRoleId, $demoContextId, $userId]);
                if (!$stmtRa->fetchColumn()) {
                    $pdo->prepare(
                        "INSERT INTO {$prefix}role_assignments
                            (roleid, contextid, userid, timemodified, modifierid)
                         VALUES
                            (?, ?, ?, ?, 2)"
                    )->execute([$studentRoleId, $demoContextId, $userId, $now]);
                }
            }
            $enrolled = true;
        }

        $studentResults[] = [
            'username'     => $uname,
            'password'     => $sharedPasswordPlain,
            'platform'     => $meta['platform'],
            'action'       => $action,
            'status'       => 'active (not suspended)',
            'demo_course'  => $enrolled ? ($demoCourse['fullname'] ?? "Course ID #$demoCourseId") : 'no_course_found',
            'kiosk_exit_password' => '123456'
        ];
    }

    // ─── 2. INISIALISASI AKUN ADMIN REVIEWER (Web Dashboard) ────────────────
    $adminUsername = 'admin.reviewer';
    $stmtAdmin = $pdo->prepare("SELECT id FROM {$prefix}user WHERE username = ? AND deleted = 0 LIMIT 1");
    $stmtAdmin->execute([$adminUsername]);
    $adminId = $stmtAdmin->fetchColumn();

    if ($adminId !== false) {
        $pdo->prepare("UPDATE {$prefix}user SET password = ?, suspended = 0, timemodified = ? WHERE id = ?")
            ->execute([$sharedPasswordHash, $now, $adminId]);
        $adminAction = 'updated_password';
    } else {
        $pdo->prepare(
            "INSERT INTO {$prefix}user
                (auth, confirmed, policyagreed, deleted, suspended, mnethostid, username, password,
                 firstname, lastname, email, city, country, lang, timecreated, timemodified)
             VALUES
                ('manual', 1, 1, 0, 0, ?, ?, ?,
                 'Reviewer', 'Admin', 'admin.reviewer@sman1-gianyar.sch.id', 'Gianyar', 'ID', 'id', ?, ?)"
        )->execute([$mnethostid, $adminUsername, $sharedPasswordHash, $now, $now]);
        $adminId = (int)$pdo->lastInsertId();
        $adminAction = 'created';
    }

    // Daftarkan ke siteadmins di mdl_config
    $stmtCfg = $pdo->prepare("SELECT value FROM {$prefix}config WHERE name = 'siteadmins' LIMIT 1");
    $stmtCfg->execute();
    $rawAdmins = (string)($stmtCfg->fetchColumn() ?: '');
    $siteAdminIds = array_filter(array_map('trim', explode(',', $rawAdmins)));
    if (!in_array((string)$adminId, $siteAdminIds, true)) {
        $siteAdminIds[] = (string)$adminId;
        $newAdmins = implode(',', $siteAdminIds);
        $pdo->prepare("UPDATE {$prefix}config SET value = ? WHERE name = 'siteadmins'")
            ->execute([$newAdmins]);
    }

    $pdo->commit();

    echo json_encode([
        'success' => true,
        'message' => 'Semua akun reviewer berhasil diinisialisasi & dipulihkan',
        'student_accounts' => $studentResults,
        'dashboard_account' => [
            'username'      => $adminUsername,
            'password'      => $sharedPasswordPlain,
            'action'        => $adminAction,
            'dashboard_url' => 'https://lms.sman1-gianyar.sch.id:9443/dashboard/',
            'role'          => 'Site Administrator'
        ]
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);

} catch (Throwable $e) {
    if (isset($pdo) && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    http_response_code(500);
    echo json_encode([
        'success' => false,
        'message' => 'Error: ' . $e->getMessage()
    ]);
}
