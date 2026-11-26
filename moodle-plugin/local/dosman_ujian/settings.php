<?php
/**
 * Admin settings for local_dosman_ujian
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

if ($hassiteconfig) {
    $settings = new admin_settingpage(
        'local_dosman_ujian',
        get_string('pluginname', 'local_dosman_ujian')
    );

    $ADMIN->add('localplugins', $settings);

    // Password keluar aplikasi
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/admin_exit_password',
        'Password Keluar Aplikasi',
        'Password yang harus dimasukkan guru/admin untuk keluar dari mode ujian di aplikasi Dosman Exam.',
        '123456',
        PARAM_RAW_TRIMMED
    ));

    // Password buka blokir siswa
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/admin_unblock_password',
        'Password Buka Blokir Siswa',
        'Kode yang dapat dimasukkan siswa di layar blokir untuk membuka blokir akun mereka sendiri. Berikan kode ini kepada siswa yang ingin membuka blokirnya.',
        '',
        PARAM_RAW_TRIMMED
    ));

    // Kode Kirim Darurat Proktor
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/admin_rescue_password',
        'Kode Kirim Darurat Proktor',
        'Kode rahasia proktor/admin untuk mengimpor paksa jawaban terkunci dari HP siswa yang terlambat kirim (>30 menit) ke attempt kosong (0 terjawab) di Moodle. JANGAN dibagikan ke siswa (berbeda dari Password Keluar). Dapat juga diatur dari Dashboard Monitor → Tab Password Keluar & Keamanan.',
        '',
        PARAM_RAW_TRIMMED
    ));

    // Versi build minimum APK Android (0 = tidak wajib update)
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/min_android_build',
        'Build Minimum APK Android',
        'Isi angka build minimum APK Android yang diizinkan login (mis. 159 untuk Play Store v2.8.7+159). Isi 0 untuk menonaktifkan kewajiban update. APK lama otomatis ditolak tanpa memblokir permanen perangkat.',
        '0',
        PARAM_INT
    ));

    // Tautan Google Play Store / unduhan APK Android terbaru
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/android_download_url',
        'Link Google Play Store Android Terbaru',
        'URL Google Play Store resmi (atau link unduhan APK) yang ditampilkan pada pesan wajib update di HP Android siswa.',
        'https://play.google.com/store/apps/details?id=com.dosman.dosman_ujian',
        PARAM_RAW_TRIMMED
    ));

    // Versi build minimum Aplikasi iOS (0 = tidak wajib update)
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/min_ios_build',
        'Build Minimum Aplikasi iOS',
        'Isi angka build minimum aplikasi iOS yang diizinkan login (mis. 159 untuk rilis terbaru App Store). Isi 0 untuk menonaktifkan kewajiban update. Versi lama otomatis ditolak tanpa memblokir permanen perangkat.',
        '0',
        PARAM_INT
    ));

    // Tautan App Store iOS terbaru
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/ios_download_url',
        'Link App Store iOS Terbaru',
        'URL App Store resmi Exam Dosman yang ditampilkan pada pesan wajib update di iPhone/iPad siswa.',
        'https://apps.apple.com/id/app/exam-dosman/id6823572758',
        PARAM_RAW_TRIMMED
    ));

    // Mode akses jaringan ujian (Lokal/Offline Saja vs Lokal & Online)
    $settings->add(new admin_setting_configselect(
        'local_dosman_ujian/network_access_mode',
        'Mode Akses Jaringan Ujian',
        'Kontrol apakah siswa boleh ujian dari Internet/Kuota atau dipaksa hanya melalui Wi-Fi lokal sekolah (EXAM DOSMAN / LAN). Guru, proktor, dan admin tetap dapat mengakses dari mana saja.',
        'both',
        [
            'both'       => 'Lokal & Online (Wi-Fi Sekolah + Internet/Kuota)',
            'local_only' => 'Lokal / Offline Saja (Hanya Wi-Fi EXAM DOSMAN / LAN Sekolah)',
        ]
    ));

    // Daftar subnet/CIDR jaringan lokal sekolah yang diizinkan saat Mode Lokal / Offline Saja aktif
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/allowed_local_cidrs',
        'Daftar Subnet Lokal Sekolah (CIDR)',
        'Daftar IP/CIDR jaringan lokal sekolah dipisah koma yang diizinkan ketika Mode Akses Jaringan disetel ke Lokal / Offline Saja.',
        '10.50.0.0/22,192.168.50.0/24,192.168.100.0/24,100.64.0.0/10,127.0.0.1/32',
        PARAM_RAW_TRIMMED
    ));

    // Tautan ke dashboard monitor
    $settings->add(new admin_setting_heading(
        'local_dosman_ujian/monitor_link',
        '',
        '<a href="' . (new moodle_url('/local/dosman_ujian/index.php'))->out() . '"
            style="display:inline-block;margin-top:4px;padding:8px 18px;background:#2563eb;
                   color:#fff;border-radius:8px;text-decoration:none;font-size:14px;font-weight:600;">
            📊 Buka Dashboard Monitor Siswa
        </a>'
    ));
}
