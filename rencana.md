# Dokumen Rencana & Arsitektur Project Lanjutan: Dosman Exam v3.0
**Target Pengembangan:** Pasca Ujian (Siap Dieksekusi Setelah Periode Ujian Selesai)  
**Strategi Utama (Dual-Mode):**
- **iOS:** Tetap menggunakan mode WebView (`LockedBrowserScreen`) yang sudah stabil dan lolos App Store.
- **Android:** Beralih ke mode **Native Semi-Offline (khusus Pilihan Ganda)** — siswa **hanya butuh sinyal di awal** (download soal) dan **di akhir** (submit jawaban).

---

## 1. Latar Belakang & Keputusan Teknis

### Mengapa Dual-Mode & Fokus Pilihan Ganda?
1. **Seluruh guru menggunakan tipe soal Pilihan Ganda (MCQ):** Ini memangkas kompleksitas parser soal hingga ~80% (tidak perlu menangani esai, menjodohkan, atau drag-and-drop yang rumit).
2. **Bebas Masalah Sinyal Putus di Tengah Ujian:** Saat siswa Android mengerjakan soal, 0 request halaman dikirim ke server. Tidak akan ada lagi layar `ERR_INTERNET_DISCONNECTED` atau siswa bolak-balik meminta password keluar karena Wi-Fi drop sesaat.
3. **Tetap Menggunakan Backend Moodle yang Ada:** Nilai siswa Android (via API) dan siswa iOS (via WebView) sama-sama masuk ke **satu buku nilai Moodle yang sama (`mdl_quiz_attempts` & `mdl_quiz_grades`)**, tanpa perlu melatih ulang guru membuat soal di sistem baru.
4. **Beban Server Turun Drastis:** Server hanya melayani 1x download soal di awal dan 1x submit jawaban di akhir per siswa Android.

---

## 2. Arsitektur Android Semi-Offline (Moodle Web Services)

```
[ Moodle Server (REST API: mod_quiz_*) ]
       │
       │ (1) Fase Awal (Online): start_attempt + get_attempt_data + download gambar
       ▼
┌───────────────────────────────────────────────────────────┐
│                    HP ANDROID SISWA                       │
│                                                           │
│  [ Local Storage Terenkripsi (SQLite / SecureStorage) ]   │
│  - Paket Soal Pilihan Ganda (HTML, slot, sequencecheck)   │
│  - Cache Gambar Soal Lokal                                │
│  - State Jawaban (A–E) & Ragu-ragu                        │
│                                                           │
│  [ Offline Quiz Engine (Flutter) ]                        │
│  - Render Teks + Gambar Lokal + MathJax/KaTeX Offline APK │
│  - Pindah Nomor Soal Instan (0 ms, tanpa internet)        │
│  - Local Countdown Timer + Screen Pinning + Anti-Cheat    │
│                                                           │
│  [ Background Telemetry Worker ]                          │
│  - Ping ringan app_ping.php (kirim quizid ke pengawas)    │
└───────────────────────────────────────────────────────────┘
       │
       │ (2) Fase Akhir (Online): process_attempt (finishattempt=1)
       ▼
[ Buku Nilai Moodle Server ]
(Jika Wi-Fi putus saat submit → Auto-Retry setiap 5 detik; jawaban tetap aman di HP)
```

---

## 3. Alur Teknis Detail (3 Fase)

