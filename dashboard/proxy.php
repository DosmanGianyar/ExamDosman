<?php
/**
 * CORS Proxy - Dosman Ujian Dashboard v5.0
 * Fix: loopback issue — server tidak bisa koneksi ke domain publik sendiri
 * Solusi: coba 127.0.0.1 dulu (lokal), baru fallback ke public URL
 *
 * Path: /www/wwwroot/.../dashboard/proxy.php
 */

error_reporting(0);
ini_set('display_errors', '0');
ini_set('display_startup_errors', '0');

header('Content-Type: application/json; charset=utf-8');

$MOODLE_HOST = 'lms.sman1-gianyar.sch.id:9443';
$MOODLE_URL  = 'https://' . $MOODLE_HOST;

function loadDbConfigFromMoodle(): array {
    $candidates = [
        dirname(__DIR__) . '/config.php',
        dirname(dirname(__DIR__)) . '/config.php',
        __DIR__ . '/../config.php',
    ];
    $cfgPath = null;
    foreach ($candidates as $path) {
        if (file_exists($path)) {
            $cfgPath = $path;
            break;
        }
    }
    if ($cfgPath === null) {
        throw new RuntimeException('config.php Moodle tidak ditemukan');
    }

    $cfgSrc = file_get_contents($cfgPath);
    $cfg = [];
    foreach (['dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $k) {
        preg_match('/\$CFG->' . $k . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $cfgSrc, $m);
        $cfg[$k] = $m[1] ?? '';
    }
    $cfg['prefix'] = $cfg['prefix'] ?: 'mdl_';
    return $cfg;
}

function isAuthorizedHeartbeatRequest(string $token, string $apiKey): bool {
    if ($apiKey !== '') {
        $expected = getenv('DOSMAN_EXIT_API_KEY') ?: '';
        if ($expected !== '' && hash_equals($expected, $apiKey)) {
            return true;
        }
    }

    if ($token === '') return false;
    try {
        $cfg = loadDbConfigFromMoodle();
        $pdo = new PDO(
            "mysql:host={$cfg['dbhost']};dbname={$cfg['dbname']};charset=utf8mb4",
            $cfg['dbuser'],
            $cfg['dbpass'],
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5]
        );
        $stmt = $pdo->prepare(
            "SELECT id FROM {$cfg['prefix']}external_tokens
              WHERE token = ?
                AND (validuntil = 0 OR validuntil > UNIX_TIMESTAMP())
              LIMIT 1"
        );
        $stmt->execute([$token]);
        return $stmt->fetchColumn() !== false;
    } catch (Throwable $e) {
        return false;
    }
}


$endpoint = isset($_GET['_endpoint']) ? trim($_GET['_endpoint']) : '';
$params   = $_GET;
unset($params['_endpoint']);

// ── Endpoint untuk mencatat heartbeat user ──────────────────────────────────
if ($endpoint === 'heartbeat') {
    $username = isset($params['username']) ? trim($params['username']) : '';
    $token = trim((string)($params['token'] ?? $_SERVER['HTTP_X_MOODLE_TOKEN'] ?? ''));
    $apiKey = trim((string)($params['apikey'] ?? $_SERVER['HTTP_X_DOSMAN_APIKEY'] ?? ''));
    if (!isAuthorizedHeartbeatRequest($token, $apiKey)) {
        http_response_code(401);
        echo json_encode(['status' => 'error', 'message' => 'Unauthorized']);
        exit;
    }
    if ($username === '') {
        echo json_encode(['status' => 'error', 'message' => 'Username wajib diisi']);
        exit;
    }
    $file = __DIR__ . '/heartbeat.json';
    $data = [];
    if (file_exists($file)) {
        $raw  = file_get_contents($file);
        $data = json_decode($raw, true);
        if (!is_array($data)) $data = [];
    }
    $data[$username] = time();
    file_put_contents($file, json_encode($data));
    echo json_encode(['status' => 'ok', 'message' => 'Heartbeat saved', 'username' => $username]);
    exit;
}

