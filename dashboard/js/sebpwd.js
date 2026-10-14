// ============================================================
// SEB PASSWORD (iOS) — manajemen password quit SEB dari dashboard
// ============================================================

function _escHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Konversi YYYY-MM-DD → format Indonesia, contoh: "1 Mei 2026"
function _formatDateID(dateStr) {
  var months = ['Januari','Februari','Maret','April','Mei','Juni',
                'Juli','Agustus','September','Oktober','November','Desember'];
  var parts = String(dateStr).split('-');
  if (parts.length !== 3) return dateStr;
  var d = parseInt(parts[2], 10);
  var m = parseInt(parts[1], 10) - 1;
  if (isNaN(d) || m < 0 || m > 11) return dateStr;
  return d + ' ' + months[m] + ' ' + parts[0];
}

var SebPwd = {
  _showing: false,

  load: function () {
    var inp = document.getElementById('seb-input');
    var sts = document.getElementById('seb-status');
    if (!inp || !sts) return;
    sts.style.color = '#6b7280';
    sts.textContent = 'Memuat…';
    var token = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : '';
    fetch('../local/dosman_ujian/getsebpwd.php?token=' + encodeURIComponent(token), { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (typeof d.password !== 'string') throw new Error(d.error || 'Format tidak valid');
        inp.value = d.password;
        SebPwd._updateStatus(d.password);
      })
      .catch(function (e) {
        sts.style.color = '#dc2626';
        sts.textContent = 'Gagal memuat: ' + e.message;
      });
  },

  _updateStatus: function (pwd) {
    var sts = document.getElementById('seb-status');
    if (!sts) return;
    if (pwd === '') {
      sts.style.color  = '#d97706';
      sts.textContent  = 'Belum ada password — iPad dapat quit SEB tanpa konfirmasi.';
    } else {
      sts.style.color  = '#16a34a';
      sts.textContent  = 'Password aktif: ' + pwd.length + ' karakter. Config URL sudah reflect perubahan.';
    }
  },

  toggle: function () {
    var inp = document.getElementById('seb-input');
    var btn = document.getElementById('seb-toggle');
    if (!inp) return;
    this._showing = !this._showing;
    inp.type      = this._showing ? 'text' : 'password';
    if (btn) {
      btn.innerHTML = this._showing ? '&#x1F648;' : '&#x1F441;';
      btn.title     = this._showing ? 'Sembunyikan' : 'Tampilkan';
    }
  },

  generate: function () {
    var inp = document.getElementById('seb-input');
    var sts = document.getElementById('seb-status');
    if (!inp) return;
    var digits        = Math.floor(100000 + Math.random() * 900000).toString();
    inp.value         = digits;
    inp.type          = 'text';
    this._showing     = true;
    var btn = document.getElementById('seb-toggle');
    if (btn) { btn.innerHTML = '&#x1F648;'; btn.title = 'Sembunyikan'; }
    if (sts) {
      sts.style.color = '#2563eb';
      sts.textContent = 'Password digenerate: ' + digits + ' — klik Simpan untuk menyimpan.';
    }
  },

  generateAndSave: function () {
    this.generate();
    this.save();
  },

  clear: function () {
    var inp = document.getElementById('seb-input');
    var sts = document.getElementById('seb-status');
    if (!inp) return;
    inp.value         = '';
    inp.type          = 'text';
    this._showing     = true;
    var btn = document.getElementById('seb-toggle');
    if (btn) { btn.innerHTML = '&#x1F648;'; btn.title = 'Sembunyikan'; }
    if (sts) {
      sts.style.color = '#d97706';
      sts.textContent = 'Input dikosongkan — klik Simpan untuk menghapus password.';
    }
    inp.focus();
  },

  save: function () {
    var inp = document.getElementById('seb-input');
    var sts = document.getElementById('seb-status');
    if (!inp || !sts) return;
    var val = inp.value;
    if (val !== '' && val.length < 4) {
      sts.style.color = '#dc2626';
      sts.textContent = 'Password minimal 4 karakter, atau kosongkan.';
      return;
    }
    var token = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : '';
    sts.style.color = '#6b7280';
    sts.textContent = 'Menyimpan…';
    fetch('../local/dosman_ujian/setsebpwd.php', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ token: token, password: val })
    })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.success) {
          inp.value = val;
          sts.style.color = '#16a34a';
          sts.textContent = val === ''
            ? '✓ Password dihapus — iPad dapat quit tanpa konfirmasi.'
            : '✓ Disimpan: ' + val.length + ' karakter — aktif di SEB mulai launch berikutnya.';
        } else {
          sts.style.color = '#dc2626';
          sts.textContent = '✗ ' + (d.message || 'Gagal menyimpan.');
        }
      })
      .catch(function (e) {
        sts.style.color = '#dc2626';
        sts.textContent = '✗ Error: ' + e.message;
      });
  },

  downloadStarter: function () {
    var launchInput = document.getElementById('seb-qr-url');
    var launchUrl = launchInput ? (launchInput.value || '').trim() : '';
    if (!launchUrl) {
      var sts = document.getElementById('seb-status');
      if (sts) {
        sts.style.color = '#dc2626';
        sts.textContent = 'Generate Barcode SEB dulu, baru download config starter.';
      }
      return;
    }
    var xml = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"',
      '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0">',
      '<dict>',
      '    <!-- Fallback URL jika fetch sebConfigURL gagal -->',
      '    <key>startURL</key>',
      '    <string>https://lms.sman1-gianyar.sch.id:9443/login/index.php</string>',
      '    <!-- Suffix UA resmi SEB (bukan browserUserAgentiOS) agar Moodle mengenali iOS -->',
      '    <key>browserUserAgent</key>',
      '    <string> ExamDosmanIOS</string>',
      '    <!-- SEB akan fetch config lengkap (termasuk password quit) dari URL ini -->',
      '    <key>sebConfigURL</key>',
      '    <string>' + launchUrl + '</string>',
      '</dict>',
      '</plist>'
    ].join('\n');

    var blob = new Blob([xml], { type: 'application/seb' });
    var url  = URL.createObjectURL(blob);
    var a    = document.createElement('a');
    a.href     = url;
    a.download = 'dosman_exam_starter.seb';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }
};

