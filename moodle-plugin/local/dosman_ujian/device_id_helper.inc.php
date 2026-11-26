<?php
/**
 * Helper normalisasi dan validasi device_id agar Android Build.ID yang bersifat global/shared
 * tidak memblokir siswa lain yang memakai tipe/firmware HP yang sama.
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

/**
 * Validasi format dasar device_id yang diterima dari aplikasi.
 */
function dosman_is_valid_device_id_format(string $deviceId): bool {
    return $deviceId !== '' && preg_match('/^[A-Za-z0-9._-]{1,128}$/', $deviceId) === 1;
}

/**
 * Cek apakah device_id benar-benar unik per perangkat fisik:
 * - Standard UUID (iOS identifierForVendor atau fallback UUID)
 * - True Android ID (16 hex lowercase atau diawali "aid_")
 */
function dosman_is_unique_device_id(string $deviceId): bool {
    if (preg_match('/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/', $deviceId) === 1) {
        return true;
    }
    if (preg_match('/^(?:aid_)?[0-9a-f]{16}$/', $deviceId) === 1) {
        return true;
    }
    return false;
}

/**
 * Cek apakah device_id sudah memakai format terikat user (u{userid}__{id}).
 */
function dosman_is_user_scoped_device_id(string $deviceId): bool {
    return preg_match('/^u\d+__[A-Za-z0-9._-]+$/', $deviceId) === 1;
}

/**
 * Normalisasi device_id untuk disimpan di tabel devices:
 * Jika device_id tidak unik (misal Android Build.ID), ikatkan dengan userid.
 */
function dosman_normalize_storage_device_id(string $deviceId, int $userid): string {
    if (dosman_is_unique_device_id($deviceId) || dosman_is_user_scoped_device_id($deviceId)) {
        return $deviceId;
    }
    return substr('u' . $userid . '__' . $deviceId, 0, 128);
}

/**
 * Daftar resmi akun reviewer App Store / Play Store yang dikecualikan dari sanksi anti-cheat.
 */
function dosman_is_reviewer_username(string $username): bool {
    return in_array(
        strtolower(trim($username)),
        ['appstore.review', 'playstore.review', 'admin.reviewer', 'apple.review'],
        true
    );
}

/**
 * Cek apakah akun termasuk user yang kebal dari sanksi anti-cheat:
 * site admin Moodle, role manager, atau akun reviewer resmi App Store / Play Store.
 */
function dosman_is_protected_user(PDO $pdo, string $prefix, int $userid): bool {
    if ($userid <= 0) {
        return false;
    }

    $stmtAdmins = $pdo->prepare(
        "SELECT value FROM {$prefix}config WHERE name = 'siteadmins' LIMIT 1"
    );
    $stmtAdmins->execute();
    $siteAdminList = array_filter(array_map('trim', explode(',', (string)($stmtAdmins->fetchColumn() ?: ''))));
    if (in_array((string)$userid, $siteAdminList, true)) {
        return true;
    }

    $stmtRole = $pdo->prepare(
        "SELECT COUNT(*) FROM {$prefix}role_assignments ra
          JOIN {$prefix}role r ON r.id = ra.roleid
         WHERE ra.userid = ? AND r.shortname = 'manager'"
    );
    $stmtRole->execute([$userid]);
    if ((int)$stmtRole->fetchColumn() > 0) {
        return true;
    }

    $stmtUser = $pdo->prepare("SELECT username FROM {$prefix}user WHERE id = ? LIMIT 1");
    $stmtUser->execute([$userid]);
    $username = (string)($stmtUser->fetchColumn() ?: '');
    return $username !== '' && dosman_is_reviewer_username($username);
}

/**
 * Cek apakah alasan pelanggaran termasuk aturan legacy yang sudah dinonaktifkan
 * karena terbukti memicu false-positive massal pada APK versi lama
 * (overlay toast/aksesibilitas OEM dan screen_cast virtual display bawaan HP).
 */
