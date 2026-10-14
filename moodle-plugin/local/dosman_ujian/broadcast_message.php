<?php
/**
 * Endpoint: kirim, baca, atau batalkan pengumuman kilat (Broadcast)
 * dari proktor dashboard ke seluruh HP siswa yang sedang ujian.
 *
 * POST body (JSON): { token, message, expires_in (detik, default 1800) }
 *   Jika message kosong: membatalkan/menarik pengumuman aktif.
 *
 * GET ?token=... atau ?apikey=...
 *   -> { success: true, broadcast: {...} atau null }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, X-Dosman-Token');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

const DOSMAN_API_KEY = 'dosman-exam-sman1gianyar-2024';

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) throw new RuntimeException('config.php not found');

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $key) {
        if (preg_match('/\$CFG->' . $key . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) $cfg[$key] = $m[1];
    }
    if (empty($cfg['dbname'])) throw new RuntimeException('DB config not parseable');

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    $now = time();

    // ── GET: Ambil pengumuman aktif saat ini ──────────────────────────────────
    if ($_SERVER['REQUEST_METHOD'] === 'GET') {
        $stmt = $pdo->prepare(
            "SELECT value FROM {$prefix}config_plugins
              WHERE plugin = 'local_dosman_ujian' AND name = 'active_broadcast' LIMIT 1"
        );
        $stmt->execute();
        $raw = $stmt->fetchColumn();
        $broadcast = null;
        if ($raw) {
            $data = json_decode($raw, true);
            if (!empty($data) && ($data['expires_at'] ?? 0) > $now) {
                $broadcast = $data;
            }
        }
        echo json_encode(['success' => true, 'broadcast' => $broadcast]);
        exit;
    }

    // ── POST: Kirim atau hapus pengumuman ─────────────────────────────────────
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $body      = json_decode(file_get_contents('php://input'), true) ?: [];
        $token     = trim((string)($body['token'] ?? $_SERVER['HTTP_X_DOSMAN_TOKEN'] ?? ''));
        $apikey    = trim((string)($body['apikey'] ?? ''));
        $message   = trim((string)($body['message'] ?? ''));
        $expiresIn = (int)($body['expires_in'] ?? 1800); // default 30 menit
        if ($expiresIn <= 60) $expiresIn = 1800;

        $authorized = false;
        $senderName = 'Pengawas Ruangan';

        // Validasi via API Key
        if ($apikey === DOSMAN_API_KEY) {
            $authorized = true;
            $senderName = 'Panitia Ujian';
        }

        // Validasi via Token Guru
        if (!$authorized && $token !== '') {
            $stTok = $pdo->prepare(
                "SELECT u.id, u.firstname, u.lastname
                   FROM {$prefix}external_tokens t
                   JOIN {$prefix}user u ON u.id = t.userid
                  WHERE t.token = ? AND (t.validuntil = 0 OR t.validuntil > ?) LIMIT 1"
            );
            $stTok->execute([$token, $now]);
            $uRow = $stTok->fetch(PDO::FETCH_ASSOC);
            if ($uRow) {
                $authorized = true;
                $senderName = trim(($uRow['firstname'] ?? '') . ' ' . ($uRow['lastname'] ?? '')) ?: 'Proktor';
            }
        }

        if (!$authorized) {
            http_response_code(401);
            echo json_encode(['success' => false, 'error' => 'Unauthorized']);
            exit;
        }

        if ($message === '') {
            // Hapus pengumuman aktif
            $pdo->prepare(
                "DELETE FROM {$prefix}config_plugins
                  WHERE plugin = 'local_dosman_ujian' AND name = 'active_broadcast'"
            )->execute();

            echo json_encode(['success' => true, 'message' => 'Pengumuman berhasil ditarik', 'broadcast' => null]);
            exit;
        }

        // Simpan broadcast baru
        $bcId = 'bc_' . $now . '_' . substr(bin2hex(random_bytes(3)), 0, 6);
        $payload = [
            'id'         => $bcId,
            'message'    => $message,
            'sender'     => $senderName,
            'created_at' => $now,
            'expires_at' => $now + $expiresIn,
        ];

        $jsonStr = json_encode($payload, JSON_UNESCAPED_UNICODE);

        $pdo->prepare(
            "INSERT INTO {$prefix}config_plugins (plugin, name, value)
             VALUES ('local_dosman_ujian', 'active_broadcast', ?)
             ON DUPLICATE KEY UPDATE value = VALUES(value)"
        )->execute([$jsonStr]);

        echo json_encode(['success' => true, 'message' => 'Pengumuman berhasil dikirim ke seluruh siswa', 'broadcast' => $payload]);
        exit;
    }

} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'error' => 'Server error: ' . $e->getMessage()]);
}
