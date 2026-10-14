<?php
/**
 * Endpoint: Upload / Sinkronisasi Data Kartu Peserta Ujian & Password Siswa
 *
 * Menerima file CSV (multipart/form-data) atau JSON payload.
 * Menyimpan password asli dan data ujian (no_peserta, ruang, sesi, meja)
 * ke tabel mdl_local_dosman_student_cards.
 *
 * POST /local/dosman_ujian/upload_student_cards.php
 *
 * @package    local_dosman_ujian
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

$validApiKey = 'dosman-exam-sman1gianyar-2024';

try {
    $configfile = __DIR__ . '/../../config.php';
    if (!is_readable($configfile)) throw new RuntimeException('config.php not found');

    $src = file_get_contents($configfile);
    $cfg = [];
    foreach (['dbtype', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix'] as $key) {
        if (preg_match('/\$CFG->' . $key . '\s*=\s*[\'"]([^\'"]*)[\'"]/', $src, $m)) {
            $cfg[$key] = $m[1];
        }
    }
    if (empty($cfg['dbname'])) throw new RuntimeException('DB config not parseable');

    $prefix = $cfg['prefix'] ?? 'mdl_';
    $dsn    = 'mysql:host=' . $cfg['dbhost'] . ';dbname=' . $cfg['dbname'] . ';charset=utf8mb4';
    $pdo    = new PDO($dsn, $cfg['dbuser'], $cfg['dbpass'], [
        PDO::ATTR_TIMEOUT => 5,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);

    // Otorisasi: Cek apikey atau token
    $token  = trim((string)($_POST['token'] ?? ($_GET['token'] ?? '')));
    $apiKey = trim((string)($_POST['apikey'] ?? ($_GET['apikey'] ?? '')));

    // Cek JSON body jika bukan form-data
    $rawInput = file_get_contents('php://input');
    $jsonData = null;
    if (!empty($rawInput)) {
        $decoded = json_decode($rawInput, true);
        if (is_array($decoded)) {
            $jsonData = $decoded;
            if (empty($token) && !empty($decoded['token'])) $token = trim($decoded['token']);
            if (empty($apiKey) && !empty($decoded['apikey'])) $apiKey = trim($decoded['apikey']);
        }
    }

    $isAuthorized = false;
    if ($apiKey === $validApiKey) {
        $isAuthorized = true;
    } else if (!empty($token)) {
        $st = $pdo->prepare(
            "SELECT userid FROM {$prefix}external_tokens
              WHERE token = ? AND (validuntil = 0 OR validuntil > ?) LIMIT 1"
        );
        $st->execute([$token, time()]);
        if ($st->fetchColumn() !== false) {
            $isAuthorized = true;
        }
    }

    if (!$isAuthorized) {
        http_response_code(401);
        echo json_encode(['error' => 'Token atau API Key tidak valid']);
        exit;
    }

    // Pastikan tabel ada
    $pdo->exec("
        CREATE TABLE IF NOT EXISTS {$prefix}local_dosman_student_cards (
            id BIGINT AUTO_INCREMENT PRIMARY KEY,
            username VARCHAR(100) NOT NULL UNIQUE,
            plain_password VARCHAR(100) NOT NULL,
            no_peserta VARCHAR(50) DEFAULT '',
            ruang VARCHAR(50) DEFAULT '',
            sesi VARCHAR(50) DEFAULT '',
            meja VARCHAR(50) DEFAULT '',
            created_at INT NOT NULL,
            updated_at INT NOT NULL,
            INDEX idx_username (username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ");

    $items = [];

    // Kasus 1: Upload File CSV
    if (isset($_FILES['csv_file']) && is_uploaded_file($_FILES['csv_file']['tmp_name'])) {
        $tmpPath = $_FILES['csv_file']['tmp_name'];
        $content = file_get_contents($tmpPath);

        // Hapus UTF-8 BOM jika ada
        $content = preg_replace('/^\xEF\xBB\xBF/', '', $content);
        $lines = preg_split('/\r\n|\r|\n/', trim($content));

        if (count($lines) < 2) {
            throw new RuntimeException('File CSV kosong atau tidak memiliki baris data.');
        }

        // Deteksi delimiter: koma, titik koma, atau tab
        $firstLine = $lines[0];
        $delimiter = ',';
        if (substr_count($firstLine, ';') > substr_count($firstLine, ',')) {
            $delimiter = ';';
        } else if (substr_count($firstLine, "\t") > substr_count($firstLine, ',')) {
            $delimiter = "\t";
        }

        $headers = str_getcsv($firstLine, $delimiter);
        $headerMap = [];
        foreach ($headers as $idx => $h) {
            $cleanH = strtolower(trim(preg_replace('/[^a-zA-Z0-9_]/', '', $h)));
            $headerMap[$cleanH] = $idx;
        }

        // Kolom username wajib ada
        $uIdx = $headerMap['username'] ?? ($headerMap['user'] ?? ($headerMap['namapengguna'] ?? null));
        $pIdx = $headerMap['password'] ?? ($headerMap['pass'] ?? ($headerMap['katasandi'] ?? null));
        $npIdx = $headerMap['nopeserta'] ?? ($headerMap['nomorpeserta'] ?? ($headerMap['nis'] ?? ($headerMap['idnumber'] ?? null)));
        $rIdx = $headerMap['ruang'] ?? ($headerMap['ruangan'] ?? ($headerMap['room'] ?? null));
        $sIdx = $headerMap['sesi'] ?? ($headerMap['session'] ?? null);
        $mIdx = $headerMap['meja'] ?? ($headerMap['nomeja'] ?? null);

        if ($uIdx === null || $pIdx === null) {
            throw new RuntimeException('CSV wajib memiliki kolom "username" dan "password". Kolom terdeteksi: ' . implode(', ', $headers));
        }

        for ($i = 1; $i < count($lines); $i++) {
            $line = trim($lines[$i]);
            if (empty($line)) continue;

            $row = str_getcsv($line, $delimiter);
            $u = trim((string)($row[$uIdx] ?? ''));
            $p = trim((string)($row[$pIdx] ?? ''));
            if (empty($u) || empty($p)) continue;

            $items[] = [
                'username'   => $u,
                'password'   => $p,
                'no_peserta' => $npIdx !== null ? trim((string)($row[$npIdx] ?? '')) : '',
                'ruang'      => $rIdx !== null ? trim((string)($row[$rIdx] ?? '')) : '',
                'sesi'       => $sIdx !== null ? trim((string)($row[$sIdx] ?? '')) : '',
                'meja'       => $mIdx !== null ? trim((string)($row[$mIdx] ?? '')) : '',
            ];
        }
    } 
    // Kasus 2: JSON Payload langsung
    else if (!empty($jsonData['students']) && is_array($jsonData['students'])) {
        foreach ($jsonData['students'] as $s) {
            $u = trim((string)($s['username'] ?? ''));
            $p = trim((string)($s['password'] ?? ''));
            if (empty($u) || empty($p)) continue;

            $items[] = [
                'username'   => $u,
                'password'   => $p,
                'no_peserta' => trim((string)($s['no_peserta'] ?? ($s['nopeserta'] ?? ''))),
                'ruang'      => trim((string)($s['ruang'] ?? '')),
                'sesi'       => trim((string)($s['sesi'] ?? '')),
                'meja'       => trim((string)($s['meja'] ?? '')),
            ];
        }
    } else {
        throw new RuntimeException('Tidak ada data yang dikirim. Kirim file "csv_file" atau JSON array "students".');
    }

    if (empty($items)) {
        throw new RuntimeException('Tidak ada baris data siswa yang valid dengan username dan password.');
    }

    // Bulk Upsert ke tabel mdl_local_dosman_student_cards
    $now = time();
    $sql = "
        INSERT INTO {$prefix}local_dosman_student_cards
            (username, plain_password, no_peserta, ruang, sesi, meja, created_at, updated_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            plain_password = VALUES(plain_password),
            no_peserta     = IF(VALUES(no_peserta) != '', VALUES(no_peserta), no_peserta),
            ruang          = IF(VALUES(ruang) != '', VALUES(ruang), ruang),
            sesi           = IF(VALUES(sesi) != '', VALUES(sesi), sesi),
            meja           = IF(VALUES(meja) != '', VALUES(meja), meja),
            updated_at     = VALUES(updated_at)
    ";

    $stmt = $pdo->prepare($sql);
    $pdo->beginTransaction();
    $savedCount = 0;

    foreach ($items as $item) {
        $stmt->execute([
            $item['username'],
            $item['password'],
            $item['no_peserta'],
            $item['ruang'],
            $item['sesi'],
            $item['meja'],
            $now,
            $now
        ]);
        $savedCount++;
    }
    $pdo->commit();

    echo json_encode([
        'success' => true,
        'count'   => $savedCount,
        'message' => "Berhasil menyimpan $savedCount data password & kartu peserta ujian ke server."
    ]);

} catch (Throwable $e) {
    if (isset($pdo) && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    http_response_code(400);
    echo json_encode([
        'success' => false,
        'error'   => $e->getMessage()
    ]);
}