function dosman_is_legacy_ignored_violation_reason(string $reason): bool {
    $r = strtolower(trim($reason));
    if ($r === '') {
        return false;
    }
    return str_contains($r, 'overlay')
        || str_contains($r, 'screen_cast')
        || str_contains($r, 'screen cast')
        || str_contains($r, 'mirroring');
}

/**
 * Validasi murni apakah sebuah attempt Moodle masih berada dalam jendela waktu aktif.
 * - Lewat timeclose + grace (default 300 dtk) => kedaluwarsa.
 * - Lewat timestart + timelimit + grace => kedaluwarsa.
 * - Kuis latihan/simulasi tanpa batas waktu (timeclose=0 & timelimit=0) yang dimulai
 *   lebih dari 3 jam lalu (10800 dtk) dianggap terbengkalai, bukan ujian aktif.
 */
function dosman_is_attempt_currently_active(
    int $timestart,
    int $effectiveClose,
    int $effectiveLimit,
    int $now,
    int $graceSec = 300,
    int $maxUnboundedAgeSec = 10800
): bool {
    if ($timestart <= 0) {
        return false;
    }
    if ($effectiveClose > 0 && $effectiveClose < ($now - $graceSec)) {
        return false;
    }
    if ($effectiveLimit > 0 && ($timestart + $effectiveLimit) < ($now - $graceSec)) {
        return false;
    }
    if ($effectiveClose === 0 && $effectiveLimit === 0 && $timestart < ($now - $maxUnboundedAgeSec)) {
        return false;
    }
    return true;
}

/**
 * Satu-satunya sumber kebenaran apakah siswa sedang aktif mengerjakan ujian:
 * wajib memiliki attempt Moodle non-preview dengan state = 'inprogress' yang
 * masih berada dalam jendela waktu efektif (termasuk quiz_overrides user/grup).
 * Mengembalikan ['quizid' => int, 'timestart' => int] atau null jika tidak ada.
 */
function dosman_get_active_quiz_attempt(PDO $pdo, string $prefix, int $userid, ?int $now = null): ?array {
    if ($userid <= 0) {
        return null;
    }
    $now = $now ?? time();

    $stmt = $pdo->prepare(
        "SELECT qa.quiz, qa.timestart, q.timeclose, q.timelimit
           FROM {$prefix}quiz_attempts qa
           JOIN {$prefix}quiz q ON q.id = qa.quiz
          WHERE qa.userid = ? AND qa.state = 'inprogress' AND qa.preview = 0
          ORDER BY qa.timestart DESC"
    );
    $stmt->execute([$userid]);
    $attempts = $stmt->fetchAll(PDO::FETCH_ASSOC);
    if (empty($attempts)) {
        return null;
    }

    $stmtOv = $pdo->prepare(
        "SELECT userid, groupid, timeclose, timelimit
           FROM {$prefix}quiz_overrides
          WHERE quiz = ?
            AND (userid = ? OR groupid IN (
                SELECT groupid FROM {$prefix}groups_members WHERE userid = ?
            ))"
    );

    foreach ($attempts as $row) {
        $quizId    = (int)$row['quiz'];
        $timestart = (int)$row['timestart'];
        $effClose  = (int)$row['timeclose'];
        $effLimit  = (int)$row['timelimit'];

        $stmtOv->execute([$quizId, $userid, $userid]);
        $overrides = $stmtOv->fetchAll(PDO::FETCH_ASSOC);

        if (!empty($overrides)) {
            $groupCloses = [];
            $groupLimits = [];
            $userOv      = null;

            foreach ($overrides as $ov) {
                if ($ov['userid'] !== null && (int)$ov['userid'] === $userid) {
                    $userOv = $ov;
                } elseif ($ov['groupid'] !== null) {
                    if ($ov['timeclose'] !== null) {
                        $groupCloses[] = (int)$ov['timeclose'];
                    }
                    if ($ov['timelimit'] !== null) {
                        $groupLimits[] = (int)$ov['timelimit'];
                    }
                }
            }

            if (!empty($groupCloses)) {
                $effClose = in_array(0, $groupCloses, true) ? 0 : max($groupCloses);
            }
            if (!empty($groupLimits)) {
                $effLimit = in_array(0, $groupLimits, true) ? 0 : max($groupLimits);
            }
            if ($userOv !== null) {
                if ($userOv['timeclose'] !== null) {
                    $effClose = (int)$userOv['timeclose'];
                }
                if ($userOv['timelimit'] !== null) {
                    $effLimit = (int)$userOv['timelimit'];
                }
            }
        }

        if (dosman_is_attempt_currently_active($timestart, $effClose, $effLimit, $now)) {
            return [
                'quizid'    => $quizId,
                'timestart' => $timestart,
            ];
        }
    }

    return null;
}

