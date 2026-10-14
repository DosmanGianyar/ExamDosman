/**
 * DOSMAN EXAM — Admin & Proctoring Controller
 * SMAN 1 GIANYAR, BALI
 * 
 * Modular, clean, zero legacy code, 100% pure vanilla JavaScript.
 */

(function () {
  'use strict';

  // State Management
  const state = {
    token: '',
    username: 'Guru',
    activeTab: 'live-monitor',
    liveUsers: [],
    deviceBlocked: [],
    suspendedStudents: [],
    selectedSuspendedIds: new Set(),
    countdown: 10,
    countdownInterval: null,
    tickerInterval: null,
    isRefreshing: false,
    pwdVisible: false,
  };

  const API_KEY = (typeof CONFIG !== 'undefined' && CONFIG.EXIT_PWD_API_KEY)
    ? CONFIG.EXIT_PWD_API_KEY
    : 'dosman-exam-sman1gianyar-2024';

  /* ─── INITIALIZATION ─────────────────────────────────────────────────────── */
  function init() {
    state.token = (typeof Auth !== 'undefined' && Auth.getToken) ? Auth.getToken() : localStorage.getItem('dosman_token');
    if (!state.token) {
      window.location.href = 'login.html';
      return;
    }

    state.username = (typeof Auth !== 'undefined' && Auth.getUsername) ? Auth.getUsername() : (localStorage.getItem('dosman_username') || 'Guru');
    const userEl = document.getElementById('nav-user-text');
    if (userEl) userEl.textContent = state.username;

    // Setup Logout
    const logoutBtn = document.getElementById('logout-btn');
    if (logoutBtn) {
      logoutBtn.addEventListener('click', function () {
        Swal.fire({
          title: 'Keluar Dashboard?',
          text: 'Sesi monitoring akan diakhiri.',
          icon: 'question',
          showCancelButton: true,
          confirmButtonText: 'Ya, Keluar',
          cancelButtonText: 'Batal',
          confirmButtonColor: '#ef4444',
          cancelButtonColor: '#475569',
        }).then((result) => {
          if (result.isConfirmed) {
            if (typeof Auth !== 'undefined' && Auth.logout) {
              Auth.logout();
            } else {
              localStorage.clear();
              window.location.href = 'login.html';
            }
          }
        });
      });
    }

    // Start Live Clock
    startClock();

    // Setup Tab Navigation
    setupTabs();

    // Setup Filters & Search
    setupFilters();

    // Setup Exit Password Controls
    setupPasswordControls();

    // Setup Bulk Actions
    setupBulkActions();

    // Initial Load
    refreshAllData();

    // Start Auto Refresh Loop & Tickers
    startAutoRefresh();
    startLastSeenTicker();
  }

  /* ─── CLOCK ──────────────────────────────────────────────────────────────── */
  function startClock() {
    const clockEl = document.getElementById('live-clock');
    if (!clockEl) return;

    function update() {
      const now = new Date();
      // WITA is UTC+8
      const hours = String(now.getHours()).padStart(2, '0');
      const minutes = String(now.getMinutes()).padStart(2, '0');
      const seconds = String(now.getSeconds()).padStart(2, '0');
      clockEl.textContent = `${hours}:${minutes}:${seconds} WITA`;
    }
    update();
    setInterval(update, 1000);
  }

  /* ─── TABS ───────────────────────────────────────────────────────────────── */
  function setupTabs() {
    const tabBtns = document.querySelectorAll('.tab-btn[data-tab]');
    tabBtns.forEach(btn => {
      btn.addEventListener('click', function () {
        const targetTab = this.getAttribute('data-tab');
        switchTab(targetTab);
      });
    });
  }

  function switchTab(tabId) {
    state.activeTab = tabId;

    // Update Tab Buttons
    document.querySelectorAll('.tab-btn[data-tab]').forEach(btn => {
      if (btn.getAttribute('data-tab') === tabId) {
        btn.classList.add('active');
      } else {
        btn.classList.remove('active');
      }
    });

    // Update Tab Panels
    document.querySelectorAll('.tab-panel').forEach(panel => {
      if (panel.id === `tab-${tabId}`) {
        panel.classList.add('active');
      } else {
        panel.classList.remove('active');
      }
    });

    if (tabId === 'suspended-violations') {
      loadViolations();
    } else if (tabId === 'security-password') {
      loadExitPassword();
    } else if (tabId === 'live-monitor') {
      loadLiveUsers();
    }
  }

  /* ─── REFRESH CYCLE ──────────────────────────────────────────────────────── */
  function startAutoRefresh() {
    if (state.countdownInterval) clearInterval(state.countdownInterval);

    state.countdown = 10;
    updateCountdownUI();

    state.countdownInterval = setInterval(() => {
      if (state.isRefreshing) return;
      state.countdown--;
      updateCountdownUI();

      if (state.countdown <= 0) {
        state.countdown = 10;
        refreshAllData(true);
      }
    }, 1000);
  }

  function updateCountdownUI() {
    const badge = document.getElementById('refresh-countdown');
    if (badge) {
      badge.textContent = `${state.countdown}s`;
    }
  }

  async function refreshAllData(silent = false) {
    if (state.isRefreshing) return;
    state.isRefreshing = true;

    const refreshBtn = document.getElementById('btn-manual-refresh');
    if (refreshBtn && !silent) {
      refreshBtn.disabled = true;
      refreshBtn.innerHTML = '&#x23F3; Memuat...';
    }

    try {
      if (state.activeTab === 'live-monitor') {
        await loadLiveUsers();
        // Background update violations count for tab badge
        loadViolations(true);
      } else if (state.activeTab === 'suspended-violations') {
        await loadViolations();
        // Background update live users for tab badge
        loadLiveUsers(true);
      } else if (state.activeTab === 'security-password') {
        await loadExitPassword();
      }
    } catch (err) {
      console.error('Refresh failed:', err);
    } finally {
      state.isRefreshing = false;
      if (refreshBtn && !silent) {
        refreshBtn.disabled = false;
        refreshBtn.innerHTML = '&#x1F504; Refresh';
      }
    }
  }

  /* ─── LIVE MONITOR (TAB 1) ───────────────────────────────────────────────── */
  async function loadLiveUsers(backgroundOnly = false) {
    try {
      const res = await fetch(`../local/dosman_ujian/get_app_users.php?token=${encodeURIComponent(state.token)}`, {
        cache: 'no-store'
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();

      if (data.error) {
        if (data.error.includes('Token tidak valid')) {
          localStorage.clear();
          window.location.href = 'login.html';
          return;
        }
        throw new Error(data.error);
      }

      state.liveUsers = Array.isArray(data.users) ? data.users : [];

      updateLiveKPI();
      rebuildClassFilterOptions();

      if (!backgroundOnly) {
        renderLiveMonitorTable();
      }
    } catch (e) {
      console.warn('loadLiveUsers error:', e.message);
      if (!backgroundOnly) {
        renderLiveMonitorError(e.message);
      }
    }
  }

  function updateLiveKPI() {
    const users = state.liveUsers;
    const total = users.length;
    const inQuiz = users.filter(u => u.current_quizid > 0 && (u.lock_status === 1 || u.client_type === 'ios')).length;
    const standby = users.filter(u => u.current_quizid === 0 && (u.lock_status === 1 || u.client_type === 'ios')).length;
    const blocked = users.filter(u => u.lock_status === 2 || u.lock_status === 3).length;

    const elTotal = document.getElementById('kpi-total');
    const elInQuiz = document.getElementById('kpi-inquiz');
    const elStandby = document.getElementById('kpi-standby');
    const elBlocked = document.getElementById('kpi-blocked');
    const tabBadge = document.getElementById('tab-badge-live');

    if (elTotal) elTotal.textContent = total;
    if (elInQuiz) elInQuiz.textContent = inQuiz;
    if (elStandby) elStandby.textContent = standby;
    if (elBlocked) elBlocked.textContent = blocked;
    if (tabBadge) tabBadge.textContent = total;
  }

  function rebuildClassFilterOptions() {
    const select = document.getElementById('filter-class');
    if (!select) return;

    const currentVal = select.value;
    const classes = new Set();

    state.liveUsers.forEach(u => {
      const dept = (u.department || '').trim();
      if (dept) classes.add(dept);

      // Also check if class is embedded in lastname e.g. "| X 3 | 2025"
      const match = (u.lastname || '').match(/\|\s*([X|XI|XII][^|]+)\s*\|/i);
      if (match && match[1]) {
        classes.add(match[1].trim());
      }
    });

    const sorted = Array.from(classes).sort((a, b) => a.localeCompare(b, 'id'));

    // Preserve standard options
    let html = '<option value="">Semua Kelas</option>';
    sorted.forEach(cls => {
      html += `<option value="${escapeHtml(cls)}">${escapeHtml(cls)}</option>`;
    });

    select.innerHTML = html;
    if (currentVal && (sorted.includes(currentVal) || currentVal === '')) {
      select.value = currentVal;
    }
  }

  function getFilteredLiveUsers() {
    const searchInput = document.getElementById('search-live');
    const q = (searchInput ? searchInput.value : '').trim().toLowerCase();

    const classSelect = document.getElementById('filter-class');
    const selectedClass = classSelect ? classSelect.value : '';

    const statusSelect = document.getElementById('filter-status');
    const selectedStatus = statusSelect ? statusSelect.value : '';

    const platformSelect = document.getElementById('filter-platform');
    const selectedPlatform = platformSelect ? platformSelect.value : '';

    return state.liveUsers.filter(u => {
      // Platform filter
      if (selectedPlatform && u.client_type !== selectedPlatform) return false;

      // Status filter
      if (selectedStatus === 'inquiz') {
        if (!(u.current_quizid > 0 && (u.lock_status === 1 || u.client_type === 'ios'))) return false;
      } else if (selectedStatus === 'standby') {
        if (!(u.current_quizid === 0 && (u.lock_status === 1 || u.client_type === 'ios'))) return false;
      } else if (selectedStatus === 'paused') {
        if (u.lock_status !== 3) return false;
      } else if (selectedStatus === 'blocked') {
        if (u.lock_status !== 2) return false;
      }

      // Class filter
      if (selectedClass) {
        const dept = (u.department || '').trim();
        const lastname = (u.lastname || '').trim();
        if (dept !== selectedClass && !lastname.includes(selectedClass)) return false;
      }

      // Search keyword filter
      if (q) {
        const fullname = `${u.firstname || ''} ${u.lastname || ''}`.toLowerCase();
        const username = (u.username || '').toLowerCase();
        const quizName = (u.quiz_name || '').toLowerCase();
        if (!fullname.includes(q) && !username.includes(q) && !quizName.includes(q)) return false;
      }

      return true;
    });
  }

  function renderLiveMonitorTable() {
    const tbody = document.getElementById('live-monitor-tbody');
    const countBadge = document.getElementById('filtered-count');
    if (!tbody) return;

    const filtered = getFilteredLiveUsers();
    if (countBadge) countBadge.textContent = `${filtered.length} siswa ditampilkan`;

    if (filtered.length === 0) {
      tbody.innerHTML = `
        <tr>
          <td colspan="8">
            <div class="empty-state">
              <div class="empty-icon">&#x1F4CB;</div>
              <div class="empty-title">Tidak Ada Siswa Sesuai Filter</div>
              <div class="empty-desc">Belum ada siswa yang sedang terhubung atau sesuai kriteria pencarian yang dipilih.</div>
            </div>
          </td>
        </tr>
      `;
      return;
    }

    let rowsHtml = '';
    filtered.forEach((u, idx) => {
      const isBlocked = u.lock_status === 2;
      const isPaused = u.lock_status === 3;
      const isOnQuiz = u.current_quizid > 0 && (u.lock_status === 1 || u.client_type === 'ios');
      const isIOS = u.client_type === 'ios';

      // Status Badge
      let statusBadge = '';
      if (isBlocked) {
        statusBadge = '<span class="badge badge-danger">&#x1F534; Terblokir</span>';
      } else if (isPaused) {
        statusBadge = '<span class="badge badge-warning">&#x23F8;&#xFE0F; Dijeda</span>';
      } else if (isOnQuiz) {
        statusBadge = '<span class="badge badge-success">&#x270D;&#xFE0F; Sedang Ujian</span>';
      } else {
        statusBadge = '<span class="badge badge-secondary">&#x1F4A4; Standby</span>';
      }

      // Platform Badge
      const platformBadge = isIOS
        ? '<span class="badge badge-ios">&#x1F34E; iOS / Apple</span>'
        : '<span class="badge badge-android">&#x1F916; Android</span>';

      // Initials Avatar
      const rawFirst = (u.firstname || 'S').trim();
      const initials = rawFirst.substring(0, 2).toUpperCase();

      // Formatted Class Name
      let kelas = (u.department || '').trim();
      const match = (u.lastname || '').match(/\|\s*([^|]+)\s*\|/);
      if (match && match[1]) {
        kelas = match[1].trim();
      }
      if (!kelas || kelas === 'SMA Negeri 1 Gianyar') {
        kelas = (u.department || '—');
      }

      // Quiz cell
      const quizHtml = isOnQuiz
        ? `<strong style="color:var(--primary); font-size:0.825rem;">${escapeHtml(u.quiz_name || `Ujian #${u.current_quizid}`)}</strong>`
        : `<span style="color:var(--text-dim); font-size:0.8rem;">Di Beranda</span>`;

      // Live ping ticker
      const lastSeenText = formatLastSeen(u.lastping);

      // Action buttons
      let actionButtons = '';
      if (isBlocked || isPaused) {
        actionButtons += `
          <button class="btn-action btn-action-unblock" onclick="DosmanApp.unblockStudent(${u.userid}, '${escapeJs(u.firstname)}')" title="Buka blokir dan izinkan siswa kembali ujian">
            &#x1F513; Buka Blokir
          </button>
        `;
      }

      actionButtons += `
        <button class="btn-action btn-action-reset" onclick="DosmanApp.resetStudentSession(${u.userid}, '${escapeJs(u.firstname)}')" title="Reset sesi aplikasi (paksa login ulang)">
          &#x1F504; Reset
        </button>
        <button class="btn-action btn-action-suspend" onclick="DosmanApp.suspendStudent(${u.userid}, '${escapeJs(u.firstname)}')" title="Kunci akun Moodle (pelanggaran)">
          &#x26D4; Suspend
        </button>
      `;

      rowsHtml += `
        <tr>
          <td style="color:var(--text-dim); font-size:0.8rem; font-family:'JetBrains Mono';">${idx + 1}</td>
          <td>
            <div class="student-cell">
              <div class="student-avatar">${escapeHtml(initials)}</div>
              <div class="student-meta">
                <span class="student-name">${escapeHtml(u.firstname || '')} ${escapeHtml(u.lastname || '')}</span>
                <span class="student-sub">@${escapeHtml(u.username || '')} &bull; ID: ${u.userid}</span>
              </div>
            </div>
          </td>
          <td><span style="font-size:0.85rem; font-weight:500;">${escapeHtml(kelas)}</span></td>
          <td>${platformBadge}</td>
          <td>${statusBadge}</td>
          <td>${quizHtml}</td>
          <td>
            <div class="time-ticker live-ticker-cell" data-lastping="${u.lastping || 0}">
              ${lastSeenText}
            </div>
          </td>
          <td>
            <div class="action-group">
              ${actionButtons}
            </div>
          </td>
        </tr>
      `;
    });

    tbody.innerHTML = rowsHtml;
  }

  function renderLiveMonitorError(msg) {
    const tbody = document.getElementById('live-monitor-tbody');
    if (!tbody) return;
    tbody.innerHTML = `
      <tr>
        <td colspan="8">
          <div class="empty-state" style="color:var(--danger);">
            <div class="empty-icon">&#x26A0;&#xFE0F;</div>
            <div class="empty-title" style="color:var(--danger);">Gagal Memuat Data Monitor</div>
            <div class="empty-desc">${escapeHtml(msg)}</div>
          </div>
        </td>
      </tr>
    `;
  }

  /* ─── PELANGGARAN & TERSUSPEND (TAB 2) ───────────────────────────────────── */
  async function loadViolations(backgroundOnly = false) {
    try {
      // 1. Fetch Tier 1: Device Blocked
      const devRes = await fetch(`../local/dosman_ujian/get_device_blocked_students.php?token=${encodeURIComponent(state.token)}`, {
        cache: 'no-store'
      });
      if (devRes.ok) {
        const devData = await devRes.json();
        state.deviceBlocked = Array.isArray(devData.students) ? devData.students : [];
      }

      // 2. Fetch Tier 2: Suspended Moodle Accounts
      const suspRes = await fetch(`../local/dosman_ujian/get_suspended_students.php?token=${encodeURIComponent(state.token)}`, {
        cache: 'no-store'
      });
      if (suspRes.ok) {
        const suspData = await suspRes.json();
        state.suspendedStudents = Array.isArray(suspData.students) ? suspData.students : [];
      }

      // Update badge in Tab header
      const totalViolations = state.deviceBlocked.length + state.suspendedStudents.length;
      const tabBadge = document.getElementById('tab-badge-violations');
      if (tabBadge) {
        tabBadge.textContent = totalViolations;
        if (totalViolations > 0) {
          tabBadge.classList.add('danger');
        } else {
          tabBadge.classList.remove('danger');
        }
      }

      if (!backgroundOnly) {
        renderDeviceBlockedTable();
        renderSuspendedTable();
      }
    } catch (e) {
      console.warn('loadViolations error:', e.message);
    }
  }

  function renderDeviceBlockedTable() {
    const tbody = document.getElementById('device-blocked-tbody');
    const countEl = document.getElementById('device-blocked-count');
    if (!tbody) return;

    if (countEl) countEl.textContent = `${state.deviceBlocked.length} perangkat`;

    if (state.deviceBlocked.length === 0) {
      tbody.innerHTML = `
        <tr>
          <td colspan="6">
            <div class="empty-state">
              <div class="empty-icon">&#x2705;</div>
              <div class="empty-title">Tidak Ada Perangkat Diblokir</div>
              <div class="empty-desc">Semua perangkat siswa beroperasi normal tanpa pelanggaran anti-cheat.</div>
            </div>
          </td>
        </tr>
      `;
      return;
    }

    let html = '';
    state.deviceBlocked.forEach((d, idx) => {
      const name = `${d.firstname || ''} ${d.lastname || ''}`.trim() || d.username || 'Siswa';
      const reason = d.block_reason || 'Terdeteksi keluar dari aplikasi / minimize';
      const timeStr = d.blocked_at ? new Date(d.blocked_at * 1000).toLocaleTimeString('id-ID') : '—';
      const escSecs = d.seconds_until_escalation ?? 0;
      const escalateText = escSecs > 0 ? `Auto-suspend dalam ${Math.ceil(escSecs / 60)} mnt` : 'Siap eskalasi';

      html += `
        <tr>
          <td style="color:var(--text-dim); font-size:0.8rem; font-family:'JetBrains Mono';">${idx + 1}</td>
          <td>
            <div class="student-meta">
              <span class="student-name">${escapeHtml(name)}</span>
              <span class="student-sub">ID: ${d.userid} &bull; Model: ${escapeHtml(d.model || 'Unknown Device')}</span>
            </div>
          </td>
          <td>
            <span class="badge badge-danger">&#x1F6A8; ${escapeHtml(reason)}</span>
          </td>
          <td style="font-size:0.825rem; font-family:'JetBrains Mono';">${timeStr}</td>
          <td>
            <span class="badge badge-warning">&#x23F3; ${escalateText}</span>
          </td>
          <td>
            <div class="action-group">
              <button class="btn-action btn-action-unblock" onclick="DosmanApp.unblockDevice('${escapeJs(d.device_id)}', '${escapeJs(name)}')" title="Buka blokir perangkat">
                &#x1F513; Buka Blokir
              </button>
              <button class="btn-action btn-action-suspend" onclick="DosmanApp.suspendStudent(${d.userid}, '${escapeJs(name)}')" title="Eskalasi ke suspend sekarang">
                &#x26D4; Suspend
              </button>
            </div>
          </td>
        </tr>
      `;
    });

    tbody.innerHTML = html;
  }

  function renderSuspendedTable() {
    const tbody = document.getElementById('suspended-tbody');
    const countEl = document.getElementById('suspended-count');
    if (!tbody) return;

    const searchInput = document.getElementById('search-suspended');
    const q = (searchInput ? searchInput.value : '').trim().toLowerCase();

    const filtered = state.suspendedStudents.filter(s => {
      if (!q) return true;
      const name = `${s.firstname || ''} ${s.lastname || ''}`.toLowerCase();
      const uname = (s.username || '').toLowerCase();
      const email = (s.email || '').toLowerCase();
      return name.includes(q) || uname.includes(q) || email.includes(q);
    });

    if (countEl) countEl.textContent = `${filtered.length} akun`;

    if (filtered.length === 0) {
      tbody.innerHTML = `
        <tr>
          <td colspan="6">
            <div class="empty-state">
              <div class="empty-icon">&#x1F389;</div>
              <div class="empty-title">Tidak Ada Siswa Tersuspend</div>
              <div class="empty-desc">Tidak ada akun siswa yang dikunci atau disanksi pelanggaran.</div>
            </div>
          </td>
        </tr>
      `;
      return;
    }

    let html = '';
    filtered.forEach((s, idx) => {
      const name = `${s.firstname || ''} ${s.lastname || ''}`.trim() || s.username;
      const isSelected = state.selectedSuspendedIds.has(s.userid);
      const timeStr = s.timemodified ? new Date(s.timemodified * 1000).toLocaleString('id-ID') : '—';

      html += `
        <tr>
          <td style="text-align:center;">
            <input type="checkbox" class="suspended-cb" data-userid="${s.userid}" ${isSelected ? 'checked' : ''} onchange="DosmanApp.toggleSuspendedSelect(${s.userid}, this.checked)">
          </td>
          <td style="color:var(--text-dim); font-size:0.8rem; font-family:'JetBrains Mono';">${idx + 1}</td>
          <td>
            <div class="student-meta">
              <span class="student-name">${escapeHtml(name)}</span>
              <span class="student-sub">@${escapeHtml(s.username || '')} &bull; ${escapeHtml(s.department || '')}</span>
            </div>
          </td>
          <td><span style="font-size:0.825rem; color:var(--text-muted);">${escapeHtml(s.email || '—')}</span></td>
          <td style="font-size:0.825rem; font-family:'JetBrains Mono'; color:var(--text-muted);">${timeStr}</td>
          <td>
            <button class="btn-action btn-action-unblock" onclick="DosmanApp.unsuspendStudent(${s.userid}, '${escapeJs(name)}')" title="Aktifkan kembali akun siswa">
              &#x1F513; Aktifkan Akun
            </button>
          </td>
        </tr>
      `;
    });

    tbody.innerHTML = html;
  }

  /* ─── PASSWORD KELUAR (TAB 3) ────────────────────────────────────────────── */
  async function loadExitPassword() {
    const input = document.getElementById('exit-pwd-input');
    const statusText = document.getElementById('exit-pwd-status');
    if (!input) return;

    try {
      if (statusText) statusText.textContent = 'Memuat password aktif...';
      const res = await fetch(`../local/dosman_ujian/exitpwd.php?apikey=${encodeURIComponent(API_KEY)}`, {
        cache: 'no-store'
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();

      if (typeof data.password === 'string') {
        input.value = data.password;
        if (statusText) {
          if (data.password === '') {
            statusText.innerHTML = '<span style="color:var(--warning);">&#x26A0;&#xFE0F; Password kosong &bull; Siswa dapat keluar tanpa konfirmasi password.</span>';
          } else {
            statusText.innerHTML = `<span style="color:var(--success);">&#x2705; Password aktif terpasang (${data.password.length} karakter).</span>`;
          }
        }
      }
    } catch (e) {
      if (statusText) {
        statusText.innerHTML = `<span style="color:var(--danger);">&#x274C; Gagal memuat password: ${escapeHtml(e.message)}</span>`;
      }
    }
  }

  async function saveExitPassword(newPassword) {
    const statusText = document.getElementById('exit-pwd-status');
    if (statusText) statusText.textContent = 'Menyimpan ke server...';

    try {
      const res = await fetch('../local/dosman_ujian/setpwd.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          password: newPassword
        })
      });
      const data = await res.json();

      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Tersimpan!',
          text: newPassword === '' ? 'Password keluar telah dikosongkan.' : `Password keluar berhasil diperbarui: "${newPassword}"`,
          timer: 2000,
          showConfirmButton: false
        });
        loadExitPassword();
      } else {
        throw new Error(data.message || 'Gagal menyimpan password');
      }
    } catch (e) {
      Swal.fire({
        icon: 'error',
        title: 'Gagal Menyimpan',
        text: e.message
      });
      if (statusText) {
        statusText.innerHTML = `<span style="color:var(--danger);">&#x274C; ${escapeHtml(e.message)}</span>`;
      }
    }
  }

  function setupPasswordControls() {
    // Eye toggle
    const toggleBtn = document.getElementById('btn-toggle-pwd');
    const input = document.getElementById('exit-pwd-input');
    if (toggleBtn && input) {
      toggleBtn.addEventListener('click', function () {
        state.pwdVisible = !state.pwdVisible;
        input.type = state.pwdVisible ? 'text' : 'password';
        toggleBtn.innerHTML = state.pwdVisible ? '&#x1F648;' : '&#x1F441;';
      });
    }

    // Generate & Save
    const btnGen = document.getElementById('btn-pwd-random');
    if (btnGen) {
      btnGen.addEventListener('click', function () {
        const randomNum = String(Math.floor(100000 + Math.random() * 900000));
        if (input) {
          input.value = randomNum;
          input.type = 'text';
          state.pwdVisible = true;
          if (toggleBtn) toggleBtn.innerHTML = '&#x1F648;';
        }
        saveExitPassword(randomNum);
      });
    }

    // Save Manual
    const btnSave = document.getElementById('btn-pwd-save');
    if (btnSave) {
      btnSave.addEventListener('click', function () {
        const val = input ? input.value.trim() : '';
        if (val !== '' && val.length < 4) {
          Swal.fire({
            icon: 'warning',
            title: 'Password Terlalu Pendek',
            text: 'Password minimal 4 karakter, atau kosongkan untuk membebaskan keluar.'
          });
          return;
        }
        saveExitPassword(val);
      });
    }

    // Clear & Free
    const btnClear = document.getElementById('btn-pwd-clear');
    if (btnClear) {
      btnClear.addEventListener('click', function () {
        Swal.fire({
          title: 'Kosongkan Password?',
          text: 'Siswa akan diizinkan keluar aplikasi tanpa perlu memasukkan password ujian.',
          icon: 'warning',
          showCancelButton: true,
          confirmButtonText: 'Ya, Kosongkan',
          cancelButtonText: 'Batal',
          confirmButtonColor: '#f59e0b',
          cancelButtonColor: '#475569',
        }).then((result) => {
          if (result.isConfirmed) {
            if (input) input.value = '';
            saveExitPassword('');
          }
        });
      });
    }
  }

  /* ─── FILTERS & SEARCH SETUP ─────────────────────────────────────────────── */
  function setupFilters() {
    const searchLive = document.getElementById('search-live');
    if (searchLive) {
      searchLive.addEventListener('input', renderLiveMonitorTable);
    }

    const filterClass = document.getElementById('filter-class');
    if (filterClass) {
      filterClass.addEventListener('change', renderLiveMonitorTable);
    }

    const filterStatus = document.getElementById('filter-status');
    if (filterStatus) {
      filterStatus.addEventListener('change', renderLiveMonitorTable);
    }

    const filterPlatform = document.getElementById('filter-platform');
    if (filterPlatform) {
      filterPlatform.addEventListener('change', renderLiveMonitorTable);
    }

    const btnRefresh = document.getElementById('btn-manual-refresh');
    if (btnRefresh) {
      btnRefresh.addEventListener('click', () => {
        state.countdown = 10;
        refreshAllData(false);
      });
    }

    const searchSuspended = document.getElementById('search-suspended');
    if (searchSuspended) {
      searchSuspended.addEventListener('input', renderSuspendedTable);
    }
  }

  /* ─── ACTIONS ON STUDENTS ────────────────────────────────────────────────── */
  async function unblockStudent(userId, name) {
    const res = await Swal.fire({
      title: 'Buka Blokir Siswa?',
      html: `Izinkan <strong>${escapeHtml(name)}</strong> untuk melanjutkan ujian kembali.`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'Ya, Buka Blokir',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#10b981',
      cancelButtonColor: '#475569',
    });

    if (!res.isConfirmed) return;

    try {
      const response = await fetch('../local/dosman_ujian/set_lock_status.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          userid: userId,
          lock_status: 1
        })
      });
      const data = await response.json();
      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Blokir Dibuka',
          text: `Siswa "${name}" dapat kembali melanjutkan ujian.`,
          timer: 2000,
          showConfirmButton: false
        });
        loadLiveUsers();
      } else {
        throw new Error(data.error || 'Gagal membuka blokir');
      }
    } catch (e) {
      Swal.fire({ icon: 'error', title: 'Error', text: e.message });
    }
  }

  async function resetStudentSession(userId, name) {
    const res = await Swal.fire({
      title: 'Reset Sesi Ujian?',
      html: `Sesi login <strong>${escapeHtml(name)}</strong> akan dihapus dan dipaksa login ulang.<br><small style="color:var(--text-muted)">Akun TIDAK di-suspend, siswa bisa langsung login kembali.</small>`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonText: 'Ya, Reset Sesi',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#3b82f6',
      cancelButtonColor: '#475569',
    });

    if (!res.isConfirmed) return;

    try {
      const response = await fetch('../local/dosman_ujian/force_logout_student.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          userid: userId
        })
      });
      const data = await response.json();
      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Sesi Direset',
          text: `Sesi "${name}" berhasil direset.`,
          timer: 2000,
          showConfirmButton: false
        });
        loadLiveUsers();
      } else {
        throw new Error(data.error || 'Gagal reset sesi');
      }
    } catch (e) {
      Swal.fire({ icon: 'error', title: 'Error', text: e.message });
    }
  }

  async function suspendStudent(userId, name) {
    const res = await Swal.fire({
      title: 'Suspend Akun Siswa?',
      html: `<span style="color:var(--danger)">PERINGATAN:</span> Akun Moodle <strong>${escapeHtml(name)}</strong> akan dikunci sepenuhnya.<br>Siswa tidak dapat login sama sekali sampai diaktifkan kembali oleh proktor.`,
      icon: 'error',
      showCancelButton: true,
      confirmButtonText: 'Ya, Suspend Akun',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#ef4444',
      cancelButtonColor: '#475569',
    });

    if (!res.isConfirmed) return;

    try {
      const response = await fetch('../local/dosman_ujian/suspend_student.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          userid: userId
        })
      });
      const data = await response.json();
      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Akun Tersuspend',
          text: `Akun "${name}" telah disanksi suspend.`,
          timer: 2000,
          showConfirmButton: false
        });
        loadLiveUsers();
        loadViolations();
      } else {
        throw new Error(data.message || 'Gagal melakukan suspend');
      }
    } catch (e) {
      Swal.fire({ icon: 'error', title: 'Error', text: e.message });
    }
  }

  async function unsuspendStudent(userId, name) {
    const res = await Swal.fire({
      title: 'Aktifkan Akun Siswa?',
      html: `Buka kunci akun Moodle untuk <strong>${escapeHtml(name)}</strong> agar dapat login dan mengikuti ujian kembali.`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'Ya, Aktifkan',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#10b981',
      cancelButtonColor: '#475569',
    });

    if (!res.isConfirmed) return;

    try {
      const response = await fetch('../local/dosman_ujian/unsuspend_student.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          userid: userId
        })
      });
      const data = await response.json();
      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Akun Aktif',
          text: `Akun "${name}" berhasil diaktifkan kembali.`,
          timer: 2000,
          showConfirmButton: false
        });
        state.selectedSuspendedIds.delete(userId);
        loadViolations();
        loadLiveUsers();
      } else {
        throw new Error(data.message || 'Gagal mengaktifkan akun');
      }
    } catch (e) {
      Swal.fire({ icon: 'error', title: 'Error', text: e.message });
    }
  }

  async function unblockDevice(deviceId, name) {
    const res = await Swal.fire({
      title: 'Buka Blokir Perangkat?',
      html: `Perangkat milik <strong>${escapeHtml(name)}</strong> akan diizinkan kembali untuk membuka aplikasi ujian.`,
      icon: 'question',
      showCancelButton: true,
      confirmButtonText: 'Ya, Buka Perangkat',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#10b981',
      cancelButtonColor: '#475569',
    });

    if (!res.isConfirmed) return;

    try {
      const response = await fetch('../local/dosman_ujian/unblock_device.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          device_id: deviceId
        })
      });
      const data = await response.json();
      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Perangkat Dibuka',
          text: data.message || 'Perangkat berhasil dibuka blokirnya.',
          timer: 2000,
          showConfirmButton: false
        });
        loadViolations();
      } else {
        throw new Error(data.message || 'Gagal membuka blokir perangkat');
      }
    } catch (e) {
      Swal.fire({ icon: 'error', title: 'Error', text: e.message });
    }
  }

  /* ─── BULK ACTIONS ───────────────────────────────────────────────────────── */
  function setupBulkActions() {
    const selectAllCb = document.getElementById('cb-select-all-suspended');
    if (selectAllCb) {
      selectAllCb.addEventListener('change', function () {
        const isChecked = this.checked;
        state.suspendedStudents.forEach(s => {
          if (isChecked) {
            state.selectedSuspendedIds.add(s.userid);
          } else {
            state.selectedSuspendedIds.delete(s.userid);
          }
        });
        renderSuspendedTable();
        updateBulkUI();
      });
    }

    const bulkBtn = document.getElementById('btn-bulk-unsuspend');
    if (bulkBtn) {
      bulkBtn.addEventListener('click', async function () {
        const count = state.selectedSuspendedIds.size;
        if (count === 0) return;

        const res = await Swal.fire({
          title: `Buka Suspend ${count} Siswa?`,
          text: 'Semua akun siswa yang dipilih akan diaktifkan kembali.',
          icon: 'question',
          showCancelButton: true,
          confirmButtonText: `Ya, Buka ${count} Akun`,
          cancelButtonText: 'Batal',
          confirmButtonColor: '#10b981',
          cancelButtonColor: '#475569',
        });

        if (!res.isConfirmed) return;

        Swal.fire({
          title: 'Memproses...',
          html: 'Sedang mengaktifkan akun siswa...',
          allowOutsideClick: false,
          didOpen: () => { Swal.showLoading(); }
        });

        let successCount = 0;
        for (const uid of Array.from(state.selectedSuspendedIds)) {
          try {
            const resp = await fetch('../local/dosman_ujian/unsuspend_student.php', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ token: state.token, userid: uid })
            });
            const d = await resp.json();
            if (d.success) successCount++;
          } catch (_) {}
        }

        state.selectedSuspendedIds.clear();
        Swal.fire({
          icon: 'success',
          title: 'Selesai!',
          text: `${successCount} dari ${count} akun berhasil diaktifkan.`,
          timer: 2000,
          showConfirmButton: false
        });
        loadViolations();
      });
    }
  }

  function toggleSuspendedSelect(userId, checked) {
    if (checked) {
      state.selectedSuspendedIds.add(userId);
    } else {
      state.selectedSuspendedIds.delete(userId);
    }
    updateBulkUI();
  }

  function updateBulkUI() {
    const count = state.selectedSuspendedIds.size;
    const bulkBtn = document.getElementById('btn-bulk-unsuspend');
    if (bulkBtn) {
      bulkBtn.style.display = count > 0 ? 'inline-flex' : 'none';
      bulkBtn.textContent = `\u{1F513} Aktifkan ${count} Siswa Terpilih`;
    }
  }

  /* ─── TICKERS & HELPERS ──────────────────────────────────────────────────── */
  function startLastSeenTicker() {
    setInterval(() => {
      document.querySelectorAll('.live-ticker-cell[data-lastping]').forEach(el => {
        const ping = parseInt(el.getAttribute('data-lastping'), 10);
        if (ping > 0) {
          el.textContent = formatLastSeen(ping);
        }
      });
    }, 1000);
  }

  function formatLastSeen(timestamp) {
    if (!timestamp || timestamp <= 0) return '—';
    const nowSec = Math.floor(Date.now() / 1000);
    const diff = Math.max(0, nowSec - timestamp);

    if (diff < 5) return 'Baru saja';
    if (diff < 60) return `${diff} dtk lalu`;
    if (diff < 3600) return `${Math.floor(diff / 60)} mnt lalu`;
    return `${Math.floor(diff / 3600)} jam lalu`;
  }

  function escapeHtml(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function escapeJs(str) {
    if (!str) return '';
    return String(str).replace(/'/g, "\\'").replace(/"/g, '\\"');
  }

  // Public Interface for Inline Handlers
  window.DosmanApp = {
    init: init,
    switchTab: switchTab,
    unblockStudent: unblockStudent,
    resetStudentSession: resetStudentSession,
    suspendStudent: suspendStudent,
    unsuspendStudent: unsuspendStudent,
    unblockDevice: unblockDevice,
    toggleSuspendedSelect: toggleSuspendedSelect,
  };

  // Launch when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
