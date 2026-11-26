<?php
/**
 * Endpoint: verifikasi jumlah jawaban yang benar-benar tersimpan di Moodle untuk sebuah quiz attempt.
 * Dipakai Flutter app setelah mod_quiz_process_attempt agar tidak salah menampilkan
 * "BUKTI UJIAN TERKIRIM" jika Moodle menolak jawaban karena terlambat (gaveup / 0 terjawab).
 *
 * Lightweight Direct PDO — aman untuk beban 800+ siswa bersamaan.
 *
 * POST body (JSON): { "token": "<wstoken>", "attempt_id": 12345 }
 * Response 200:
 *   { "success": true, "attempt_id": 12345, "state": "finished", "total_slots": 40, "answered_slots": 38, "timefinish": 1795667830 }
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method not allowed']);
    exit;
}

$body      = json_decode(file_get_contents('php://input'), true) ?: [];
$token     = trim((string)($body['token'] ?? ''));
$attemptId = (int)($body['attempt_id'] ?? 0);

if ($token === '' || $attemptId <= 0) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => 'Parameter tidak lengkap']);
    exit;
}

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) {
        throw new RuntimeException('config.php not found');
    }

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $k) {
        if (preg_match('/\$CFG->' . $k . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$k] = $m[1];
        }
    }
    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    $now = time();

    // Validasi token Moodle aktif milik user (tidak dihapus).
    $stmtTok = $pdo->prepare(
        "SELECT et.userid
           FROM {$prefix}external_tokens et
           JOIN {$prefix}user u ON u.id = et.userid
          WHERE et.token = ?
            AND (et.validuntil = 0 OR et.validuntil > ?)
            AND u.deleted = 0
          LIMIT 1"
    );
    $stmtTok->execute([$token, $now]);
    $userid = (int)$stmtTok->fetchColumn();
    if ($userid <= 0) {
        http_response_code(401);
        echo json_encode(['success' => false, 'message' => 'Token tidak valid atau kedaluwarsa']);
        exit;
    }

    // Pastikan attempt memang milik user tersebut.
    $stmtAtt = $pdo->prepare(
        "SELECT id, uniqueid, state, timefinish
           FROM {$prefix}quiz_attempts
          WHERE id = ? AND userid = ?
          LIMIT 1"
    );
    $stmtAtt->execute([$attemptId, $userid]);
    $attRow = $stmtAtt->fetch(PDO::FETCH_ASSOC);
    if ($attRow === false) {
        http_response_code(404);
        echo json_encode(['success' => false, 'message' => 'Attempt tidak ditemukan']);
        exit;
    }

    $qubaId = (int)$attRow['uniqueid'];

    // Hitung total slot soal & slot yang benar-benar memiliki responsesummary terisi.
    $stmtCnt = $pdo->prepare(
        "SELECT COUNT(*) AS total_slots,
                SUM(CASE WHEN responsesummary IS NOT NULL AND TRIM(responsesummary) <> '' THEN 1 ELSE 0 END) AS answered_slots
           FROM {$prefix}question_attempts
          WHERE questionusageid = ?"
    );
    $stmtCnt->execute([$qubaId]);
    $cntRow = $stmtCnt->fetch(PDO::FETCH_ASSOC);

    $totalSlots    = (int)($cntRow['total_slots'] ?? 0);
    $answeredSlots = (int)($cntRow['answered_slots'] ?? 0);

    echo json_encode([
        'success'        => true,
        'attempt_id'     => (int)$attRow['id'],
        'state'          => (string)$attRow['state'],
        'total_slots'    => $totalSlots,
        'answered_slots' => $answeredSlots,
        'timefinish'     => (int)($attRow['timefinish'] ?? 0),
    ]);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['success' => false, 'message' => 'Server error']);
}
