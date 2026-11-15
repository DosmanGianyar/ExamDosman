# CLAUDE.md — Panduan Agent & Deployment Dosman Exam

> File ini ikut ter-commit ke Git agar konsisten di semua PC tempat project dikerjakan.

---

## 1. Aturan Sesi (Wajib di Awal & Akhir Sesi)

1. **Awal sesi:** Jalankan `git pull --rebase --autostash` di root repository sebelum membaca/mengedit file.
2. **Akhir sesi:** Commit & `git push origin main` agar PC lain mendapat versi terbaru.

---

## 2. Keamanan & Akses Server Production (Tailscale Only)

- **Akses Jaringan:** Server Moodle **HANYA dapat diakses melalui jaringan pribadi Tailscale** (SSH/SCP tidak dibuka ke internet publik). Pastikan Tailscale di PC dalam keadaan terhubung sebelum melakukan deployment.
- **Kredensial:** Jangan pernah menaruh password SSH atau `sudo` secara *plaintext* di dalam repository Git. Simpan password di environment variable lokal (`$env:DOSMAN_SSH_PW`) atau minta langsung kepada pemilik project saat sesi deploy.

| Parameter | Nilai |
|---|---|
| **Host / IP Tailscale** | `100.119.100.104` |
| **SSH Username** | `dosman` |
| **Owner File Web (Moodle)** | `www:www` |
| **Path Plugin `local_dosman_ujian`** | `/www/wwwroot/moodledosman.test/local/dosman_ujian` |
| **Path Plugin `quizaccess_dosmanexam`** | `/www/wwwroot/moodledosman.test/mod/quiz/accessrule/dosmanexam` |
| **Path Dashboard Pengawas** | `/www/wwwroot/moodledosman.test/dashboard` |

---

## 3. Cara Deploy / Sinkronisasi ke Server Moodle (`pscp` + `plink`)

Karena direktori `/www/wwwroot/moodledosman.test` di server tidak menggunakan `git` langsung di folder root Moodle, deployment file backend (`moodle-plugin/` atau `dashboard/`) dilakukan dengan mengunggah file yang berubah via `pscp` lalu memindahkannya dengan `plink`:

```powershell
# Contoh deploy 1 file PHP ke local/dosman_ujian (pastikan Tailscale aktif & $env:DOSMAN_SSH_PW sudah diset)
$file = "suspend_student.php"
pscp -batch -pw $env:DOSMAN_SSH_PW "moodle-plugin\local\dosman_ujian\$file" "dosman@100.119.100.104:/tmp/$file"
plink -batch -pw $env:DOSMAN_SSH_PW dosman@100.119.100.104 "echo $env:DOSMAN_SSH_PW | sudo -S sh -c 'cp /tmp/$file /www/wwwroot/moodledosman.test/local/dosman_ujian/$file && chown www:www /www/wwwroot/moodledosman.test/local/dosman_ujian/$file && chmod 644 /www/wwwroot/moodledosman.test/local/dosman_ujian/$file && rm -f /tmp/$file && php -l /www/wwwroot/moodledosman.test/local/dosman_ujian/$file'"
```

> **Catatan OPcache:** Server Moodle mengaktifkan OPcache (`revalidate_freq = 60`), sehingga perubahan file PHP otomatis aktif maksimal dalam 60 detik tanpa perlu me-restart PHP-FPM saat ujian berlangsung.