document.addEventListener('DOMContentLoaded', function () {
  SebPwd.load();
  SebLog.load();
  SebQRHistory.load();
});

// ── Barcode QR SEB per judul ──────────────────────────────────────────────────
var SebQR = {
  generate: function () {
    var token    = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : '';
    var warnSts  = document.getElementById('seb-status');   // selalu terlihat
    var status   = document.getElementById('seb-qr-status');
    var titleEl  = document.getElementById('seb-qr-title');
    var dateEl   = document.getElementById('seb-qr-exam-date');

    var title    = titleEl ? titleEl.value.trim() : '';
    var examDate = dateEl  ? dateEl.value.trim()  : '';

    // Normalisasi untuk pengecekan duplikat (cocokkan dengan apa yang server simpan)
    var checkTitle = (title === '' ? 'Ujian SEB' : title).toLowerCase();
    var today      = new Date();
    var checkDate  = examDate !== '' ? examDate
      : today.getFullYear() + '-'
        + String(today.getMonth() + 1).padStart(2, '0') + '-'
        + String(today.getDate()).padStart(2, '0');

    // Blok keras — judul+tanggal yang sama tidak boleh dibuat ulang
    var isDupe = SebQRHistory._data.some(function (e) {
      return (e.title || '').toLowerCase() === checkTitle && e.date === checkDate;
    });

    if (isDupe) {
      if (warnSts) {
        warnSts.style.color = '#dc2626';
        warnSts.textContent = '✗ QR “' + (title || 'Ujian SEB') + '” untuk tanggal ini sudah ada.'
          + ' Gunakan judul berbeda atau pilih tanggal lain.';
      }
      return;
    }

    // Bersihkan pesan error duplikat jika ada
    if (warnSts && warnSts.textContent.charAt(0) === '✗') warnSts.textContent = '';

    if (status) {
      status.style.color = '#6b7280';
      status.textContent = 'Membuat barcode...';
    }

    var url = '../local/dosman_ujian/getsebqr.php?token=' + encodeURIComponent(token);
    if (title)    url += '&title='     + encodeURIComponent(title);
    if (examDate) url += '&exam_date=' + encodeURIComponent(examDate);

    fetch(url, { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (!d.launch_url || !d.qr_image_url) {
          throw new Error(d.error || 'Format respons tidak valid');
        }
        var wrap    = document.getElementById('seb-qr-wrap');
        var img     = document.getElementById('seb-qr-img');
        var inp     = document.getElementById('seb-qr-url');
        var titleDp = document.getElementById('seb-qr-title-display');
        var dateDp  = document.getElementById('seb-qr-date-display');
        if (wrap)    wrap.style.display = 'block';
        if (img)     img.src = d.qr_image_url;
        if (inp)     inp.value = d.launch_url;
        if (titleDp) titleDp.textContent = d.title || '';
        if (dateDp)  dateDp.textContent  = d.date  || '';
        if (status) {
          status.style.color = '#16a34a';
          status.textContent = 'Barcode siap — password tersimpan permanen untuk QR ini.';
        }
        SebQRHistory.load();
      })
      .catch(function (e) {
        if (status) {
          status.style.color = '#dc2626';
          status.textContent = 'Gagal membuat barcode: ' + e.message;
        }
      });
  },

  copyUrl: function () {
    var inp    = document.getElementById('seb-qr-url');
    var status = document.getElementById('seb-qr-status');
    if (!inp || !inp.value) return;

    var done = function () {
      if (status) {
        status.style.color = '#2563eb';
        status.textContent = 'URL barcode disalin.';
      }
    };

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(inp.value).then(done).catch(function () {
        inp.select(); document.execCommand('copy'); done();
      });
      return;
    }
    inp.select();
    document.execCommand('copy');
    done();
  },

  // entry: { qr_image_url, launch_url, title, date } — jika null, baca dari DOM
  printQr: function (entry) {
    var qrSrc, launchUrl, title, date, status;

    if (entry && entry.qr_image_url) {
      qrSrc     = entry.qr_image_url;
      launchUrl = entry.launch_url || entry.url || '';
      title     = entry.title || '';
      date      = entry.date  || '';
    } else {
      var img    = document.getElementById('seb-qr-img');
      var urlEl  = document.getElementById('seb-qr-url');
      var titleDp = document.getElementById('seb-qr-title-display');
      var dateDp  = document.getElementById('seb-qr-date-display');
      status    = document.getElementById('seb-qr-status');
      qrSrc     = img   ? (img.src    || '').trim() : '';
      launchUrl = urlEl ? (urlEl.value || '').trim() : '';
      title     = titleDp ? (titleDp.textContent || '') : '';
      date      = dateDp  ? (dateDp.textContent  || '') : '';
      if (!qrSrc || !launchUrl) {
        if (status) {
          status.style.color = '#dc2626';
          status.textContent = 'Generate barcode dulu sebelum cetak.';
        }
        return;
      }
    }

    var printWin = window.open('', '_blank', 'width=960,height=720');
    if (!printWin) {
      if (status) {
        status.style.color = '#dc2626';
        status.textContent = 'Popup diblokir browser. Izinkan popup lalu coba cetak lagi.';
      }
      return;
    }

    var safeUrl   = _escHtml(launchUrl);
    var safeTitle = title ? '<div class="exam-title">' + _escHtml(title) + '</div>' : '';
    var safeDate  = date  ? '<div class="exam-date">'  + _escHtml(date)  + '</div>' : '';

    var html = [
      '<!DOCTYPE html>',
      '<html lang="id"><head><meta charset="UTF-8"><title>Cetak QR SEB</title>',
      '<style>',
      '@page { size: A4 portrait; margin: 12mm; }',
      'html, body { margin: 0; padding: 0; font-family: Arial, sans-serif; background: #fff; color: #111827; }',
      '.sheet { width: 186mm; min-height: 273mm; margin: 0 auto; display: flex; flex-direction: column; align-items: center; }',
      '.title { font-size: 28px; font-weight: 700; margin-top: 8mm; text-align: center; }',
      '.subtitle { font-size: 16px; color: #374151; margin-top: 4mm; text-align: center; }',
      '.exam-title { font-size: 22px; font-weight: 600; color: #1e3a5f; margin-top: 6mm; text-align: center; }',
      '.exam-date { font-size: 14px; color: #6b7280; margin-top: 3mm; text-align: center; }',
      '.qr-wrap { margin-top: 10mm; width: 170mm; height: 170mm; border: 2px solid #111827; display: flex; align-items: center; justify-content: center; }',
      '.qr-wrap img { width: 166mm; height: 166mm; object-fit: contain; }',
      '.hint { margin-top: 10mm; font-size: 15px; text-align: center; color: #4b5563; }',
      '.url { margin-top: 4mm; font-size: 11px; color: #6b7280; word-break: break-all; text-align: center; max-width: 180mm; }',
      '@media print { .sheet { page-break-after: always; } }',
      '</style></head><body>',
      '<div class="sheet">',
      '<div class="title">QR Safe Exam Browser</div>',
      '<div class="subtitle">Dosman Exam &mdash; SMAN 1 Gianyar</div>',
      safeTitle,
      safeDate,
      '<div class="qr-wrap"><img src="' + qrSrc + '" alt="QR SEB"></div>',
      '<div class="hint">Scan QR ini menggunakan aplikasi Safe Exam Browser (SEB) iOS di iPad.</div>',
      '<div class="url">' + safeUrl + '</div>',
      '</div>',
      '<script>window.onload = function(){ window.focus(); window.print(); }<\/script>',
      '</body></html>'
    ].join('');

    printWin.document.open();
    printWin.document.write(html);
    printWin.document.close();
  }
};

