# Dokumen Rencana & Arsitektur Project Lanjutan: Dosman Exam v3.0
**Target Pengembangan:** Pasca Ujian (Maret/April 2026 ke Depan)  
**Tujuan Utama:** 
1. Tampilan antarmuka khusus (Clean & Modern Native Flutter UI) tanpa elemen web Moodle yang membingungkan siswa.
2. Mekanisme kuis Semi-Offline (Download Paket Soal Terenkripsi $\rightarrow$ Pengerjaan Mandiri di HP $\rightarrow$ Upload Jawaban Batch) guna meringankan beban server hingga 90%+.
3. Sistem Keamanan & Kiosk Terpadu (Zero-latency Local Lockout + Ultralight Telemetry Heartbeat untuk pengawasan & suspend).

---

## 1. Analisis Kebutuhan & Problem Statement

### Masalah pada Sistem Saat Ini (v2.7.x - WebView Mode):
- **Beban Server & Database:** Setiap siswa berpindah soal atau menyimpan jawaban, Moodle memproses halaman HTML lengkap, sesi PHP, dan query database. Pada 800+ siswa simultan, ini memicu lonjakan CPU/RAM.
- **Ketergantungan Wi-Fi:** Jika Access Point (AP) di sekolah drop sesaat, halaman web kuis siswa bisa freeze atau blank (ERR_NAME_NOT_RESOLVED / Timeout).
- **Tampilan Kurang Bersih:** Tampilan kuis di WebView membawa komponen bawaan Moodle (navbar, breadcrumbs, tombol lapor, drawer) yang kurang relevan untuk ujian resmi tingkat sekolah.

---

## 2. Arsitektur Dosman Exam v3.0 (Native Semi-Offline)

```
[ Moodle Server (REST API) ]
       │
       │ (1) Download Paket Soal Terenkripsi (di awal ujian)
       ▼
┌─────────────────────────────────────────────────────┐
│                     HP SISWA                        │
│                                                     │
│  [ SQLite / SQLCipher (Secure Local Storage) ]       │
│  - Paket Soal (AES-256)                             │
│  - State Jawaban & Ragu-ragu                        │
│                                                     │
│  [ Native Flutter Quiz Engine ]                     │
│  - Render Soal, Pilihan Ganda, Gambar               │
│  - Local Countdown Timer                            │
│  - Zero-Latency Lockout (Cegah Curang Lokal)       │
│                                                     │
│  [ Background Telemetry Worker ]                    │
│  - Ultralight Heartbeat (~150 bytes / 30s)          │
└─────────────────────────────────────────────────────┘
       │
       │ (2) Ultralight Heartbeat & Suspend Status (selama ujian)
       ▼
[ Dashboard Pengawas / Moodle ]
       ▲
       │ (3) Batch Upload Seluruh Jawaban (saat selesai ujian)
       │
[ HP SISWA ]
```

---

## 3. Komponen Utama & Alur Kerja

### A. Tampilan Kuis (Clean Native Flutter UI)
1. **Layar Pemilihan Ujian / Course:**
   - Hanya menampilkan kartu ujian yang dijadwalkan aktif pada hari itu.
   - Informasi jelas: Nama Mata Pelajaran, Jumlah Soal, Durasi Waktu, Status Pengerjaan.
2. **Layar Pengerjaan Kuis (Distraction-Free):**
   - Header minimalis: Tombol Daftar Nomor Soal, Timer Countdown melayang, Indikator Sinyal/Baterai.
   - Area Soal: Teks soal responsif, dukungan gambar perbesaran (*pinch-to-zoom*), dan render rumus matematika (LaTeX).
   - Area Pilihan Jawaban: Desain kartu pilihan A, B, C, D yang luas dan mudah ditekan.
   - Footer: Tombol "Sebelumnya", "Ragu-ragu", "Berikutnya", dan "Selesaikan Ujian".

### B. Mekanisme Semi-Offline (Quiz Engine)
1. **Fase 1: Download & Enkripsi (Pre-Attempt)**
   - Siswa menekan tombol "Mulai Ujian".
   - Aplikasi memanggil endpoint REST Moodle: `mod_quiz_start_attempt` & `mod_quiz_get_attempt_data`.
   - Data JSON berisi daftar pertanyaan dan token attempt disimpan ke dalam database lokal HP (`sqflite` dengan enkripsi SQLCipher / AES-256).
   - Seluruh asset gambar soal diunduh dan di-cache secara lokal.
