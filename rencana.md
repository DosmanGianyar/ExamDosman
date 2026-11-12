# Dokumen Rencana & Arsitektur Project Lanjutan: Dosman Exam v3.0
**Target Pengembangan:** Pasca Ujian (Mulai Akhir Maret 2026 ke Depan)  
**Tujuan Utama:** 
1. Tampilan antarmuka khusus (Clean & Modern Native Flutter UI) tanpa elemen web Moodle yang membingungkan siswa.
2. Mekanisme kuis Semi-Offline (Download Paket Soal Terenkripsi $\rightarrow$ Pengerjaan Mandiri di HP $\rightarrow$ Upload Jawaban Batch) guna meringankan beban server hingga 90%+.
3. Sistem Keamanan & Kiosk Terpadu (Zero-latency Local Lockout + Ultralight Telemetry Heartbeat untuk pengawasan & suspend).
4. Opsi Modernisasi Backend: Evaluasi antara Headless Moodle vs Custom CBT Backend (Open Source / Scratch).

---

## 1. Analisis Kebutuhan & Problem Statement

### Masalah pada Sistem Saat Ini (v2.7.x - WebView Mode):
- **Beban Server & Database:** Setiap siswa berpindah soal atau menyimpan jawaban, Moodle memproses halaman HTML lengkap, sesi PHP, dan query database. Pada 800+ siswa simultan, ini memicu lonjakan CPU/RAM.
- **Ketergantungan Wi-Fi:** Jika Access Point (AP) di sekolah drop sesaat, halaman web kuis siswa bisa freeze atau blank (ERR_NAME_NOT_RESOLVED / Timeout).
- **Tampilan Kurang Bersih:** Tampilan kuis di WebView membawa komponen bawaan Moodle (navbar, breadcrumbs, tombol lapor, drawer) yang kurang relevan untuk ujian resmi tingkat sekolah.

---

## 2. Arsitektur Dosman Exam v3.0 (Native Semi-Offline)

```
[ Backend Server (Moodle REST / Custom CBT API) ]
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
[ Dashboard Pengawas Server ]
       ▲
       │ (3) Batch Upload Seluruh Jawaban (saat selesai ujian)
       │
[ HP SISWA ]
```

---

## 3. Komparasi Opsi Backend: Moodle vs Custom / Open Source

| Kriteria | Opsi 1: Headless Moodle (REST API) | Opsi 2: Fork Open Source CBT (Laravel/Candy CBT/jujurCBT) | Opsi 3: Custom Micro-Backend (Go Fiber / Node.js) |
|---|---|---|---|
| **Kelebihan** | Guru tetap pakai Moodle lama; fitur nilai, bank soal, dan acak soal sudah 100% matang; tidak perlu pelatihan guru baru. | Khusus format sekolah Indonesia (Aiken/Excel/Word); ada role guru & pengawas; kode PHP familiar. | Kinerja paling tinggi di dunia (bisa 10.000 req/s, RAM < 50MB); arsitektur API sangat clean & mudah disesuaikan. |
| **Kekurangan** | Struktur API Moodle cukup berbelit-belit untuk mobile dev. | Tampilan web default jadul; perlu dipreteli agar murni jadi REST API untuk Flutter; performa PHP standar. | Butuh waktu membuat Web Dashboard admin/guru untuk input soal & rekap nilai (meski dibantu AI). |
| **Beban Server (800 Siswa)** | Sangat Rendah (turun 85% karena via JSON) | Sangat Rendah (karena pengerjaan semi-offline) | Hampir 0% (Sangat dingin & super efisien) |
| **Rekomendasi Waktu** | Cepat (2 Minggu) | Sedang (2–3 Minggu) | Cepat dengan AI (2–3 Minggu) |

---

## 4. Referensi Open-Source CBT Terbaik di GitHub

Jika kita memilih jalur menggunakan basis open-source yang sudah ada untuk disesuaikan:

1. **`fadhil-riyanto/jujurCBT` (Laravel 11 + MariaDB/Vite)**
   - *Kelebihan:* Menggunakan Laravel modern, didesain khusus ujian sekolah di Indonesia yang jujur dan bersih.
   - *Penyesuaian:* Kita pasang REST API Controller untuk koneksi ke Flutter App.
2. **`ahmadammarm/ujian-cbt` (Naiju - Laravel 11 + Vue 3)**
   - *Kelebihan:* Manajemen bank soal privat guru, autosave jawaban, rate limiting, dan proteksi anti-kecurangan.
3. **`codezelat/laravel-mcq-exam-system` (Laravel)**
   - *Kelebihan:* Penegakan ujian satu kali pengerjaan (*single attempt*), pencegahan login ganda (*concurrent login prevention* dengan atomic lock), dan penilaian instan.
4. **`semmidev/lms` (Go / Golang Fiber v2 + React)**
   - *Kelebihan:* Performa backend luar biasa kencang (Go Fiber), clean architecture, sangat hemat RAM server sekolah.
5. **Candy CBT (Repositori Komunitas GitHub: `sutam21/candycbt`)**
   - *Kelebihan:* Sangat familiar bagi operator sekolah SMA/SMK di Indonesia (format import soal Excel/Word sudah standar).
   - *Kekurangan:* Arsitektur kode lama (PHP procedural), butuh refactoring jika ingin dijadikan API modern.

