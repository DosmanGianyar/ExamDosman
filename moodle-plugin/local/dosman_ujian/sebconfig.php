<?php
/**
 * Endpoint publik: generate file konfigurasi SEB (Safe Exam Browser) untuk iOS.
 * SEB device men-fetch URL ini setiap launch untuk mendapat config terbaru,
 * termasuk hashedQuitPassword (SHA-256 dari password yang disimpan admin di dashboard).
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

// Nilai default (fallback jika config.php tidak dapat dibaca)
$moodle_base      = 'https://lms.sman1-gianyar.sch.id:9443';
$allowed_host_raw = 'lms.sman1-gianyar.sch.id:9443';
$allowed_pat_raw  = '^https://lms\.sman1-gianyar\.sch\.id:9443(/|$)';

$hashed_pwd = '';   // default: tidak perlu password untuk quit
$qr_secret  = '';   // secret untuk validasi QR harian (opsional)

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) throw new RuntimeException('config.php not found');

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix', 'wwwroot'] as $key) {
        if (preg_match('/\$CFG->' . $key . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$key] = $m[1];
        }
    }

    if (empty($cfg['dbname'])) throw new RuntimeException('DB config not parseable');

    // Override URL dari wwwroot Moodle agar sinkron dengan getsebqr.php
    if (!empty($cfg['wwwroot'])) {
        $moodle_base  = rtrim((string)$cfg['wwwroot'], '/');
        $parsed_host  = parse_url($moodle_base, PHP_URL_HOST);
        if ($parsed_host) {
            $allowed_host_raw = (string)$parsed_host;
            $esc              = str_replace('.', '\\.', $allowed_host_raw);
            $allowed_pat_raw  = '^https://([a-z0-9-]+\\.)?' . $esc . '(/|$)';
        }
    }

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    $qrId = trim((string)($_GET['qr'] ?? ''));
    if ($qrId !== '') {
        // Lookup password dari riwayat QR berdasarkan ID
        $stmt = $pdo->prepare(
            'SELECT value FROM ' . $prefix . 'config_plugins
              WHERE plugin = :plugin AND name = :name LIMIT 1'
        );
        $stmt->execute([':plugin' => 'local_dosman_ujian', ':name' => 'seb_qr_history']);
        $raw = $stmt->fetchColumn();
        $qrHistory = $raw ? (json_decode($raw, true) ?: []) : [];
        $today = date('Y-m-d');
        $qrFound = false;
        foreach ($qrHistory as $entry) {
            if (($entry['id'] ?? '') === $qrId) {
                $qrFound = true;
                $qrExamDate = $entry['date'] ?? '';
                // Validasi: QR hanya berlaku pada tanggal ujian yang ditentukan
                if ($qrExamDate !== $today) {
                    $idMonths = ['Januari','Februari','Maret','April','Mei','Juni',
                                 'Juli','Agustus','September','Oktober','November','Desember'];
                    $parts = explode('-', $qrExamDate);
                    $dateLabel = (count($parts) === 3)
                        ? ((int)$parts[2] . ' ' . ($idMonths[(int)$parts[1] - 1] ?? $parts[1]) . ' ' . $parts[0])
                        : $qrExamDate;
                    header('Content-Type: text/html; charset=utf-8');
                    header('Cache-Control: no-store, no-cache');
                    http_response_code(403);
                    echo '<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">'
                        . '<meta name="viewport" content="width=device-width,initial-scale=1">'
                        . '<title>QR Tidak Valid</title>'
                        . '<style>body{font-family:sans-serif;display:flex;align-items:center;'
                        . 'justify-content:center;min-height:100vh;margin:0;background:#f5f5f5;}'
                        . '.box{background:#fff;border-radius:12px;padding:2rem 2.5rem;'
                        . 'max-width:420px;text-align:center;box-shadow:0 2px 16px rgba(0,0,0,.1);}'
                        . 'h1{color:#c0392b;font-size:1.4rem;margin-bottom:.5rem;}'
                        . 'p{color:#555;line-height:1.6;}</style></head><body>'
                        . '<div class="box"><h1>QR Code Tidak Berlaku Hari Ini</h1>'
                        . '<p>QR code ini hanya dapat digunakan pada tanggal<br>'
                        . '<strong>' . htmlspecialchars($dateLabel, ENT_HTML5, 'UTF-8') . '</strong>.</p>'
                        . '<p>Hubungi pengawas ujian untuk mendapatkan QR code yang sesuai.</p>'
                        . '</div></body></html>';
                    exit;
                }
                if (!empty($entry['pwd'])) {
                    $hashed_pwd = hash('sha256', (string)$entry['pwd']);
                }
                break;
            }
        }
        if (!$qrFound) {
            header('Content-Type: text/html; charset=utf-8');
            header('Cache-Control: no-store, no-cache');
            http_response_code(404);
            echo '<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8">'
                . '<title>QR Tidak Ditemukan</title></head><body>'
                . '<p>QR code tidak ditemukan.</p></body></html>';
            exit;
        }
    } else {
        // Fallback: gunakan password global (backward-compat)
        $stmt = $pdo->prepare(
            'SELECT value FROM ' . $prefix . 'config_plugins
              WHERE plugin = :plugin AND name = :name LIMIT 1'
        );
        $stmt->execute([':plugin' => 'local_dosman_ujian', ':name' => 'ios_seb_quit_password']);
        $row = $stmt->fetchColumn();
        if ($row !== false && (string)$row !== '') {
            $hashed_pwd = hash('sha256', (string)$row);
        }
    }

    // ── Catat log download config (IP + UA + waktu), max 100 entri terakhir ──
    $ip  = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? '';
    $ua  = $_SERVER['HTTP_USER_AGENT'] ?? '';
    $now = time();

    $logStmt = $pdo->prepare(
        'SELECT value FROM ' . $prefix . 'config_plugins
          WHERE plugin = :p AND name = :n LIMIT 1'
    );
    $logStmt->execute([':p' => 'local_dosman_ujian', ':n' => 'seb_download_log']);
    $existing = $logStmt->fetchColumn();
    $log = ($existing !== false) ? (json_decode($existing, true) ?: []) : [];

    array_unshift($log, ['ip' => $ip, 'ua' => $ua, 'time' => $now]);
    if (count($log) > 100) $log = array_slice($log, 0, 100);

    $pdo->prepare(
        'INSERT INTO ' . $prefix . 'config_plugins (plugin, name, value)
         VALUES (:p, :n, :v)
         ON DUPLICATE KEY UPDATE value = VALUES(value)'
    )->execute([':p' => 'local_dosman_ujian', ':n' => 'seb_download_log', ':v' => json_encode($log)]);

} catch (Throwable $e) {
    // Gagal silently — gunakan password kosong (quit bebas)
}

header('Content-Type: application/seb; charset=utf-8');
header('Content-Disposition: attachment; filename="dosman_exam.seb"');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');

$start_url           = htmlspecialchars($moodle_base . '/login/index.php', ENT_XML1, 'UTF-8');
$allowed_host        = htmlspecialchars($allowed_host_raw, ENT_XML1, 'UTF-8');
$allowed_url_pattern = htmlspecialchars($allowed_pat_raw, ENT_XML1, 'UTF-8');
$hashed_pwd          = htmlspecialchars($hashed_pwd, ENT_XML1, 'UTF-8');
// SEB modern: suffix UA resmi (bukan key browserUserAgentiOS — iOS menolak sebagai corrupt).
$browser_ua_suffix   = htmlspecialchars(' ExamDosmanIOS', ENT_XML1, 'UTF-8');

echo <<<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

    <!-- ── URL Awal ─────────────────────────────────────────────────── -->
    <key>startURL</key>
    <string>{$start_url}</string>

    <!-- ── Quit Password ────────────────────────────────────────────── -->
    <!-- allowQuit: true agar tombol quit muncul; password kosong = quit bebas -->
    <key>allowQuit</key>
    <true/>
    <key>hashedQuitPassword</key>
    <string>{$hashed_pwd}</string>

    <!-- ── Tampilan Browser ──────────────────────────────────────────── -->
    <!-- Tampilkan toolbar navigasi (tombol Kembali/Maju) agar siswa yang -->
    <!-- tersesat di halaman settings bisa kembali tanpa keluar SEB. -->
    <!-- Keluar SEB tetap memerlukan quit password (hashedQuitPassword). -->
    <key>showTaskBar</key>
    <true/>
    <key>enableBrowserWindowToolbar</key>
    <true/>
    <key>showNavigationButtons</key>
    <true/>
    <key>allowPreferencesWindow</key>
    <false/>

    <!-- ── User Agent (suffix) ───────────────────────────────────────── -->
    <!-- Ditambahkan ke UA default perangkat; harus mengandung ExamDosmanIOS untuk rule Moodle -->
    <key>browserUserAgent</key>
    <string>{$browser_ua_suffix}</string>

    <!-- ── Filter URL ───────────────────────────────────────────────── -->
    <!-- Hanya izinkan domain Moodle sekolah; blokir semua URL lain -->
    <key>URLFilterEnable</key>
    <true/>
    <key>URLFilterEnableContentFilter</key>
    <false/>
    <key>URLFilterRules</key>
    <array>
        <!-- Izinkan semua URL di domain Moodle sekolah (https + path lengkap) -->
        <dict>
            <key>active</key>
            <true/>
            <key>regex</key>
            <true/>
            <key>action</key>
            <integer>1</integer>
            <key>expression</key>
            <string>{$allowed_url_pattern}</string>
        </dict>
    </array>

    <!-- ── Blokir Screenshot & Screen Recording ─────────────────────── -->
    <key>allowScreenCapture</key>
    <false/>

    <!-- ── Blokir Kamera & Mikrofon ─────────────────────────────────── -->
    <!-- Siswa tidak bisa akses kamera/mic dari dalam SEB -->
    <key>allowVideoCapture</key>
    <false/>
    <key>allowAudioCapture</key>
    <false/>

    <!-- ── Blokir Siri (iOS) ─────────────────────────────────────────── -->
    <key>allowSiri</key>
    <false/>

    <!-- ── Blokir Zoom Halaman ───────────────────────────────────────── -->
    <key>enableZoomPage</key>
    <false/>

    <!-- ── Blokir Find in Page (Ctrl+F / Cmd+F) ──────────────────────── -->
    <key>allowFind</key>
    <false/>

    <!-- ── Blokir Spell Check & Kamus ────────────────────────────────── -->
    <!-- Mencegah siswa menggunakan autocorrect sebagai petunjuk jawaban -->
    <key>enableSpellChecking</key>
    <false/>
    <key>allowDictionaryLookup</key>
    <false/>

    <!-- ── Blokir Display Eksternal ──────────────────────────────────── -->
    <!-- Paksa hanya layar bawaan iPad; cegah proyeksi ke TV/monitor luar -->
    <key>allowedDisplayBuiltinEnforce</key>
    <true/>

    <!-- ── Guided Access (Kiosk iOS) ─────────────────────────────────── -->
    <!-- Minta SEB mengaktifkan Guided Access agar siswa tidak bisa -->
    <!-- pindah ke app lain via App Switcher / gesture swipe-up -->
    <key>mobileEnableGuidedAccess</key>
    <true/>
    <key>mobileAllowSingleAppMode</key>
    <true/>

    <!-- ── Blokir buka link di window/tab baru ──────────────────────── -->
    <!-- 0 = buka di window yang sama; mencegah navigasi keluar quiz -->
    <key>newBrowserWindowByLinkPolicy</key>
    <integer>0</integer>

    <!-- ── Blokir PDF viewer internal ───────────────────────────────── -->
    <!-- Cegah siswa membuka file PDF yang mungkin berisi jawaban -->
    <key>allowPDFPlugIn</key>
    <false/>

    <!-- ── Sembunyikan tombol reload ─────────────────────────────────── -->
    <key>showReloadButton</key>
    <false/>

</dict>
</plist>
XML;
