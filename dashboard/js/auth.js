// ===========================
// DOSMAN UJIAN - AUTH
// ===========================

var Auth = {
  getToken: function () {
    return localStorage.getItem("dosman_token");
  },
  getMoodleUrl: function () {
    return (
      localStorage.getItem("dosman_moodle_url") ||
      "https://lms.sman1-gianyar.sch.id:9443"
    );
  },
  getUsername: function () {
    return localStorage.getItem("dosman_username") || "Guru";
  },
  isLoggedIn: function () {
    return !!this.getToken();
  },
  logout: function () {
    localStorage.removeItem("dosman_token");
    localStorage.removeItem("dosman_moodle_url");
    localStorage.removeItem("dosman_username");
    window.location.href = "login.html";
  },
};

// Guard untuk index.html
if (document.getElementById("logout-btn")) {
  if (!Auth.isLoggedIn()) {
    window.location.href = "login.html";
  } else {
    // Verifikasi role ke server — cegah bypass via token manual atau sesi bersama
    (function () {
      var overlay = document.createElement('div');
      overlay.style.cssText =
        'position:fixed;inset:0;background:#fff;z-index:99999;' +
        'display:flex;align-items:center;justify-content:center;' +
        'font-family:system-ui,sans-serif;font-size:14px;color:#6b7280';
      overlay.innerHTML = '&#x23F3; Memverifikasi akses...';
      document.body.appendChild(overlay);

      fetch('../local/dosman_ujian/check_dashboard_role.php?token=' +
            encodeURIComponent(Auth.getToken()))
        .then(function (r) { return r.json(); })
        .then(function (data) {
          if (data.allowed) {
            overlay.remove();
          } else {
            // Hapus semua data sesi dan kembali ke login
            localStorage.removeItem('dosman_token');
            localStorage.removeItem('dosman_moodle_url');
            localStorage.removeItem('dosman_username');
            localStorage.removeItem('dosman_userid');
            window.location.href = 'login.html';
          }
        })
        .catch(function () {
          // Server tidak terjangkau — biarkan lanjut, jangan kick pengguna sah
          overlay.remove();
        });
    })();
  }

  var navUser = document.getElementById("nav-user");
  if (navUser) {
    navUser.textContent = "👤 " + Auth.getUsername();
  }
}