// ── Riwayat QR SEB ────────────────────────────────────────────────────────────
var SebQRHistory = {
  _data:  [],
  _shown: {},   // id -> true jika password terlihat

  load: function () {
    var tbody = document.getElementById('seb-qr-history-body');
    var token = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : '';

    fetch('../local/dosman_ujian/getsebqrlist.php?token=' + encodeURIComponent(token), { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        SebQRHistory._data = Array.isArray(d.history) ? d.history : [];
        SebQRHistory.render();
      })
      .catch(function () {
        if (tbody) {
          tbody.innerHTML = '<tr><td colspan="5" style="padding:16px;text-align:center;color:#dc2626">Gagal memuat riwayat.</td></tr>';
        }
      });
  },

  render: function () {
    var tbody = document.getElementById('seb-qr-history-body');
    if (!tbody) return;
    var data = this._data;
    if (!data.length) {
      tbody.innerHTML = '<tr><td colspan="5" style="padding:16px;text-align:center;color:#9ca3af;font-size:13px">Belum ada QR digenerate.</td></tr>';
      return;
    }
    tbody.innerHTML = data.map(function (entry, i) {
      var id      = entry.id || '';
      var title   = _escHtml(entry.title || '-');
      var date    = _escHtml(entry.date ? _formatDateID(entry.date) : '-');
      var pwd     = entry.pwd || '';
      var shown   = !!SebQRHistory._shown[id];
      var pwdCell = shown
        ? '<span style="font-family:monospace;letter-spacing:1px">' + _escHtml(pwd) + '</span>'
        : '<span style="color:#9ca3af">' + (pwd ? '••••••••' : '(kosong)') + '</span>';
      var eyeIcon = shown ? '&#x1F648;' : '&#x1F441;';
      var bg = i % 2 === 0 ? '#fff' : '#f9fafb';
      return '<tr style="background:' + bg + '">'
        + '<td style="padding:7px 10px;color:#9ca3af;text-align:center">' + (i + 1) + '</td>'
        + '<td style="padding:7px 10px;font-weight:500">' + title + '</td>'
        + '<td style="padding:7px 10px;white-space:nowrap">' + date + '</td>'
        + '<td style="padding:7px 10px">' + pwdCell + '</td>'
        + '<td style="padding:6px 8px;white-space:nowrap">'
        +   '<button type="button" class="btn-generate" style="padding:4px 8px;font-size:12px;margin-right:4px" '
        +   'data-action="seb-qr-history-toggle" data-qr-id="' + _escHtml(id) + '" title="' + (shown ? 'Sembunyikan' : 'Tampilkan') + '">'
        +   eyeIcon + '</button>'
        +   '<button type="button" class="btn-download" style="padding:4px 8px;font-size:12px;margin-right:4px" '
        +   'data-action="seb-qr-history-print" data-qr-id="' + _escHtml(id) + '" title="Cetak QR ini">'
        +   '&#x1F5A8;</button>'
        +   '<button type="button" class="btn-clear" style="padding:4px 8px;font-size:12px" '
        +   'data-action="seb-qr-history-delete" data-qr-id="' + _escHtml(id) + '" title="Hapus QR ini">'
        +   '&#x1F5D1;</button>'
        + '</td>'
        + '</tr>';
    }).join('');
  },

  toggleRow: function (id) {
    if (this._shown[id]) {
      delete this._shown[id];
    } else {
      this._shown[id] = true;
    }
    this.render();
  },

  showAll: function () {
    this._data.forEach(function (e) { if (e.id) SebQRHistory._shown[e.id] = true; });
    this.render();
  },

  hideAll: function () {
    this._shown = {};
    this.render();
  },

  printRow: function (id) {
    var entry = null;
    for (var i = 0; i < this._data.length; i++) {
      if (this._data[i].id === id) { entry = this._data[i]; break; }
    }
    if (!entry) return;
    var launchUrl  = entry.url || '';
    var qrImageUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=260x260&data=' + encodeURIComponent(launchUrl);
    SebQR.printQr({
      qr_image_url: qrImageUrl,
      launch_url:   launchUrl,
      title:        entry.title || '',
      date:         entry.date ? _formatDateID(entry.date) : ''
    });
  },

  deleteRow: function (id) {
    var entry = null;
    for (var i = 0; i < this._data.length; i++) {
      if (this._data[i].id === id) { entry = this._data[i]; break; }
    }
    if (!entry) return;

    var label = (entry.title || 'QR ini') + (entry.date ? ' (' + _formatDateID(entry.date) + ')' : '');
    Swal.fire({
      title: 'Hapus QR?',
      html: '<strong>' + label + '</strong><br><small style="color:#9ca3af">QR yang sudah dibagikan ke siswa tidak akan bisa digunakan lagi.</small>',
      icon: 'warning',
      showCancelButton: true,
      confirmButtonText: 'Ya, Hapus',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#dc2626',
      cancelButtonColor: '#6b7280',
    }).then(function (res) {
      if (!res.isConfirmed) return;
      var token = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : '';
      fetch('../local/dosman_ujian/deletesebqr.php', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ token: token, qr_id: id })
      })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (d.success) {
            delete SebQRHistory._shown[id];
            SebQRHistory.load();
          } else {
            Swal.fire({ icon: 'error', title: 'Gagal Menghapus', text: d.error || 'Error tidak diketahui' });
          }
        })
        .catch(function () {
          Swal.fire({ icon: 'error', title: 'Gagal Menghapus', text: 'Koneksi error.' });
        });
    });
  }
};