// ── Endpoint untuk mencatat waktu keluar user ─────────────
if ($endpoint === 'logout_activity') {
    $username = isset($params['username']) ? trim($params['username']) : '';
    $token = trim((string)($params['token'] ?? $_SERVER['HTTP_X_MOODLE_TOKEN'] ?? ''));
    $apiKey = trim((string)($params['apikey'] ?? $_SERVER['HTTP_X_DOSMAN_APIKEY'] ?? ''));
    if (!isAuthorizedHeartbeatRequest($token, $apiKey)) {
        http_response_code(401);
        echo json_encode(['status' => 'error', 'message' => 'Unauthorized']);
        exit;
    }
    if ($username === '') {
        echo json_encode(['status' => 'error', 'message' => 'Username wajib diisi']);
        exit;
    }
    $file = __DIR__ . '/logout_activity.json';
    $data = [];
    if (file_exists($file)) {
        $json = file_get_contents($file);
        $data = json_decode($json, true);
        if (!is_array($data)) $data = [];
    }
    $data[$username] = time();
    file_put_contents($file, json_encode($data));
    echo json_encode(['status' => 'ok', 'message' => 'Logout time saved', 'username' => $username]);
    exit;
}

// ── Endpoint test diagnostik ─────────────────────────────────────────────────
if ($endpoint === 'test') {
    echo json_encode([
        'status'      => 'ok',
        'php_version' => PHP_VERSION,
        'curl'        => function_exists('curl_init') ? 'yes' : 'no',
        'fopen'       => ini_get('allow_url_fopen') ? 'yes' : 'no',
        'moodle_url'  => $MOODLE_URL,
        'proxy_ver'   => '5.0',
    ]);
    exit;
}

if ($endpoint === 'token') {
    $path = '/login/token.php';
} elseif ($endpoint === 'webservice') {
    $path = '/webservice/rest/server.php';
} else {
    echo json_encode(['exception' => 'proxyerror', 'message' => 'Endpoint tidak valid']);
    exit;
}

$query      = http_build_query($params);
$publicUrl  = $MOODLE_URL . $path . '?' . $query;

// ── Ekstrak JSON bersih (buang PHP notice/warning HTML di depan) ─────────────
function extractJson($raw) {
    if (empty($raw)) return false;
    $raw = trim($raw);
    if ($raw[0] === '{' || $raw[0] === '[') return $raw;
    $posObj = strpos($raw, '{');
    $posArr = strpos($raw, '[');
    if ($posObj === false && $posArr === false) return false;
    if ($posObj === false)      $start = $posArr;
    elseif ($posArr === false)  $start = $posObj;
    else                        $start = min($posObj, $posArr);
    return substr($raw, $start);
}

// ── Helper: cURL request ─────────────────────────────────────────────────────
function doCurl($url, $extraOpts = []) {
    if (!function_exists('curl_init')) return false;
    $ch = curl_init($url);
    $defaults = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
        CURLOPT_HTTPHEADER     => ['Accept: application/json'],
    ];
    curl_setopt_array($ch, $defaults + $extraOpts);
    $response  = @curl_exec($ch);
    $lastError = curl_error($ch);
    curl_close($ch);
    return ($response !== false && $response !== '') ? $response : false;
}

$response  = false;
$lastError = 'Semua metode koneksi gagal';

// ════════════════════════════════════════════════════════════════════════════
// METODE 1: cURL ke HTTPS publik dengan CURLOPT_RESOLVE → 127.0.0.1
// Trik: URL tetap pakai domain asli (agar SNI & Host header benar),
// tapi koneksi TCP diarahkan ke 127.0.0.1 agar tidak keluar server.
// ════════════════════════════════════════════════════════════════════════════
if ($response === false && function_exists('curl_init')) {
    $response = doCurl($publicUrl, [
        CURLOPT_RESOLVE => [$MOODLE_HOST . ':443:127.0.0.1'],
    ]);
    if ($response === false) $lastError = 'Metode 1 (HTTPS+resolve) gagal';
}

