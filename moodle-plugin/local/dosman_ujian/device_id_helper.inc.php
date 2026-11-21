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
 * Satu-satunya sumber kebenaran apakah siswa sedang aktif mengerjakan ujian:
 * wajib memiliki attempt Moodle dengan state = 'inprogress'.
 * Mengembalikan quizid aktif (> 0) atau 0 jika siswa tidak sedang mengerjakan ujian.
 */
function dosman_get_active_quiz_id(PDO $pdo, string $prefix, int $userid): int {
    if ($userid <= 0) {
        return 0;
    }
    $stmt = $pdo->prepare(
        "SELECT quiz FROM {$prefix}quiz_attempts
          WHERE userid = ? AND state = 'inprogress'
          ORDER BY timestart DESC
          LIMIT 1"
    );
    $stmt->execute([$userid]);
    return (int)($stmt->fetchColumn() ?: 0);
}
