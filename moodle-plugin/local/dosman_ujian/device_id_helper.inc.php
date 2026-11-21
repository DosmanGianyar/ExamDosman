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
 * Mengembalikan quizid aktif (> 0) atau 0 jika siswa tidak sedang mengerjakan ujian.
 */
function dosman_get_active_quiz_id(PDO $pdo, string $prefix, int $userid, ?int $now = null): int {
    if ($userid <= 0) {
        return 0;
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
        return 0;
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
            return $quizId;
        }
    }

    return 0;
}
