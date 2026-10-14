# DOSMAN UJIAN — Dokumentasi Proyek & Standar Tim

**⚠️ Catatan Penting (v1.5.0):** Fitur pemblokiran siswa telah dihapus dan diganti dengan automatic suspend akun Moodle. Semua endpoint dan UI terkait blocking sudah dihapus dari plugin, dashboard, dan mobile.

Dokumen ini adalah acuan tunggal untuk pengembangan `mobile` (Flutter), `dashboard` (Web JS), dan `moodle-plugin` (PHP Moodle) agar:
- tidak terjadi perbedaan gaya bahasa kode antar developer,
- semua orang paham alur sistem end-to-end,
- integrasi API tidak putus saat ada perubahan.

## 1) Ringkasan Sistem

Komponen utama:
- `mobile/`: aplikasi siswa (Flutter Android) untuk exam browser + lockdown.
- `dashboard/`: web dashboard guru/admin untuk monitoring, aksi sesi, dan konfigurasi.
- `moodle-plugin/local/dosman_ujian/`: backend API custom di Moodle.

Arsitektur komunikasi:
- `mobile` → Moodle REST (`server.php`) via service `dosman_ujian_mobile`.
- `dashboard` → `proxy.php` → Moodle REST (`server.php`).
- sumber data utama ada di plugin Moodle (tabel sesi, log, dan config).

## 2) Struktur Direktori yang Wajib Dipahami

```text
dosman-ujian-project/
├── mobile/
│   ├── lib/
│   │   ├── config/         # Konstanta app (URL, channel, fallback)
│   │   ├── models/         # Data model hasil API
│   │   ├── services/       # Layer akses API
│   │   ├── screens/        # UI per halaman
│   │   └── widgets/        # Komponen UI reusable
│   └── android/            # Native bridge MethodChannel (lockdown Android)
├── dashboard/
│   ├── index.html
│   ├── login.html
│   ├── proxy.php
│   ├── appstatus.php
│   ├── pwd.php
│   ├── test.html
│   └── js/
│       ├── auth.js
│       ├── api.js
│       ├── config.js
│       ├── dashboard.js
│       ├── exitpwd.js
│       ├── login_status.js
│       └── sebpwd.js
└── moodle-plugin/
    └── local/dosman_ujian/
        ├── version.php
        ├── db/services.php
        ├── db/install.xml
        ├── db/upgrade.php
        └── classes/external/*.php
```

## 3) Standar Bahasa Kode (WAJIB DIKUTI TIM)

### 3.1 Bahasa komentar, variable, function
- Nama symbol kode (`function`, `class`, variable): **bahasa Inggris**.
- Komentar teknis pendek: **bahasa Indonesia** boleh, tapi konsisten per file.
- Teks UI untuk user/guru: **bahasa Indonesia**.

Contoh benar:
- `verifyExitPassword`, `getClientConfig`, `sessionFetchError`
- UI: `"Password admin diperlukan"`

### 3.2 Naming convention per layer
- Flutter/Dart:
  - file: `snake_case.dart`
  - class/enum: `PascalCase`
  - variable/method: `camelCase`
  - private state: prefix `_`
- JavaScript dashboard:
  - object global: `PascalCase` (`Dashboard`, `API`, `Auth`)
  - method/variable: `camelCase`
  - konstanta map: `UPPER_SNAKE_CASE` jika benar-benar constant
- PHP Moodle plugin:
  - class external: `snake_case.php` sesuai function
  - function WS: `local_dosman_ujian_<action>`
  - parameter REST: `snake_case`

### 3.3 Aturan endpoint dan response
- Semua endpoint custom harus return struktur stabil:
  - minimal `success` + `message` (jika aksi),
  - atau object data dengan field wajib terdokumentasi.
- Jangan ubah nama field response tanpa update:
  - `mobile/lib/models/*`
  - `dashboard/js/*` yang konsumsi field tersebut
  - dokumen ini (bagian kontrak API)

## 4) Alur Bisnis Utama (End-to-End)

### 4.1 Alur siswa (mobile)
1. Login Moodle (`token.php`) lalu verifikasi user.
2. Pilih course dan quiz.
3. Masuk `ExamScreen`:
   - register session,
   - aktifkan lockdown,
   - load quiz di WebView,
   - heartbeat berkala.
4. Keluar kuis:
   - siswa input password admin,
   - password diverifikasi ke server (`verify_exit_password`),
   - jika valid baru kirim `request_exit` ke guru.

### 4.2 Alur guru/admin (dashboard)
1. Login dashboard.
2. Pilih course dan quiz.
3. Monitor sesi live + log.
4. Aksi sesi (`pause/resume/reset/approve_exit/reject_exit`).
5. Admin dapat ubah password keluar di panel monitor:
   - load config (`get_client_config`)
   - simpan config (`set_client_config`).