/**
 * Mengembalikan quizid aktif (> 0) jika siswa sedang mengerjakan ujian, atau 0 jika tidak ada.
 */
function dosman_get_active_quiz_id(PDO $pdo, string $prefix, int $userid, ?int $now = null): int {
    $attempt = dosman_get_active_quiz_attempt($pdo, $prefix, $userid, $now);
    return (int)($attempt['quizid'] ?? 0);
}

/**
 * Cek apakah siswa masih memiliki 1x jatah login ulang yang sah setelah di-unsuspend
 * atau di-unblock oleh pengawas (dalam jendela grace, dan belum dipakai login lagi).
 */
function dosman_has_valid_relogin_grace(
    int $maxPrevLastSeen,
    int $latestUnsuspendTs,
    int $now,
    int $graceSec = 180
): bool {
    return $latestUnsuspendTs > 0
        && ($now - $latestUnsuspendTs) >= 0
        && ($now - $latestUnsuspendTs) <= $graceSec
        && $maxPrevLastSeen < $latestUnsuspendTs;
}

/**
 * Tentukan apakah panggilan register_device saat ada attempt ujian 'inprogress' harus
 * langsung men-suspend akun siswa (indikasi tutup paksa & buka ulang aplikasi).
 */
function dosman_should_suspend_mid_exam_relogin(
    ?array $activeAttempt,
    int $maxPrevLastSeen,
    int $latestUnsuspendTs,
    int $now,
    int $minQuizAgeSec = 30,
    int $unsuspendGraceSec = 180
): bool {
    if ($activeAttempt === null || (int)($activeAttempt['quizid'] ?? 0) <= 0) {
        return false;
    }
    if (($now - (int)($activeAttempt['timestart'] ?? 0)) < $minQuizAgeSec) {
        return false;
    }
    if (dosman_has_valid_relogin_grace($maxPrevLastSeen, $latestUnsuspendTs, $now, $unsuspendGraceSec)) {
        return false;
    }
    return true;
}

/**
 * Ambil timestamp pembukaan blokir/unsuspend terbaru dari log pengawas untuk user ini.
 */
function dosman_get_latest_unsuspend_time(PDO $pdo, string $prefix, int $userid): int {
    if ($userid <= 0) {
        return 0;
    }
    $stmt = $pdo->prepare(
        "SELECT COALESCE(MAX(timecreated), 0)
           FROM {$prefix}local_dosman_ujian_logs
          WHERE userid = ? AND eventtype = 'account_unsuspended'"
    );
    $stmt->execute([$userid]);
    return (int)($stmt->fetchColumn() ?: 0);
}

/**
 * Catat log pembukaan suspend/blokir agar register_device memberi 1x izin login ulang.
 */
function dosman_record_unsuspend_log(
    PDO $pdo,
    string $prefix,
    int $userid,
    int $adminId,
    string $source
): void {
    $pdo->prepare(
        "INSERT INTO {$prefix}local_dosman_ujian_logs
             (userid, courseid, quizid, eventtype, eventdata, suspicious, timecreated)
         VALUES (?, 1, 0, 'account_unsuspended', ?, 0, ?)"
    )->execute([
        $userid,
        json_encode(['admin_id' => $adminId, 'source' => $source], JSON_UNESCAPED_UNICODE),
        time(),
    ]);
}