### Fase 1: Download Paket Soal Saat Start Kuis (Online di Awal)
1. Siswa Android login $\rightarrow$ masuk ke [`CourseListScreen`](file:///c:/Users/dosman/Projects/exam/mobile/lib/screens/course_list_screen.dart) $\rightarrow$ memilih kuis di [`QuizListScreen`](file:///c:/Users/dosman/Projects/exam/mobile/lib/screens/quiz_list_screen.dart). *(Pada tahap ini belum ada soal yang diunduh agar keamanan soal terjaga dan server tidak terbebani sebelum siswa benar-benar memulai).*
2. Proses download soal **baru berjalan tepat ketika siswa menekan tombol "Mulai Ujian" (Start Quiz)** — setelah validasi jadwal buka dan password kuis (jika ada):
   - Cek attempt aktif dengan `mod_quiz_get_user_attempts` (jika ada status `inprogress`, gunakan `attemptid` tersebut untuk melanjutkan; jika paket soal belum ada di HP, unduh ulang).
   - Jika belum ada attempt, panggil `mod_quiz_start_attempt`.
   - Tampilkan progress bar unduhan (*"Mengunduh paket soal..."*) sambil mengambil seluruh halaman soal lewat `mod_quiz_get_attempt_data`.
3. **Ekstraksi Soal Pilihan Ganda:**
   - Dari HTML `question.html` tiap slot, ekstrak:
     - Teks/HTML pertanyaan (pertahankan tag format, tabel, dan LaTeX `\(...\)`).
     - Daftar opsi pilihan ganda (`name`, `value` 0–4, label teks/HTML opsi A–E).
     - `sequencecheck` (`name="q{usageid}:{slot}_:sequencecheck"`).
   - Unduh seluruh gambar (`<img src=".../pluginfile.php/...">`) menggunakan token siswa dan simpan ke direktori lokal HP agar gambar tetap tampil saat offline.
4. Simpan paket soal terenkripsi ke database lokal HP (`sqflite`).

### Fase 2: Pengerjaan Soal (100% Offline di HP)
1. **Renderer Soal & LaTeX Offline:**
   - Sertakan bundel ringan **MathJax/KaTeX langsung di dalam aset APK Android** (`assets/katex/` atau `assets/mathjax/`).
   - Soal dirender cepat secara lokal tanpa internet, mendukung rumus matematika/kimia dan gambar lokal.
2. **Navigasi & Penyimpanan Instan:**
   - Tombol nomor soal (panel grid nomor), tombol **Ragu-ragu**, **Sebelumnya**, **Berikutnya**, dan **Timer Countdown**.
   - Setiap siswa memilih jawaban A–E, langsung tersimpan ke `sqflite` lokal (aman meskipun baterai habis atau aplikasi tertutup).
3. **Keamanan & Monitoring Pengawas:**
   - *Screen Pinning* (`LockTask`), deteksi split-screen, Bluetooth audio, dan timeout background 10 detik tetap berjalan penuh secara lokal.
   - Worker latar belakang tetap mengirim `app_ping.php` (menyertakan `quizid` aktif agar Dashboard Pengawas tetap melihat siswa sedang mengerjakan kuis; jika sinyal putus sementara, layar soal siswa **tidak terganggu**).

### Fase 3: Submit Jawaban Batch (Online di Akhir)
1. Ketika siswa klik **"Selesai & Kirim Jawaban"** (atau timer lokal habis):
   - Kemas seluruh jawaban lokal ke dalam parameter `data` untuk endpoint `mod_quiz_process_attempt` dengan `finishattempt = 1`.
2. **Perlindungan Anti-Gagal Submit:**
   - Jika koneksi Wi-Fi sedang putus pada detik submit:
     - Jawaban **tidak dihapus**.
     - Layar menampilkan status **"Menunggu Sinyal untuk Mengirim Jawaban..."** dan melakukan *auto-retry* otomatis setiap 5 detik sampai server membalas sukses (`state = finished`).
   - Setelah server mengonfirmasi tersimpan, bersihkan cache soal lokal dari HP dan tampilkan ringkasan selesai ujian.

---

## 4. Penyesuaian Server Moodle (Minimal, Tanpa Ganti Backend)
1. Pastikan service `moodle_mobile_app` aktif dan role `student` memiliki izin webservice untuk `mod_quiz_start_attempt`, `mod_quiz_get_attempt_data`, `mod_quiz_process_attempt`, dan `mod_quiz_get_user_attempts`.
2. Pada pengaturan setiap Quiz di Moodle: aktifkan opsi **"Allow quiz to be attempted offline using the mobile app"** (atau pastikan tidak ada pembatasan offline di access rule).
3. Tambah parameter opsional `quizid` pada [`app_ping.php`](file:///c:/Users/dosman/Projects/exam/moodle-plugin/local/dosman_ujian/app_ping.php) agar status `current_quizid` siswa Android tetap terpantau real-time di Dashboard Pengawas meskipun tidak membuka halaman web Moodle.

---

## 5. Roadmap Eksekusi (Estimasi: 10–14 Hari Kerja)

| Tahap | Fokus Pekerjaan | Estimasi |
|---|---|---|
| **Tahap 1** | **Moodle API & Downloader:** Uji coba endpoint `mod_quiz_*` di server live, buat downloader soal + gambar lokal + parser Pilihan Ganda + enkripsi `sqflite`. | 3–4 Hari |
| **Tahap 2** | **Offline Quiz UI & LaTeX Lokal:** Buat `OfflineQuizScreen` (grid nomor soal, opsi A–E, ragu-ragu, timer lokal) + integrasi KaTeX/MathJax offline di aset APK. | 3–4 Hari |
| **Tahap 3** | **Batch Submit & Auto-Retry:** Implementasi `mod_quiz_process_attempt` (`finishattempt=1`), mekanisme auto-retry saat sinyal putus, dan update `app_ping.php` (`quizid`). | 2–3 Hari |
| **Tahap 4** | **Uji Coba & Simulasi:** Tes end-to-end dengan soal bergambar + LaTeX, tes matikan Wi-Fi saat mengerjakan lalu nyalakan lagi saat submit, dan verifikasi nilai masuk di Gradebook Moodle. | 2–3 Hari |

---

## 6. Kompatibilitas Masa Transisi (Multi-Versi Berjalan Bersamaan)

Karena di lapangan selalu ada kemungkinan sebagian siswa belum memperbarui APK Android mereka, arsitektur ini **dirancang agar semua versi tetap bisa ujian bersamaan di 1 server Moodle yang sama**:
1. **Android APK Versi Lama (WebView Online):** Tetap berjalan normal via `/mod/quiz/attempt.php` tanpa terganggu.
2. **Android APK Versi Baru (Semi-Offline):** Mengunduh paket soal saat klik *Start Quiz* dan mengirim jawaban akhir via `mod_quiz_process_attempt`.
3. **iOS App (WebView Online):** Tetap berjalan normal via `LockedBrowserScreen`.
4. **Satu Buku Nilai & Satu Dashboard Pengawas:** Seluruh hasil nilai masuk ke `mdl_quiz_attempts` & `mdl_quiz_grades` yang sama, serta seluruh siswa tetap terpantau dan bisa di-*suspend* dari satu Dashboard Pengawas yang sama melalui `app_ping.php` dan `suspend_student.php`.


---

## 7. Rencana Lanjutan: Auto-Lock iOS Seperti SEB (`AEAssessmentSession`) + Auto-Unlock (Durasi Kuis Moodle + 2 Menit)

**Status:** Menunggu pengajuan & persetujuan Apple Entitlement (`com.apple.developer.automatic-assessment-configuration`).  
**Tujuan:** Siswa iOS **tidak perlu lagi mengaktifkan Akses Terpadu (Guided Access) secara manual**, karena aplikasi otomatis mengunci layar saat ujian dimulai (seperti Safe Exam Browser / SEB) dan **otomatis membuka kunci** setelah waktu kuis Moodle habis + 2 menit cadangan.

### Aturan Durasi Penguncian Otomatis
- **Sumber waktu:** Mengikuti langsung pengaturan waktu kuis di Moodle (`timelimit` / sisa waktu attempt siswa `_remainingSec`).
- **Formula:**
  $$\text{Durasi Kunci} = \text{Sisa Waktu Kuis Moodle} + 2\text{ menit (120 detik)}$$
  - Contoh: Jika durasi kuis di Moodle **120 menit**, maka aplikasi terkunci maksimal **122 menit** lalu otomatis terbuka sendiri.
  - Jika kuis tidak memiliki `timelimit` (`0`), gunakan fallback `timeclose - sekarang + 2 menit` (atau default aman 122 menit).
  - Jika siswa **menyelesaikan & mengirim jawaban lebih cepat** atau **guru memasukkan password keluar**, kunci layar tetap bisa langsung dilepas lebih awal tanpa menunggu timer habis.
- **Berlaku konsisten untuk iOS & Android:** Timer auto-unlock (`durasi kuis + 2 menit`) diterapkan baik pada `AEAssessmentSession.end()` (iOS) maupun `stopLockTask()` (Android) sebagai *failsafe* agar HP siswa tidak pernah terjebak terkunci.

### Alur Pengerjaan (Step-by-Step)

1. **Tahap 1 — Pengajuan Entitlement Resmi ke Apple (Prasyarat)**
   - Pemilik akun (**Account Holder**) Apple Developer mengajukan permohonan di:  
     `https://developer.apple.com/contact/request/automatic-assessment-configuration/`
   - Data utama: App Name `EXAM DOSMAN`, Bundle ID `com.sman1-gianyar.examdosman`, Platform `iOS / iPadOS`, Institusi `SMA Negeri 1 Gianyar`.
   - Tunggu email persetujuan dari Apple (estimasi 3–14 hari kerja).

2. **Tahap 2 — Aktivasi Capability di Apple Developer Portal & Codemagic**
   - Masuk ke **Apple Developer Portal → Certificates, Identifiers & Profiles → Identifiers → `com.sman1-gianyar.examdosman`**.
   - Aktifkan entitlement **Automatic Assessment Configuration** lalu simpan.
   - Regenerate Provisioning Profile App Store (di Codemagic cukup jalankan build ulang karena `app-store-connect fetch-signing-files` otomatis mengambil profile terbaru).

3. **Tahap 3 — Implementasi Kode Native & Flutter**
   - **Entitlements iOS:** Buat/update `mobile/ios/Runner/Runner.entitlements` dengan:
     - `com.apple.developer.automatic-assessment-configuration` = `true`.
   - **Native iOS (`mobile/ios/Runner/AppDelegate.swift`):**
     - Import `AutomaticAssessmentConfiguration` (iOS 13.4+).
     - Saat menerima `enterLockTask` / `startAssessmentSession(durationSeconds)`:
       - Buat `AEAssessmentConfiguration()` (batasi switch app, autocorrect, spellcheck, predictive keyboard, dictionary, screen capture).
       - Jalankan `AEAssessmentSession(configuration: config).begin()`.
       - Pasang timer native (`DispatchSourceTimer` / `Timer`) selama `durationSeconds` (`sisa waktu kuis Moodle + 120 detik`).
       - Saat timer habis → otomatis panggil `session.end()` agar layar terbuka normal.
     - Saat menerima `exitLockTask` / `disableLockdown` (selesai ujian atau password keluar) → batalkan timer dan panggil `session.end()`.
     - Simpan fallback deteksi Guided Access bila perangkat iOS tidak mendukung AAC.
   - **Flutter (`mobile/lib/screens/offline_quiz_screen.dart` & `kiosk_controller.dart`):**
     - Hitung `lockDurationSec = _remainingSec + 120` tepat setelah paket soal & durasi kuis Moodle selesai diunduh, lalu kirim ke native (`startAssessmentTimer` / `enterLockTask`).
     - Terapkan juga timer auto-unlock yang sama pada Android (`MainActivity.kt` → `stopLockTask()`) saat `lockDurationSec` tercapai.

4. **Tahap 4 — Pengujian via TestFlight & Rilis App Store**
   - Trigger workflow **iOS Build & TestFlight** di Codemagic (`codemagic.yaml`).
   - Uji langsung di iPhone/iPad menggunakan kuis uji coba (mis. durasi 3 menit di Moodle):
     1. Masuk ujian → pastikan iPhone langsung terkunci otomatis **tanpa** aktifkan Akses Terpadu manual.
     2. Cek tidak bisa keluar app / swipe home / buka aplikasi lain.
     3. Biarkan sampai 3 menit + 2 menit (5 menit) → pastikan kunci **otomatis lepas sendiri**.
     4. Uji selesai lebih cepat / keluar dengan password → pastikan kunci langsung lepas.
   - Jika seluruh skenario lolos → submit build ke App Store Review dan rilis untuk seluruh siswa iOS.