---

## 5. Komponen Utama & Alur Kerja v3.0

### A. Tampilan Kuis (Clean Native Flutter UI)
1. **Layar Pemilihan Ujian / Course:**
   - Hanya menampilkan kartu ujian yang dijadwalkan aktif pada hari itu.
   - Informasi jelas: Nama Mapel, Jumlah Soal, Durasi Waktu, Status Pengerjaan.
2. **Layar Pengerjaan Kuis (Distraction-Free):**
   - Header minimalis: Tombol Nomor Soal, Countdown Timer melayang, Indikator Sinyal/Baterai.
   - Area Soal: Teks soal responsif, dukungan gambar perbesaran (*pinch-to-zoom*), dan render rumus matematika (LaTeX).
   - Area Pilihan Jawaban: Desain kartu pilihan A, B, C, D yang luas dan mudah ditekan.
   - Footer: Tombol "Sebelumnya", "Ragu-ragu", "Berikutnya", dan "Selesaikan Ujian".

### B. Mekanisme Semi-Offline (Quiz Engine)
1. **Fase 1: Download & Enkripsi (Pre-Attempt)**
   - Siswa menekan tombol "Mulai Ujian".
   - Aplikasi memanggil endpoint REST: `start_attempt` & download seluruh data soal dalam format JSON.
   - Data disimpan ke dalam database lokal HP (`sqflite` dengan enkripsi SQLCipher / AES-256).
   - Seluruh asset gambar soal diunduh dan di-cache secara lokal.
2. **Fase 2: Pengerjaan Mandiri (Zero Network Dependency)**
   - Siswa menjawab soal dan berpindah halaman secara instan (0 detik loading).
   - Setiap perubahan jawaban langsung tersimpan di database lokal HP.
   - Timer berjalan menggunakan jam internal terproteksi (mencegah manipulasi waktu perangkat).
3. **Fase 3: Sinkronisasi & Upload Jawaban (Post-Attempt)**
   - Saat waktu habis atau siswa menekan "Selesai", aplikasi mengemas seluruh jawaban dalam 1 request batch API.
   - Jika koneksi Wi-Fi sedang padat, jawaban tetap tersimpan aman di HP, dan aplikasi menampilkan tombol *"Kirim Ulang Jawaban"*.

### C. Keamanan & Pengawasan (Hybrid Security)
1. **Local Security Guardian:**
   - Deteksi otomatis tombol Home, Recent Apps, Split Screen, Floating Apps, dan Screenshot.
   - Layar langsung terkunci seketika (Zero Latency) tanpa menunggu perintah server.
2. **Ultralight Heartbeat & Suspend Checker:**
   - Selama pengerjaan, aplikasi mengirim paket data sangat kecil (~150 bytes) setiap 20–30 detik ke server.
   - Mengirim status: Sisa waktu, jumlah pelanggaran lokal, status baterai.
   - Menerima balasan dari server: `action: "ok"` atau `action: "suspend"`.
   - Jika pengawas menekan **Suspend** di Dashboard, HP siswa terkunci dalam beberapa detik.
3. **Data Erasure:**
   - Setelah server mengonfirmasi jawaban tersimpan dan kuis selesai, data soal di memori lokal HP dihapus bersih (*secure wipe*).

---

## 6. Tahapan Pengerjaan (Roadmap Pelaksanaan Pasca Ujian)

| Tahap | Fokus Pekerjaan | Estimasi Waktu |
|---|---|---|
| **Tahap 1** | **Keputusan Backend & API:** Menentukan pilihan backend (Headless Moodle / Custom Go / Fork Laravel CBT) dan menyusun spesifikasi REST API. | 3–5 Hari |
| **Tahap 2** | **Quiz Engine & Local Storage:** Membangun arsitektur SQLite/SQLCipher di Flutter untuk menyimpan attempt soal dan jawaban offline. | 1 Minggu |
| **Tahap 3** | **Native UI/UX:** Mendesain antarmuka kuis bersih di Flutter (Course List $\rightarrow$ Soal $\rightarrow$ Review Jawaban $\rightarrow$ Submit Dialog). | 1 Minggu |
| **Tahap 4** | **Integrasi Keamanan & Heartbeat:** Menghubungkan sistem suspend dashboard pengawas dengan worker heartbeat Flutter. | 4 Hari |
| **Tahap 5** | **Testing & Simulasi Skala Besar:** Uji coba di berbagai varian HP (spek rendah hingga tinggi, Android & iOS), uji coba Wi-Fi mati/hidup. | 5 Hari |
| **Tahap 6** | **Rilis App Store & Play Store:** Pengajuan update resmi v3.0 ke Apple App Store & Google Play Store jauh-jauh hari sebelum jadwal ujian semester berikutnya. | 1–2 Minggu |

---

## 7. Catatan Kesiapan Ujian Tanggal 16 (Status Quo)
- Untuk ujian tanggal **16**, aplikasi **tetap menggunakan versi 2.7.8 yang sudah disetujui di App Store**.
- Server Moodle sudah dioptimalkan (PHP-FPM 160 worker, MariaDB 1000 koneksi, Redis session non-blocking).
- SOP login bertahap (*staggered start*) 3–5 menit antar ruangan wajib diterapkan untuk menjaga stabilitas AP Wi-Fi sekolah.
