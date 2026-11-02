<?php
// suspend_inactive_users.php
// Suspend akun Moodle jika user keluar aplikasi > 15 detik

// --- KONFIGURASI DATABASE TERUPDATE ---
$db_host = 'localhost';
$db_user = 'sql_moodledosman_test';
$db_pass = '043b4b3622a03';
$db_name = 'sql_moodledosman_test';

// Path file heartbeat.json
$heartbeat_file = __DIR__ . '/heartbeat.json';

// Waktu batas (detik)
$timeout = 15;

// Koneksi DB
$conn = new mysqli($db_host, $db_user, $db_pass, $db_name);
if ($conn->connect_error) {
    die('DB Connection failed: ' . $conn->connect_error);
}

// Ambil data heartbeat
if (!file_exists($heartbeat_file)) exit('No heartbeat.json found.');
$data = json_decode(file_get_contents($heartbeat_file), true);
if (!is_array($data)) exit('Invalid heartbeat.json format.');

$now = time();
$suspended = [];

foreach ($data as $username => $last_heartbeat) {
    if (in_array(strtolower(trim((string)$username)), ['appstore.review', 'playstore.review', 'admin.reviewer'], true)) continue;
    if ($now - $last_heartbeat > $timeout) {
        // Cari user id di Moodle (menggunakan prepare agar aman)
        $stmt = $conn->prepare('SELECT id, suspended FROM mdl_user WHERE username = ?');
        $stmt->bind_param('s', $username);
        $stmt->execute();
        $stmt->bind_result($userid, $oldsuspended);
        
        // Simpan hasil fetch ke variabel sementara agar statement bisa ditutup
        if ($stmt->fetch()) {
            $stmt->close(); // Tutup dulu sebelum menjalankan update

            if ($oldsuspended == 0) {
                // Suspend user
                $stmt2 = $conn->prepare('UPDATE mdl_user SET suspended = 1 WHERE id = ?');
                $stmt2->bind_param('i', $userid);
                $stmt2->execute();
                $stmt2->close();
                $suspended[] = $username;
            }
        } else {
            $stmt->close(); // Tutup jika user tidak ditemukan
        }
    }
}

$conn->close();

if ($suspended) {
    echo 'Suspended: ' . implode(', ', $suspended);
} else {
    echo 'No user suspended (All active or already suspended).';
}
?>