// ════════════════════════════════════════════════════════════════════════════
// METODE 2: cURL ke HTTP 127.0.0.1 dengan Host header
// Bypass SSL — cocok jika Nginx/Apache juga listen di port 80
// ════════════════════════════════════════════════════════════════════════════
if ($response === false && function_exists('curl_init')) {
    $localUrl = 'http://127.0.0.1' . $path . '?' . $query;
    $response = doCurl($localUrl, [
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Host: ' . $MOODLE_HOST,
        ],
    ]);
    if ($response === false) $lastError = 'Metode 2 (HTTP 127.0.0.1) gagal';
}

// ════════════════════════════════════════════════════════════════════════════
// METODE 3: cURL ke HTTP localhost dengan Host header
// ════════════════════════════════════════════════════════════════════════════
if ($response === false && function_exists('curl_init')) {
    $localHostUrl = 'http://localhost' . $path . '?' . $query;
    $response = doCurl($localHostUrl, [
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Host: ' . $MOODLE_HOST,
        ],
    ]);
    if ($response === false) $lastError = 'Metode 3 (HTTP localhost) gagal';
}

// ════════════════════════════════════════════════════════════════════════════
// METODE 4: cURL ke URL publik langsung (tanpa resolve override)
// Fallback jika server bisa outbound internet
// ════════════════════════════════════════════════════════════════════════════
if ($response === false && function_exists('curl_init')) {
    $response = doCurl($publicUrl);
    if ($response === false) $lastError = 'Metode 4 (HTTPS publik) gagal';
}

// ════════════════════════════════════════════════════════════════════════════
// METODE 5: file_get_contents ke 127.0.0.1 dengan Host header
// ════════════════════════════════════════════════════════════════════════════
if ($response === false && ini_get('allow_url_fopen')) {
    $localUrl = 'http://127.0.0.1' . $path . '?' . $query;
    $ctx = stream_context_create([
        'http' => [
            'method'  => 'GET',
            'timeout' => 15,
            'header'  => "Accept: application/json\r\nHost: " . $MOODLE_HOST . "\r\n",
        ],
    ]);
    $response = @file_get_contents($localUrl, false, $ctx);
    if ($response === false) $lastError = 'Metode 5 (fopen 127.0.0.1) gagal';
}

// ════════════════════════════════════════════════════════════════════════════
// METODE 6: file_get_contents ke URL publik
// Fallback terakhir
// ════════════════════════════════════════════════════════════════════════════
if ($response === false && ini_get('allow_url_fopen')) {
    $ctx = stream_context_create([
        'http' => [
            'method'  => 'GET',
            'timeout' => 15,
            'header'  => "Accept: application/json\r\n",
        ],
        'ssl' => [
            'verify_peer'      => false,
            'verify_peer_name' => false,
        ],
    ]);
    $response = @file_get_contents($publicUrl, false, $ctx);
    if ($response === false) $lastError = 'Metode 6 (fopen publik) gagal';
}

// ── Semua metode gagal ───────────────────────────────────────────────────────
if ($response === false || $response === '') {
    echo json_encode([
        'exception' => 'proxyerror',
        'message'   => 'Tidak dapat menghubungi Moodle. ' . $lastError .
                       '. Pastikan Moodle berjalan dan dapat diakses dari server.',
    ]);
    exit;
}

// ── Ekstrak & parse JSON ─────────────────────────────────────────────────────
$clean   = extractJson($response);
$decoded = $clean ? json_decode($clean, true) : null;

if ($decoded === null) {
    $preview = substr(trim(strip_tags($response)), 0, 300);
    echo json_encode([
        'exception' => 'proxyerror',
        'message'   => 'Gagal parse JSON dari Moodle. Preview: ' . $preview,
    ]);
    exit;
}

echo json_encode($decoded);
