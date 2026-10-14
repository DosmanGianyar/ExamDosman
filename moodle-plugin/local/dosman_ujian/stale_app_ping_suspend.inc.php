<?php
/**
 * Logika suspend otomatis: siswa mode app (lock_status=1) tidak mengirim app_ping
 * lebih lama dari ambang batas → dianggap keluar aplikasi → akun langsung di-suspend.
 *
 * Tidak ada Tier 1 (device block). Hanya satu level: suspend akun.
 *
 * Dipanggil dari app_ping.php (setelah ping valid) dan opsional dari
 * cli_suspend_stale_app_ping.php (cron server).
 *
 * @package    local_dosman_ujian
 */

declare(strict_types=1);

/**
 * Detik tanpa app_ping sebelum akun di-suspend langsung.
 * Interval ping Flutter = 60 dtk; 90 dtk = 1,5 siklus ping sebagai margin aman
 * agar siswa yang masih di layar CourseList tidak terkena suspend false-positive.
 * Siswa yang sedang ujian (orak-orek di meja) terlindungi secara terpisah lewat
 * pengecekan last_heartbeat di query kandidat.
 */
const DOSMAN_UJIAN_STALE_APP_PING_SEC = 90;

/**
 * Suspend akun siswa yang tidak mengirim app_ping lebih dari ambang batas
 * DAN tidak memiliki heartbeat exam aktif (perlindungan siswa orak-orek).
 *
 * Siswa yang masih berada dalam aplikasi saat ujian (heartbeat segar ≤ 45 dtk)
 * dikecualikan sepenuhnya dari proses ini.
 *
 * @return int jumlah akun yang di-suspend pada pemanggilan ini
 */
function dosman_ujian_suspend_stale_app_ping_users(PDO $pdo, string $prefix, int $now): int {
    // FIX: Kehilangan koneksi internet (Wi-Fi drop / signal loss) BUKAN bentuk kecurangan.
    // Menghindari false-positive suspend saat koneksi internet sekolah terputus sesaat.
    // Akun siswa tidak boleh di-suspend hanya karena paket jaringan tidak sampai ke server.
    // Sanksi suspend hanya boleh dilakukan secara manual oleh pengawas dari dashboard
    // atau jika aplikasi native mendeteksi pelanggaran keamanan eksplisit.
    return 0;
}