// ── Toggle petunjuk setup SEB ─────────────────────────────────────────────────
var SebGuide = {
  toggle: function () {
    var body = document.getElementById('seb-guide-body');
    var icon = document.getElementById('seb-guide-toggle-icon');
    if (!body) return;
    var hidden = body.style.display === 'none';
    body.style.display = hidden ? 'block' : 'none';
    if (icon) icon.innerHTML = hidden ? '&#x25B2;' : '&#x25BC;';
  }
};

// ── Log download Config SEB ───────────────────────────────────────────────────
var SebLog = {
  load: function () {
    var sts   = document.getElementById('seb-log-status');
    var tbody = document.getElementById('seb-log-body');
    if (!tbody) return;
    if (sts) { sts.style.color = '#6b7280'; sts.textContent = 'Memuat…'; }

    var token = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : '';
    fetch('../local/dosman_ujian/getseblog.php?token=' + encodeURIComponent(token), { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (!Array.isArray(d.log)) throw new Error(d.error || 'Format tidak valid');
        if (sts) {
          sts.style.color = '#16a34a';
          sts.textContent = d.log.length + ' entri ditemukan.';
        }
        if (d.log.length === 0) {
          tbody.innerHTML = '<tr><td colspan="4" style="padding:16px;text-align:center;color:#9ca3af">Belum ada iPad yang mengunduh config.</td></tr>';
          return;
        }
        tbody.innerHTML = d.log.map(function (entry, i) {
          var dt = new Date(entry.time * 1000);
          var ts = dt.toLocaleDateString('id-ID') + ' ' + dt.toLocaleTimeString('id-ID');
          var ua = (entry.ua || '-').substring(0, 80);
          var ip = entry.ip || '-';
          var bg = i % 2 === 0 ? '#fff' : '#f9fafb';
          return '<tr style="background:' + bg + '">'
            + '<td style="padding:7px 10px;color:#9ca3af">' + (i + 1) + '</td>'
            + '<td style="padding:7px 10px;white-space:nowrap">' + ts + '</td>'
            + '<td style="padding:7px 10px;font-family:monospace">' + ip + '</td>'
            + '<td style="padding:7px 10px;color:#6b7280;max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + _escHtml(entry.ua || '') + '">' + _escHtml(ua) + '</td>'
            + '</tr>';
        }).join('');
      })
      .catch(function (e) {
        if (sts) { sts.style.color = '#dc2626'; sts.textContent = 'Gagal memuat: ' + e.message; }
        if (tbody) tbody.innerHTML = '<tr><td colspan="4" style="padding:16px;text-align:center;color:#dc2626">Gagal memuat log.</td></tr>';
      });
  }
};