## 5) Kontrak API (Custom Web Service)

Service: `dosman_ujian_mobile`

### 5.1 Endpoint Web Service (Moodle External Functions)

- `local_dosman_ujian_register_session`
- `local_dosman_ujian_heartbeat`
- `local_dosman_ujian_log_activity`
- `local_dosman_ujian_request_exit`
- `local_dosman_ujian_get_exam_status`
- `local_dosman_ujian_get_sessions`
- `local_dosman_ujian_get_logs`
- `local_dosman_ujian_manage_session`
- `local_dosman_ujian_get_client_config` (admin)
- `local_dosman_ujian_set_client_config` (admin)
- `local_dosman_ujian_verify_exit_password` (siswa, validasi server-side)

### 5.2 Endpoint PHP Langsung (Direct PHP Files)

File-file ini dipanggil langsung via HTTP (bukan via Moodle WS):

| Endpoint | Deskripsi |
|----------|----------|
| `app_ping.php` | Ping dari mobile app untuk koneksi |
| `browser_heartbeat.php` | Heartbeat dari browser/webview |
| `exitpwd.php` | Endpoint password keluar (verifikasi) |
| `force_logout_student.php` | Paksa logout siswa |
| `getseblog.php` | Ambil log SEB (Safe Exam Browser) |
| `getsebpwd.php` | Ambil password SEB |
| `getsebqr.php` | Ambil QR code SEB |
| `get_app_users.php` | Ambil daftar user app |
| `get_suspended_students.php` | Ambil daftar siswa disuspend |
| `sebconfig.php` | Konfigurasi SEB |
| `setpwd.php` | Set password admin |
| `setsebpwd.php` | Set password SEB |
| `set_lock_status.php` | Set status lock/unlock |
| `suspend_student.php` | Suspend siswa |
| `unsuspend_student.php` | Unsuspend siswa |
| `web_heartbeat.php` | Heartbeat dari web exam |

Catatan integrasi:
- `get_client_config` dan `set_client_config` untuk dashboard/admin.
- mobile tidak lagi menarik password mentah dari server; mobile memakai `verify_exit_password`.

## 6) Sumber Kebenaran Data (Source of Truth)

- Status sesi dan pelanggaran: DB plugin Moodle.
- Password keluar kuis: config plugin `local_dosman_ujian` key `admin_exit_password`.
- Fallback mobile (`AppConfig.adminExitPassword`) hanya darurat jika endpoint server belum tersedia.

## 7) SOP Perubahan Kode (Agar Tim Tidak Beda Gaya)

Setiap perubahan wajib mengikuti urutan:
1. Tentukan layer terdampak: `mobile`, `dashboard`, `plugin`.
2. Jika ubah API plugin:
   - update `classes/external/*.php`
   - update `db/services.php`
   - bump `version.php`
   - jalankan upgrade Moodle.
3. Sinkronkan consumer:
   - `dashboard/js/api.js`
   - `mobile/lib/services/*.dart`
4. Uji manual minimal:
   - login dashboard,
   - start monitoring,
   - start ujian di mobile,
   - heartbeat/live status,
   - flow izin keluar + password.
5. Perbarui dokumen ini (jika ada perubahan kontrak/alur).

## 8) Checklist Review PR/Internal

Sebelum merge:
- [ ] Tidak ada endpoint yang di-rename tanpa migrasi.
- [ ] Penamaan function/variable sesuai standar section 3.
- [ ] Tidak ada hardcoded secret baru.
- [ ] `version.php` di-bump jika plugin berubah.
- [ ] Dashboard dan mobile tetap kompatibel dengan response plugin terbaru.
- [ ] Uji skenario “salah password keluar” dan “benar password keluar”.

## 9) Konfigurasi Server Penting

- Domain: `https://dosman.site`
- Moodle REST endpoint: `/webservice/rest/server.php`
- Dashboard: `/dashboard/`
- Plugin path: `/local/dosman_ujian/`

Prasyarat Moodle:
- Web service aktif.
- REST protocol aktif.
- Service `dosman_ujian_mobile` aktif.
- Role/capability guru/admin sesuai kebutuhan monitoring.

## 10) Catatan Versi (Saat Dokumen Ini Diperbarui)

- Plugin release: `1.5.0`
- Plugin version: `2026042800`
- Mobile: Flutter app aktif Android exam mode (blocking features removed, use suspend instead)
- Dashboard: sudah ada panel ubah password keluar, SEB password management

---

Dokumen ini harus diperbarui setiap ada perubahan kontrak API, alur bisnis, atau aturan coding tim.