2. **Fase 2: Pengerjaan Mandiri (Zero Network Dependency)**
   - Siswa menjawab soal dan berpindah halaman secara instan (0 detik loading).
   - Setiap perubahan jawaban langsung tersimpan di database lokal HP.
   - Timer berjalan menggunakan jam internal terproteksi (mencegah manipulasi waktu perangkat).
3. **Fase 3: Sinkronisasi & Upload Jawaban (Post-Attempt)**
   - Saat waktu habis atau siswa menekan "Selesai", aplikasi mengemas seluruh jawaban dalam 1 request batch API: `mod_quiz_process_attempt` dengan flag `finish=1`.
   - Jika koneksi Wi-Fi sedang padat, aplikasi tidak panik: jawaban tetap tersimpan aman di HP, dan aplikasi menampilkan tombol *"Kirim Ulang Jawaban"* dengan indikator status sinkronisasi.

### C. Keamanan & Pengawasan (Hybrid Security)
1. **Local Security Guardian:**
   - Deteksi otomatis tombol Home, Recent Apps, Split Screen, Floating Apps, dan Screenshot.
   - Layar langsung terkunci seketika (Zero Latency) tanpa menunggu perintah server.
2. **Ultralight Heartbeat & Suspend Checker:**
   - Selama pengerjaan, aplikasi mengirim paket data sangat kecil (~150 bytes) setiap 20–30 detik ke `local_dosman_ujian/heartbeat.php`.
   - Mengirim status: Sisa waktu, jumlah pelanggaran lokal, status baterai.
   - Menerima balasan dari server: `action: "ok"` atau `action: "suspend"`.
   - Jika pengawas menekan **Suspend** di Dashboard, HP siswa terkunci dalam beberapa detik.
3. **Data Erasure:**
   - Setelah server mengonfirmasi jawaban tersimpan dan kuis berstatus *Finished*, data soal di memori lokal HP dihapus bersih (*secure wipe*).

---

## 4. Tahapan Pengerjaan (Roadmap Pelaksanaan)

| Tahap | Fokus Pekerjaan | Estimasi Waktu |
|---|---|---|
| **Tahap 1** | **Backend & API Moodle:** Mengaktifkan Moodle Mobile Web Services, konfigurasi token autentikasi, dan endpoint custom untuk enkripsi paket soal. | 1 Minggu |
| **Tahap 2** | **Quiz Engine & Local Storage:** Membangun arsitektur SQLite/SQLCipher di Flutter untuk menyimpan attempt soal dan jawaban offline. | 1.5 Minggu |
| **Tahap 3** | **Native UI/UX:** Mendesain antarmuka kuis bersih di Flutter (Course List $\rightarrow$ Soal $\rightarrow$ Review Jawaban $\rightarrow$ Submit Dialog). | 1 Minggu |
| **Tahap 4** | **Integrasi Keamanan & Heartbeat:** Menghubungkan sistem suspend dashboard pengawas dengan worker heartbeat Flutter. | 1 Minggu |
| **Tahap 5** | **Testing & Simulasi Skala Besar:** Uji coba di berbagai varian HP (spek rendah hingga tinggi, Android & iOS), uji coba Wi-Fi mati/hidup. | 1 Minggu |
| **Tahap 6** | **Rilis App Store & Play Store:** Pengajuan update resmi v3.0 ke Apple App Store & Google Play Store jauh-jauh hari sebelum jadwal ujian semester. | 1–2 Minggu |

---

## 5. Catatan Kesiapan Ujian Tanggal 16 (Status Quo)
- Untuk ujian tanggal **16**, aplikasi **tetap menggunakan versi 2.7.8 yang sudah disetujui di App Store**.
- Server Moodle sudah dioptimalkan (PHP-FPM 160 worker, MariaDB 1000 koneksi, Redis session non-blocking).
- SOP login bertahap (*staggered start*) 3–5 menit antar ruangan wajib diterapkan untuk menjaga stabilitas AP Wi-Fi sekolah.