/**
 * Suspend akun siswa secara atomik (identik dengan alur suspend_student.php) beserta pencatatan log.
 */
function dosman_suspend_student_account(
    PDO $pdo,
    string $prefix,
    int $userid,
    int $quizId,
    string $reason,
    string $source,
    string $platform = ''
): void {
    $svcStmt = $pdo->prepare(
        "SELECT id FROM {$prefix}external_services
          WHERE shortname IN ('dosman_ujian_mobile', 'moodle_mobile_app')"
    );
    $svcStmt->execute();
    $serviceIds = array_map('intval', $svcStmt->fetchAll(PDO::FETCH_COLUMN) ?: []);

    $stmt = $pdo->prepare(
        "SELECT value FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian' AND name = 'blocked_students' LIMIT 1"
    );
    $stmt->execute();
    $existing = $stmt->fetchColumn();
    $blocked  = ($existing !== false) ? (json_decode((string)$existing, true) ?: []) : [];
    unset($blocked[(string)$userid]);

    $startedTx = !$pdo->inTransaction();
    if ($startedTx) {
        $pdo->beginTransaction();
    }

    try {
        $stmtLock = $pdo->prepare("SELECT suspended FROM {$prefix}user WHERE id = ? FOR UPDATE");
        $stmtLock->execute([$userid]);
        $stmtLock->fetchColumn();

        $pdo->prepare(
            "UPDATE {$prefix}user
                SET suspended = 1, timemodified = UNIX_TIMESTAMP()
              WHERE id = ?"
        )->execute([$userid]);

        if (!empty($serviceIds)) {
            $placeholders = implode(',', array_fill(0, count($serviceIds), '?'));
            $delParams    = array_merge([$userid], $serviceIds);
            $pdo->prepare(
                "DELETE FROM {$prefix}external_tokens
                  WHERE userid = ? AND externalserviceid IN ({$placeholders})"
            )->execute($delParams);
        }

        $pdo->prepare("DELETE FROM {$prefix}sessions WHERE userid = ?")->execute([$userid]);

        $pdo->prepare(
            "INSERT INTO {$prefix}config_plugins (plugin, name, value)
             VALUES ('local_dosman_ujian', 'blocked_students', ?)
             ON DUPLICATE KEY UPDATE value = VALUES(value)"
        )->execute([json_encode($blocked)]);

        $pdo->prepare(
            "DELETE FROM {$prefix}local_dosman_ujian_appstatus WHERE userid = ?"
        )->execute([$userid]);

        $pdo->prepare(
            "DELETE FROM {$prefix}config_plugins
              WHERE plugin = 'local_dosman_ujian' AND name = ?"
        )->execute(['browser_hb_' . $userid]);

        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_sessions
                SET status = 'released', timemodified = UNIX_TIMESTAMP()
              WHERE userid = ? AND status IN ('active','blocked','paused')"
        )->execute([$userid]);

        $pdo->prepare(
            "UPDATE {$prefix}local_dosman_ujian_devices
                SET status = 'blocked',
                    block_reason = ?,
                    blocked_at = UNIX_TIMESTAMP()
              WHERE userid = ? AND status IN ('active', 'blocked')"
        )->execute([$reason, $userid]);

        $pdo->prepare(
            "INSERT INTO {$prefix}local_dosman_ujian_logs
                 (userid, courseid, quizid, eventtype, eventdata, suspicious, timecreated)
             VALUES (?, 1, ?, 'account_suspended', ?, 1, UNIX_TIMESTAMP())"
        )->execute([
            $userid,
            $quizId,
            json_encode([
                'reason'   => $reason,
                'source'   => $source,
                'platform' => $platform,
            ], JSON_UNESCAPED_UNICODE),
        ]);

        if ($startedTx) {
            $pdo->commit();
        }
    } catch (Throwable $e) {
        if ($startedTx && $pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }

    @unlink('/dev/shm/dosman_app_users_cache.json');
}

