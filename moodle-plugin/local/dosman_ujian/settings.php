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

    // Versi build minimum APK Android (0 = tidak wajib update)
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/min_android_build',
        'Build Minimum APK Android',
        'Isi angka build minimum APK Android yang diizinkan login (mis. 152 untuk v2.8.0+152). Isi 0 untuk menonaktifkan kewajiban update. APK lama otomatis ditolak tanpa memblokir permanen perangkat.',
        '0',
        PARAM_INT
    ));

    // Tautan download APK Android terbaru (opsional)
    $settings->add(new admin_setting_configtext(
        'local_dosman_ujian/android_download_url',
        'Link Download APK Android Terbaru',
        'Opsional. URL unduhan APK terbaru yang ditampilkan pada pesan wajib update di HP siswa.',
        '',
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