/**
 * Daftar CIDR default jaringan lokal sekolah (Wi-Fi Ujian Ruijie, LAN, Lab 3, Tailscale).
 */
function dosman_default_local_cidrs(): string {
    return '10.50.0.0/22,192.168.50.0/24,192.168.100.0/24,100.64.0.0/10,127.0.0.1/32';
}

/**
 * Cek apakah sebuah IPv4 berada dalam rentang CIDR tertentu (atau IP tunggal).
 */
function dosman_ip_in_cidr(string $ip, string $cidr): bool {
    $ip   = trim($ip);
    $cidr = trim($cidr);
    if ($ip === '' || $cidr === '') {
        return false;
    }

    $ipLong = ip2long($ip);
    if ($ipLong === false) {
        return false;
    }

    if (strpos($cidr, '/') === false) {
        $targetLong = ip2long($cidr);
        return $targetLong !== false && $ipLong === $targetLong;
    }

    [$subnet, $prefixRaw] = explode('/', $cidr, 2);
    $subnetLong = ip2long(trim($subnet));
    if ($subnetLong === false || !is_numeric(trim($prefixRaw))) {
        return false;
    }

    $prefixLen = (int)trim($prefixRaw);
    if ($prefixLen < 0 || $prefixLen > 32) {
        return false;
    }

    $mask = $prefixLen === 0 ? 0 : ((-1 << (32 - $prefixLen)) & 0xFFFFFFFF);
    return (($ipLong & $mask) === ($subnetLong & $mask));
}

/**
 * Cek apakah IP klien berasal dari jaringan lokal sekolah berdasarkan daftar CIDR.
 */
function dosman_is_local_school_ip(string $ip, string $cidrList = ''): bool {
    $ip = trim($ip);
    if ($ip === '') {
        return false;
    }
    $raw = trim($cidrList) !== '' ? $cidrList : dosman_default_local_cidrs();
    $cidrs = preg_split('/[\s,]+/', $raw, -1, PREG_SPLIT_NO_EMPTY) ?: [];
    foreach ($cidrs as $cidr) {
        if (dosman_ip_in_cidr($ip, $cidr)) {
            return true;
        }
    }
    return false;
}

/**
 * Ambil kebijakan mode akses jaringan ujian dari config_plugins.
 * Returns ['mode' => 'local_only'|'both', 'allowed_cidrs' => string].
 */
function dosman_get_network_access_policy(PDO $pdo, string $prefix): array {
    $mode  = 'both';
    $cidrs = dosman_default_local_cidrs();

    $stmt = $pdo->prepare(
        "SELECT name, value FROM {$prefix}config_plugins
          WHERE plugin = 'local_dosman_ujian'
            AND name IN ('network_access_mode', 'allowed_local_cidrs')"
    );
    $stmt->execute();
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        if ($row['name'] === 'network_access_mode') {
            $val = trim((string)$row['value']);
            if ($val === 'local_only' || $val === 'both') {
                $mode = $val;
            }
        } else if ($row['name'] === 'allowed_local_cidrs') {
            $val = trim((string)$row['value']);
            if ($val !== '') {
                $cidrs = $val;
            }
        }
    }

    return [
        'mode'          => $mode,
        'allowed_cidrs' => $cidrs,
    ];
}

/**
 * Cek apakah user adalah Admin, Manager, Guru, atau Reviewer resmi (kebal pembatasan jaringan lokal).
 */
function dosman_is_teacher_or_admin_pdo(PDO $pdo, string $prefix, int $userid): bool {
    if ($userid <= 0) {
        return false;
    }
    if (dosman_is_protected_user($pdo, $prefix, $userid)) {
        return true;
    }

    $stmtRole = $pdo->prepare(
        "SELECT COUNT(*) FROM {$prefix}role_assignments ra
           JOIN {$prefix}role r ON r.id = ra.roleid
          WHERE ra.userid = ?
            AND r.archetype IN ('manager','coursecreator','editingteacher','teacher')"
    );
    $stmtRole->execute([$userid]);
    return (int)$stmtRole->fetchColumn() > 0;
}
