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
    listMode: 'live', // 'live' = Siswa Sedang Login / Ujian (Active Only), 'all' = Semua Akun Terdaftar (Direktori)
    liveUsers: [],
    deviceBlocked: [],
    suspendedStudents: [],
    selectedSuspendedIds: new Set(),
    pluginConfig: { min_android_build: 0, min_ios_build: 0, network_access_mode: 'both' },
    networkAccessMode: 'both',
    countdown: 10,
    countdownInterval: null,
    tickerInterval: null,
    isRefreshing: false,
    pwdVisible: false,
    rescueCodeVisible: false,
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

    // Setup Exit Password, Proctor Rescue Code, & Network Access Mode Controls
    setupPasswordControls();
    setupRescueCodeControls();
    setupNetworkModeControls();

    // Setup Bulk Actions
    setupBulkActions();

    // Setup Broadcast Modal Trigger & Listeners
    const bcBtn = document.getElementById('btn-broadcast-open');
    if (bcBtn) {
      bcBtn.addEventListener('click', openBroadcastModal);
    }
    const bcModal = document.getElementById('modal-broadcast');
    if (bcModal) {
      bcModal.addEventListener('click', function(e) {
        if (e.target === bcModal) closeBroadcastModal();
      });
    }
    document.addEventListener('keydown', function(e) {
      if (e.key === 'Escape') closeBroadcastModal();
    });

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

    // Pulihkan tab terakhir saat halaman di-refresh
    const hashTab = (window.location.hash || '').replace(/^#/, '');
    let savedTab = '';
    try { savedTab = localStorage.getItem('dosman_admin_active_tab') || ''; } catch (_) {}
    const restoreTab = hashTab || savedTab;
    if (restoreTab && document.querySelector(`.tab-btn[data-tab="${restoreTab}"]`)) {
      switchTab(restoreTab, { skipFetch: true });
    }
  }

  function switchTab(tabId, opts = {}) {
    state.activeTab = tabId;
    try { localStorage.setItem('dosman_admin_active_tab', tabId); } catch (_) {}
    if (history.replaceState) {
      history.replaceState(null, '', `#${tabId}`);
    }

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

    if (!opts.skipFetch) {
      if (tabId === 'suspended-violations') {
        loadViolations();
      } else if (tabId === 'security-password') {
        loadExitPassword();
        loadRescueCode();
        loadNetworkMode();
      } else if (tabId === 'live-monitor') {
        loadLiveUsers();
      }
    }
  }

  /* ─── REFRESH CYCLE ──────────────────────────────────────────────────────── */
  let refreshCycleCount = 0;

  function startAutoRefresh() {
    if (state.countdownInterval) clearInterval(state.countdownInterval);

    state.countdown = 15;
    updateCountdownUI();

    state.countdownInterval = setInterval(() => {
      if (state.isRefreshing || document.hidden) return;
      state.countdown--;
      updateCountdownUI();

      if (state.countdown <= 0) {
        state.countdown = 15;
        refreshAllData(true);
      }
    }, 1000);

    document.addEventListener('visibilitychange', () => {
      if (!document.hidden && !state.isRefreshing) {
        state.countdown = 15;
        refreshAllData(true);
      }
    });
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
    refreshCycleCount++;

    const refreshBtn = document.getElementById('btn-manual-refresh');
    if (refreshBtn && !silent) {
      refreshBtn.disabled = true;
      refreshBtn.innerHTML = '&#x23F3; Memuat...';
    }

    try {
      if (state.activeTab === 'live-monitor') {
        await loadLiveUsers();
        // Optimasi 800 siswa: update badge pelanggaran hanya saat load pertama atau setiap 3 siklus (45 detik)
        if (!silent || refreshCycleCount % 3 === 1) {
          loadViolations(true);
        }
      } else if (state.activeTab === 'suspended-violations') {
        await loadViolations();
        if (!silent || refreshCycleCount % 3 === 1) {
          loadLiveUsers(true);
        }
      } else if (state.activeTab === 'security-password') {
        await loadExitPassword();
        await loadRescueCode();
        await loadNetworkMode();
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
      if (data.plugin_config && typeof data.plugin_config === 'object') {
        const netMode = data.plugin_config.network_access_mode === 'local_only' ? 'local_only' : 'both';
        state.pluginConfig = {
          min_android_build: parseInt(data.plugin_config.min_android_build || 0, 10) || 0,
          min_ios_build: parseInt(data.plugin_config.min_ios_build || 0, 10) || 0,
          network_access_mode: netMode,
        };
        state.networkAccessMode = netMode;
        updateNetworkModeUI();
      }

      updateLiveKPI();
      rebuildClassFilterOptions();
      rebuildVersionFilterAndSummary();

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
    const onlineUsers = users.filter(u => u.is_online === 1 || isUserUnresponsive(u));
    const onlineCount = onlineUsers.length;
    const inQuiz = users.filter(u => u.current_quizid > 0).length;
    const standby = users.filter(u => u.is_online === 1 && !isUserUnresponsive(u) && u.current_quizid === 0).length;
    const blocked = users.filter(u => u.lock_status === 2 || u.lock_status === 3).length;

    const elTotal = document.getElementById('kpi-total');
    const elInQuiz = document.getElementById('kpi-inquiz');
    const elStandby = document.getElementById('kpi-standby');
    const elBlocked = document.getElementById('kpi-blocked');
    const tabBadge = document.getElementById('tab-badge-live');
    const badgeCountLive = document.getElementById('badge-count-live');
    const badgeCountAll = document.getElementById('badge-count-all');

    if (elTotal) {
      elTotal.innerHTML = `${onlineCount} <span style="font-size:0.95rem; font-weight:400; color:var(--text-dim);">/ ${total}</span>`;
    }
    if (elInQuiz) elInQuiz.textContent = inQuiz;
    if (elStandby) elStandby.textContent = standby;
    if (elBlocked) elBlocked.textContent = blocked;
    if (tabBadge) tabBadge.textContent = onlineCount;
    if (badgeCountLive) badgeCountLive.textContent = onlineCount;
    if (badgeCountAll) badgeCountAll.textContent = total;
  }

  function setListMode(mode) {
    state.listMode = mode;
    const btnLive = document.getElementById('btn-mode-live');
    const btnAll = document.getElementById('btn-mode-all');
    const cardTitle = document.getElementById('card-monitor-title');

    if (btnLive && btnAll) {
      if (mode === 'live') {
        btnLive.style.background = 'var(--primary)';
        btnLive.style.color = '#fff';
        btnAll.style.background = 'transparent';
        btnAll.style.color = 'var(--text-dim)';
        if (cardTitle) cardTitle.innerHTML = '&#x1F5A5;&#xFE0F; Pemantauan Peserta Ujian Sedang Login (Live Real-Time)';
      } else {
        btnAll.style.background = 'var(--primary)';
        btnAll.style.color = '#fff';
        btnLive.style.background = 'transparent';
        btnLive.style.color = 'var(--text-dim)';
        if (cardTitle) cardTitle.innerHTML = '&#x1F465; Direktori Semua Akun Siswa Terdaftar (LMS Moodle)';
      }
    }
    rebuildVersionFilterAndSummary();
    renderLiveMonitorTable();
  }

  /* ─── APP VERSION & DEVICE HELPERS ───────────────────────────────────────── */
  function getEffectivePlatform(u) {
    const ct = (u.client_type || '').toLowerCase();
    if (ct === 'android' || ct === 'ios') return ct;
    const dp = (u.device_platform || u.platform || '').toLowerCase();
    if (dp === 'android' || dp === 'ios') return dp;
    return '';
  }

  function getVersionKey(u) {
    const ver = (u.app_version || '').trim();
    const build = parseInt(u.app_build || 0, 10) || 0;
    if (ver.toLowerCase() === 'legacy') return 'legacy';
    if (!ver && build <= 0) return 'unknown';
    const plat = getEffectivePlatform(u) || 'app';
    return `${plat}|${ver || 'v?'}|${build}`;
  }

  function formatVersionLabel(ver, build) {
    const cleanVer = (ver || '').trim();
    const numBuild = parseInt(build || 0, 10) || 0;
    if (cleanVer.toLowerCase() === 'legacy') return 'Versi Lama (<2.8.0)';
    if (!cleanVer && numBuild <= 0) return 'Belum tercatat';
    const vText = cleanVer ? (cleanVer.startsWith('v') ? cleanVer : `v${cleanVer}`) : 'App';
    return numBuild > 0 ? `${vText} (b${numBuild})` : vText;
  }

  function computeLatestBuildByPlatform(users) {
    const latest = { android: 0, ios: 0 };
    (users || []).forEach(u => {
      const plat = getEffectivePlatform(u);
      const build = parseInt(u.app_build || 0, 10) || 0;
      if ((plat === 'android' || plat === 'ios') && build > (latest[plat] || 0)) {
        latest[plat] = build;
      }
    });
    return latest;
  }

  function isOutdatedVersion(u, latestByPlatform) {
    const ver = (u.app_version || '').trim().toLowerCase();
    if (ver === 'legacy') return true;
    const build = parseInt(u.app_build || 0, 10) || 0;
    if (!ver && build <= 0) return false;
    const plat = getEffectivePlatform(u);
    const minBuild = plat === 'ios'
      ? (state.pluginConfig.min_ios_build || 0)
      : (plat === 'android' ? (state.pluginConfig.min_android_build || 0) : 0);
    if (minBuild > 0 && build > 0 && build < minBuild) return true;
    if (minBuild > 0 && build === 0) return true;
    const maxObserved = (latestByPlatform && plat) ? (latestByPlatform[plat] || 0) : 0;
    return maxObserved > 0 && build > 0 && build < maxObserved;
  }

  function renderAppVersionBadge(appVersion, appBuild, platform, latestByPlatform) {
    const ver = (appVersion || '').trim();
    const build = parseInt(appBuild || 0, 10) || 0;
    const plat = (platform || '').toLowerCase();

    if (ver.toLowerCase() === 'legacy') {
      return '<span class="badge badge-danger" style="font-size:0.7rem; padding:2px 7px;" title="APK versi lama sebelum v2.8.0 (tidak mengirim metadata versi). Rentan kendala gambar/upload, wajib update!">&#x26A0;&#xFE0F; Versi Lama (&lt;2.8.0)</span>';
    }
    if (!ver && build <= 0) {
      return '<span class="badge badge-secondary" style="font-size:0.7rem; padding:2px 7px; opacity:0.65;" title="Akan tercatat otomatis saat siswa login ulang menggunakan versi terbaru">Versi belum tercatat</span>';
    }

    const label = formatVersionLabel(ver, build);
    const minBuild = plat === 'ios'
      ? (state.pluginConfig.min_ios_build || 0)
      : (plat === 'android' ? (state.pluginConfig.min_android_build || 0) : 0);
    const maxObserved = (latestByPlatform && plat) ? (latestByPlatform[plat] || 0) : 0;

    if (minBuild > 0 && build < minBuild) {
      return `<span class="badge badge-danger" style="font-size:0.7rem; padding:2px 7px;" title="Di bawah batas minimum server (build ${minBuild}+)">&#x26A0;&#xFE0F; ${escapeHtml(label)}</span>`;
    }
    if (maxObserved > 0 && build > 0 && build < maxObserved) {
      return `<span class="badge badge-warning" style="font-size:0.7rem; padding:2px 7px;" title="Sudah ada build lebih baru terdeteksi (build ${maxObserved})">${escapeHtml(label)}</span>`;
    }
    return `<span class="badge badge-success" style="font-size:0.7rem; padding:2px 7px;">&#x2705; ${escapeHtml(label)}</span>`;
  }

  function getActiveModeUsers() {
    if (state.listMode === 'live') {
      return state.liveUsers.filter(u =>
        (u.is_online === 1) || (u.lock_status === 2 || u.lock_status === 3) || (u.current_quizid > 0) || isUserUnresponsive(u)
      );
    }
    return state.liveUsers;
  }

  function rebuildVersionFilterAndSummary() {
    const versionSelect = document.getElementById('filter-version');
    const summaryBar = document.getElementById('version-summary-bar');
    const scopeUsers = getActiveModeUsers();
    const latestByPlatform = computeLatestBuildByPlatform(state.liveUsers);

    const groups = new Map();
    let outdatedCount = 0;
    let unknownCount = 0;

    scopeUsers.forEach(u => {
      const key = getVersionKey(u);
      const plat = getEffectivePlatform(u);
      const ver = (u.app_version || '').trim();
      const build = parseInt(u.app_build || 0, 10) || 0;

      if (isOutdatedVersion(u, latestByPlatform)) {
        outdatedCount++;
      }
      if (key === 'unknown') {
        unknownCount++;
        return;
      }

      if (!groups.has(key)) {
        const platPrefix = plat === 'ios' ? 'iOS' : (plat === 'android' ? 'Android' : 'App');
        const label = key === 'legacy'
          ? 'Versi Lama (<2.8.0)'
          : `${platPrefix} ${formatVersionLabel(ver, build)}`;
        groups.set(key, {
          key,
          plat,
          build,
          label,
          count: 0,
          outdated: isOutdatedVersion(u, latestByPlatform),
          isLegacy: key === 'legacy',
        });
      }
      groups.get(key).count += 1;
    });

    const sortedGroups = Array.from(groups.values()).sort((a, b) => {
      if (a.isLegacy !== b.isLegacy) return a.isLegacy ? 1 : -1;
      if (a.plat !== b.plat) return a.plat.localeCompare(b.plat);
      return b.build - a.build;
    });

    if (versionSelect) {
      const currentVal = versionSelect.value;
      let html = '<option value="">Semua Versi Aplikasi</option>';
      if (outdatedCount > 0) {
        html += `<option value="__outdated__">&#x26A0;&#xFE0F; Versi Lama / Perlu Update (${outdatedCount})</option>`;
      }
      sortedGroups.forEach(g => {
        html += `<option value="${escapeHtml(g.key)}">${escapeHtml(g.label)} (${g.count})</option>`;
      });
      if (unknownCount > 0) {
        html += `<option value="__unknown__">Belum Tercatat (${unknownCount})</option>`;
      }
      versionSelect.innerHTML = html;
      const validValues = new Set(['', '__outdated__', '__unknown__', ...sortedGroups.map(g => g.key)]);
      versionSelect.value = validValues.has(currentVal) ? currentVal : '';
    }

    if (summaryBar) {
      if (scopeUsers.length === 0) {
        summaryBar.style.display = 'none';
        summaryBar.innerHTML = '';
        return;
      }

      const activeFilter = versionSelect ? versionSelect.value : '';
      let pillsHtml = '<span style="font-size:0.75rem; font-weight:600; color:var(--text-muted); margin-right:4px;">Distribusi Versi App:</span>';

      sortedGroups.forEach(g => {
        const isActive = activeFilter === g.key;
        const badgeCls = g.isLegacy ? 'badge-danger' : (g.outdated ? 'badge-warning' : 'badge-success');
        const activeStyle = isActive ? 'outline:2px solid #fff; transform:scale(1.03);' : 'opacity:0.9;';
        const platIcon = g.plat === 'ios' ? '&#x1F34E; ' : (g.plat === 'android' ? '&#x1F916; ' : '');
        pillsHtml += `<button type="button" class="badge ${badgeCls}" onclick="DosmanApp.setVersionFilter('${escapeJs(g.key)}')" style="cursor:pointer; font-size:0.74rem; padding:4px 10px; ${activeStyle}" title="Klik untuk memfilter versi ini">${platIcon}${escapeHtml(g.label)}: <strong>${g.count}</strong></button>`;
      });

      if (unknownCount > 0) {
        const isActive = activeFilter === '__unknown__';
        const activeStyle = isActive ? 'outline:2px solid #fff;' : 'opacity:0.75;';
        pillsHtml += `<button type="button" class="badge badge-secondary" onclick="DosmanApp.setVersionFilter('__unknown__')" style="cursor:pointer; font-size:0.74rem; padding:4px 10px; ${activeStyle}" title="Siswa belum login dengan versi pelapor terbaru">Belum tercatat: <strong>${unknownCount}</strong></button>`;
      }

      if (activeFilter) {
        pillsHtml += `<button type="button" class="btn btn-secondary btn-sm" onclick="DosmanApp.setVersionFilter('')" style="padding:2px 8px; font-size:0.72rem; margin-left:auto;">&#x2715; Reset Filter Versi</button>`;
      }

      summaryBar.innerHTML = pillsHtml;
      summaryBar.style.display = 'flex';
    }
  }

  function setVersionFilter(val) {
    const versionSelect = document.getElementById('filter-version');
    if (!versionSelect) return;
    versionSelect.value = (versionSelect.value === val) ? '' : val;
    rebuildVersionFilterAndSummary();
    renderLiveMonitorTable();
  }

  function rebuildClassFilterOptions() {
    const classSelect = document.getElementById('filter-class');
    if (!classSelect) return;

    const gradeSelect = document.getElementById('filter-grade');
    const selectedGrade = gradeSelect ? gradeSelect.value : '';
    const currentVal = classSelect.value;

    const classes = new Set();

    state.liveUsers.forEach(u => {
      // If a grade is selected, only show classes from that grade
      if (selectedGrade) {
        const uGrade = (u.grade || '').trim();
        const uClass = (u.class_name || '').trim();
        const uYear = (u.tahun_masuk || '').trim();

        let matchGrade = (uGrade === selectedGrade);
        if (!matchGrade) {
          if (selectedGrade === 'Kelas X') {
            matchGrade = uGrade.includes('Kelas X') || uClass.startsWith('X ') || uYear === '2025';
          } else if (selectedGrade === 'Kelas XI') {
            matchGrade = uGrade.includes('Kelas XI') || uClass.startsWith('XI') || uYear === '2024';
          } else if (selectedGrade === 'Kelas XII') {
            matchGrade = uGrade.includes('Kelas XII') || uClass.startsWith('XII') || uYear === '2023';
          } else if (selectedGrade === 'Guru / Staf') {
            matchGrade = uGrade.includes('Guru') || uClass === 'Guru' || uClass === 'TIM IT';
          }
        }
        if (!matchGrade) return;
      }

      const cls = (u.class_name || '').trim();
      if (cls && cls !== 'Tidak Ada Kelas' && cls !== 'Guru') {
        classes.add(cls);
      }
    });

    // Natural sort: X 1 .. X 10, XI A .. XI D2, etc.
    const sorted = Array.from(classes).sort((a, b) => {
      return a.localeCompare(b, 'id', { numeric: true, sensitivity: 'base' });
    });

    let html = '<option value="">Semua Kelas (Cohort)</option>';
    sorted.forEach(cls => {
      html += `<option value="${escapeHtml(cls)}">${escapeHtml(cls)}</option>`;
    });

    classSelect.innerHTML = html;
    if (currentVal && (sorted.includes(currentVal) || currentVal === '')) {
      classSelect.value = currentVal;
    } else {
      classSelect.value = '';
    }
  }

  function isUserUnresponsive(u) {
    if (!u || u.lock_status === 2 || u.lock_status === 3) return false;
    if (typeof u.is_unresponsive !== 'undefined') return u.is_unresponsive === 1;
    const age = (u.lastping > 0) ? (Math.floor(Date.now() / 1000) - u.lastping) : -1;
    if (u.current_quizid > 0 && (age < 0 || age >= 95)) return true;
    return u.is_online === 1 && age >= 95;
  }

  function getFilteredLiveUsers() {
    const searchInput = document.getElementById('search-live');
    const q = (searchInput ? searchInput.value : '').trim().toLowerCase();

    const gradeSelect = document.getElementById('filter-grade');
    const selectedGrade = gradeSelect ? gradeSelect.value : '';

    const classSelect = document.getElementById('filter-class');
    const selectedClass = classSelect ? classSelect.value : '';

    const statusSelect = document.getElementById('filter-status');
    const selectedStatus = statusSelect ? statusSelect.value : '';

    const platformSelect = document.getElementById('filter-platform');
    const selectedPlatform = platformSelect ? platformSelect.value : '';

    const versionSelect = document.getElementById('filter-version');
    const selectedVersion = versionSelect ? versionSelect.value : '';
    const latestByPlatform = computeLatestBuildByPlatform(state.liveUsers);

    return state.liveUsers.filter(u => {
      // 0. Mode Filter (Sedang Login / Live vs Semua Akun Terdaftar)
      if (state.listMode === 'live') {
        const isLive = (u.is_online === 1) || (u.lock_status === 2 || u.lock_status === 3) || (u.current_quizid > 0) || isUserUnresponsive(u);
        if (!isLive) return false;
      }

      // 1. Platform filter
      if (selectedPlatform) {
        const effPlat = getEffectivePlatform(u);
        if (selectedPlatform === 'android' && effPlat !== 'android') return false;
        if (selectedPlatform === 'ios' && effPlat !== 'ios') return false;
      }

      // 1b. App version filter
      if (selectedVersion) {
        const vKey = getVersionKey(u);
        if (selectedVersion === '__outdated__') {
          if (!isOutdatedVersion(u, latestByPlatform)) return false;
        } else if (selectedVersion === '__unknown__') {
          if (vKey !== 'unknown') return false;
        } else if (vKey !== selectedVersion) {
          return false;
        }
      }

      // 2. Grade (Tingkat) filter
      if (selectedGrade) {
        const uGrade = (u.grade || '').trim();
        const uClass = (u.class_name || '').trim();
        const uYear = (u.tahun_masuk || '').trim();

        let matchGrade = (uGrade === selectedGrade);
        if (!matchGrade) {
          if (selectedGrade === 'Kelas X') {
            matchGrade = uGrade.includes('Kelas X') || uClass.startsWith('X ') || uYear === '2025';
          } else if (selectedGrade === 'Kelas XI') {
            matchGrade = uGrade.includes('Kelas XI') || uClass.startsWith('XI') || uYear === '2024';
          } else if (selectedGrade === 'Kelas XII') {
            matchGrade = uGrade.includes('Kelas XII') || uClass.startsWith('XII') || uYear === '2023';
          } else if (selectedGrade === 'Guru / Staf') {
            matchGrade = uGrade.includes('Guru') || uClass === 'Guru' || uClass === 'TIM IT';
          }
        }
        if (!matchGrade) return false;
      }

      // 3. Class / Cohort (Rombel) filter
      if (selectedClass) {
        const uClass = (u.class_name || '').trim();
        const uCohort = (u.cohort_names || '').trim();
        const uLastname = (u.lastname || '').trim();
        const uDept = (u.department || '').trim();

        const matchClass = uClass.toLowerCase() === selectedClass.toLowerCase() ||
                           uCohort.toLowerCase().includes(selectedClass.toLowerCase()) ||
                           uLastname.toLowerCase().includes(selectedClass.toLowerCase()) ||
                           uDept.toLowerCase() === selectedClass.toLowerCase();
        if (!matchClass) return false;
      }

      // 4. Status filter
      if (selectedStatus === 'online') {
        if (u.is_online !== 1) return false;
      } else if (selectedStatus === 'inquiz') {
        if (!(u.current_quizid > 0)) return false;
      } else if (selectedStatus === 'unresponsive') {
        if (!isUserUnresponsive(u)) return false;
      } else if (selectedStatus === 'standby') {
        if (!(u.current_quizid === 0 && u.is_online === 1 && !isUserUnresponsive(u))) return false;
      } else if (selectedStatus === 'paused') {
        if (u.lock_status !== 3) return false;
      } else if (selectedStatus === 'blocked') {
        if (u.lock_status !== 2) return false;
      } else if (selectedStatus === 'offline') {
        if (u.is_online === 1 || u.lock_status === 2 || u.lock_status === 3 || isUserUnresponsive(u)) return false;
      }

      // 5. Search keyword filter
      if (q) {
        const studentName = (u.student_name || '').toLowerCase();
        const firstname = (u.firstname || '').toLowerCase();
        const lastname = (u.lastname || '').toLowerCase();
        const noAbsen = (u.no_absen || '').toLowerCase();
        const fullname = `${firstname} ${lastname}`;
        const username = (u.username || '').toLowerCase();
        const idnumber = (u.idnumber || '').toLowerCase();
        const email = (u.email || '').toLowerCase();
        const quizName = (u.quiz_name || '').toLowerCase();
        const className = (u.class_name || '').toLowerCase();
        const cohortNames = (u.cohort_names || '').toLowerCase();
        const gradeName = (u.grade || '').toLowerCase();
        const tahunMasuk = (u.tahun_masuk || '').toLowerCase();
        const appVer = (u.app_version || '').toLowerCase();
        const appBuildStr = u.app_build ? String(u.app_build) : '';
        const deviceModel = (u.device_model || '').toLowerCase();

        const cleanQ = q.replace(/[\s\-_.,]+/g, '');
        const cleanStudent = studentName.replace(/[\s\-_.,]+/g, '');
        const cleanFirst = firstname.replace(/[\s\-_.,]+/g, '');
        const cleanFull = fullname.replace(/[\s\-_.,]+/g, '');

        const matches = studentName.includes(q) ||
                        cleanStudent.includes(cleanQ) ||
                        firstname.includes(q) ||
                        cleanFirst.includes(cleanQ) ||
                        lastname.includes(q) ||
                        fullname.includes(q) ||
                        cleanFull.includes(cleanQ) ||
                        noAbsen === q ||
                        (noAbsen && ('absen ' + noAbsen).includes(q)) ||
                        username.includes(q) ||
                        idnumber.includes(q) ||
                        email.includes(q) ||
                        quizName.includes(q) ||
                        className.includes(q) ||
                        cohortNames.includes(q) ||
                        gradeName.includes(q) ||
                        tahunMasuk.includes(q) ||
                        appVer.includes(q) ||
                        (appBuildStr && appBuildStr.includes(q)) ||
                        deviceModel.includes(q);

        if (!matches) return false;
      }

      return true;
    });
  }

  function renderLiveMonitorTable() {
    const tbody = document.getElementById('live-monitor-tbody');
    const countBadge = document.getElementById('filtered-count');
    if (!tbody) return;

    const filtered = getFilteredLiveUsers();
    if (countBadge) {
      if (state.listMode === 'live') {
        countBadge.textContent = `${filtered.length} peserta sedang login (Live)`;
      } else {
        countBadge.textContent = `${filtered.length} dari ${state.liveUsers.length} total akun siswa terdaftar`;
      }
    }

    if (filtered.length === 0) {
      if (state.listMode === 'live') {
        tbody.innerHTML = `
          <tr>
            <td colspan="8">
              <div class="empty-state" style="padding:45px 20px; text-align:center;">
                <div class="empty-icon" style="font-size:2.8rem; margin-bottom:10px;">🟢</div>
                <div class="empty-title" style="font-size:1.15rem; font-weight:700; color:#fff;">Tidak Ada Siswa yang Sedang Login</div>
                <div class="empty-desc" style="color:var(--text-dim); max-width:540px; margin:8px auto 16px; font-size:0.875rem; line-height:1.5;">
                  Saat ini belum ada siswa yang membuka aplikasi CBT dan terhubung ke server ujian Moodle. Sesi login siswa akan otomatis muncul secara real-time di sini begitu mereka masuk.
                </div>
                <button class="btn btn-secondary btn-sm" onclick="DosmanApp.setListMode('all')" style="display:inline-flex; align-items:center; gap:6px;">
                  <span>👥 Buka Direktori Semua Akun Siswa (857 Terdaftar)</span>
                </button>
              </div>
            </td>
          </tr>
        `;
      } else {
        tbody.innerHTML = `
          <tr>
            <td colspan="8">
              <div class="empty-state" style="padding:45px 20px; text-align:center;">
                <div class="empty-icon" style="font-size:2.8rem; margin-bottom:10px;">📋</div>
                <div class="empty-title" style="font-size:1.15rem; font-weight:700; color:#fff;">Tidak Ada Siswa Sesuai Filter</div>
                <div class="empty-desc" style="color:var(--text-dim); max-width:500px; margin:8px auto 16px; font-size:0.875rem;">
                  Tidak ditemukan siswa yang sesuai dengan kata kunci atau filter Moodle yang dipilih.
                </div>
              </div>
            </td>
          </tr>
        `;
      }
      return;
    }

    let rowsHtml = '';
    const latestByPlatform = computeLatestBuildByPlatform(state.liveUsers);
    filtered.forEach((u, idx) => {
      const isBlocked = u.lock_status === 2;
      const isPaused = u.lock_status === 3;
      const isOnline = u.is_online === 1;
      const isUnresponsive = isUserUnresponsive(u);
      const hasActiveQuiz = u.current_quizid > 0;
      const isOnQuiz = isOnline && hasActiveQuiz;
      const hasClient = isOnline || isUnresponsive;
      const isIOS = hasClient && (u.client_type === 'ios');
      const isAndroid = hasClient && (u.client_type === 'android');

      // Status Badge
      let statusBadge = '';
      if (isBlocked) {
        statusBadge = '<span class="badge badge-danger">&#x1F534; Terblokir</span>';
      } else if (isPaused) {
        statusBadge = '<span class="badge badge-warning">&#x23F8;&#xFE0F; Dijeda</span>';
      } else if (isUnresponsive && hasActiveQuiz) {
        statusBadge = '<span class="badge badge-warning" style="background:rgba(245,158,11,0.22); color:#fbbf24; border:1px solid rgba(245,158,11,0.55);" title="HP tidak mengirim ping lebih dari 95 detik saat kuis masih berlangsung (kemungkinan keluar aplikasi / force-close / sinyal putus)">&#x26A0;&#xFE0F; Tidak Merespons</span>';
      } else if (isUnresponsive) {
        statusBadge = '<span class="badge badge-warning" title="HP tidak mengirim ping lebih dari 95 detik">&#x26A0;&#xFE0F; Tidak Merespons</span>';
      } else if (isOnQuiz) {
        statusBadge = '<span class="badge badge-success">&#x270D;&#xFE0F; Sedang Kuis</span>';
      } else if (isOnline) {
        statusBadge = '<span class="badge badge-info">🟢 Online (Standby)</span>';
      } else {
        statusBadge = '<span class="badge badge-secondary" style="opacity:0.55;">&#x26AA; Belum Login</span>';
      }

      // Platform Badge: Tampilkan iOS/Android saat online, atau perangkat terakhir di direktori
      const effPlat = getEffectivePlatform(u);
      let platformBadge = '';
      if (hasClient) {
        if (isIOS) {
          platformBadge = '<span class="badge badge-ios">&#x1F34E; iOS / Apple</span>';
        } else if (isAndroid) {
          platformBadge = '<span class="badge badge-android">&#x1F916; Android</span>';
        } else if (u.client_type === 'cbt_app') {
          platformBadge = '<span class="badge badge-primary">&#x1F4F1; CBT App</span>';
        } else {
          platformBadge = '<span class="badge badge-secondary" style="opacity:0.55;">&#x1F4F1; Tidak diketahui</span>';
        }
      } else if (effPlat === 'ios') {
        platformBadge = '<span class="badge badge-ios" style="opacity:0.65;" title="Perangkat terakhir saat offline">&#x1F34E; iOS (Offline)</span>';
      } else if (effPlat === 'android') {
        platformBadge = '<span class="badge badge-android" style="opacity:0.65;" title="Perangkat terakhir saat offline">&#x1F916; Android (Offline)</span>';
      } else {
        platformBadge = '<span class="badge badge-secondary" style="opacity:0.5;">— (Offline)</span>';
      }

      const versionBadgeHtml = (hasClient || u.app_version || u.app_build > 0)
        ? renderAppVersionBadge(u.app_version, u.app_build, effPlat, latestByPlatform)
        : '';
      const deviceModelHtml = u.device_model
        ? `<span style="font-size:0.71rem; color:var(--text-dim); max-width:170px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;" title="Model HP: ${escapeHtml(u.device_model)}">${escapeHtml(u.device_model)}</span>`
        : '';
      const deviceCellHtml = `
        <div style="display:flex; flex-direction:column; align-items:flex-start; gap:4px;">
          ${platformBadge}
          ${versionBadgeHtml}
          ${deviceModelHtml}
        </div>
      `;

      // Pisahkan 4 Komponen Data: No Absen, Nama Bersih, Kelas, dan Tahun Masuk
      let noAbsen = (u.no_absen || '').trim();
      let studentName = (u.student_name || '').trim();
      let className = (u.class_name || '').trim();
      let tahunMasuk = (u.tahun_masuk || '').trim();
      let gradeName = (u.grade || '').trim();

      // Fallback parsing jika backend belum ter-update
      if (!studentName || !noAbsen) {
        const rawF = (u.firstname || '').trim();
        const m = rawF.match(/^(\d{1,2})\s+(.+)$/);
        if (m) {
          if (!noAbsen) noAbsen = m[1].padStart(2, '0');
          if (!studentName) studentName = m[2].trim();
        } else if (!studentName) {
          studentName = rawF;
        }
      }
      if (studentName.includes('|')) {
        studentName = studentName.split('|')[0].trim();
      }
      if (!className || !tahunMasuk) {
        const rawL = `${u.firstname || ''} ${u.lastname || ''}`;
        const m2 = rawL.match(/\|\s*([^|]+?)\s*\|\s*(\d{4})/i);
        if (m2) {
          if (!className) className = m2[1].trim();
          if (!tahunMasuk) tahunMasuk = m2[2].trim();
        }
      }

      // Avatar: Tampilkan Nomor Absen jika ada (e.g. 08, 22), atau inisial nama
      const initials = (studentName.replace(/[^a-zA-Z]/g, '').substring(0, 2) || 'S').toUpperCase();
      const avatarText = noAbsen ? noAbsen : initials;
      const avatarBorder = isOnline ? 'border: 2px solid #10b981; box-shadow: 0 0 8px rgba(16,185,129,0.3);' : '';
      const avatarBg = noAbsen ? 'background: linear-gradient(135deg, #1e40af, #3b82f6); color: #ffffff; font-weight: 700; font-family: "JetBrains Mono", monospace;' : '';

      // Quiz cell
      const quizHtml = hasActiveQuiz
        ? `<strong style="color:${isUnresponsive ? '#fbbf24' : 'var(--primary)'}; font-size:0.825rem;">${escapeHtml(u.quiz_name || `Kuis #${u.current_quizid}`)}</strong>`
        : `<span style="color:var(--text-dim); font-size:0.8rem;">${isOnline ? 'Di Beranda Ujian' : 'Tidak Ada Ujian'}</span>`;

      // Live ping ticker (dot di luar .live-ticker-cell agar tidak tertimpa interval 1 detik)
      const netBadgeHtml = (isOnline && u.network_type)
        ? (u.network_type === 'local'
          ? ' <span class="badge badge-success" style="font-size:0.65rem; padding:1px 6px;" title="Terhubung via Wi-Fi / LAN Sekolah">&#x1F4F6; Lokal</span>'
          : ' <span class="badge badge-info" style="font-size:0.65rem; padding:1px 6px;" title="Terhubung via Internet / Kuota Seluler">&#x1F310; Online</span>')
        : '';
      let pingHtml = '';
      if (isUnresponsive) {
        const lastSeenTxt = u.lastping > 0
          ? `<span class="live-ticker-cell" data-lastping="${u.lastping}">${formatLastSeen(u.lastping)}</span>`
          : 'Tidak ada ping';
        pingHtml = `<span style="color:#fbbf24; font-weight:600; display:inline-flex; align-items:center; gap:5px; flex-wrap:wrap;"><span style="display:inline-block; width:7px; height:7px; border-radius:50%; background:#f59e0b;"></span> ${lastSeenTxt}</span>`;
      } else if (isOnline) {
        pingHtml = `<span style="color:#10b981; font-weight:600; display:inline-flex; align-items:center; gap:5px; flex-wrap:wrap;"><span style="display:inline-block; width:7px; height:7px; border-radius:50%; background:#10b981; animation:pulse 1.5s infinite;"></span> <span class="live-ticker-cell" data-lastping="${u.lastping || 0}">${formatLastSeen(u.lastping)}</span>${netBadgeHtml}</span>`;
      } else if (u.lastping > 0) {
        pingHtml = `<span class="live-ticker-cell" data-lastping="${u.lastping}" style="color:var(--text-dim); font-size:0.8rem;">${formatLastSeen(u.lastping)}</span>`;
      } else {
        pingHtml = `<span style="color:var(--text-dim); font-size:0.8rem; font-style:italic;">Belum ada sesi</span>`;
      }

      // Action buttons
      let actionButtons = '';
      if (isPaused) {
        actionButtons += `
          <button class="btn-action btn-action-unblock" onclick="DosmanApp.unblockStudent(${u.userid}, '${escapeJs(studentName)}')" title="Lanjutkan ujian siswa yang sedang dijeda">
            &#x25B6;&#xFE0F; Lanjutkan
          </button>
        `;
      } else if (isBlocked) {
        actionButtons += `
          <button class="btn-action btn-action-unblock" onclick="DosmanApp.unblockStudent(${u.userid}, '${escapeJs(studentName)}')" title="Buka blokir dan izinkan siswa kembali ujian">
            &#x1F513; Buka Kunci
          </button>
        `;
      } else if (isOnline || isUnresponsive) {
        actionButtons += `
          <button class="btn-action" style="background:rgba(245,158,11,0.15); color:#fbbf24; border:1px solid rgba(245,158,11,0.3);" onclick="DosmanApp.pauseStudent(${u.userid}, '${escapeJs(studentName)}')" title="Jeda ujian siswa sementara">
            &#x23F8;&#xFE0F; Jeda
          </button>
        `;
      }

      if (u.lastping > 0 || isOnline || isUnresponsive || isBlocked || isPaused) {
        actionButtons += `
          <button class="btn-action btn-action-reset" onclick="DosmanApp.resetStudentSession(${u.userid}, '${escapeJs(studentName)}')" title="Reset sesi aplikasi (paksa login ulang)">
            &#x1F504; Reset
          </button>
        `;
      }

      actionButtons += `
        <button class="btn-action btn-action-suspend" onclick="DosmanApp.suspendStudent(${u.userid}, '${escapeJs(studentName)}')" title="Kunci akun Moodle (pelanggaran)">
          &#x26D4; Suspend
        </button>
      `;

      const rowBgStyle = (isUnresponsive && hasActiveQuiz)
        ? 'background: rgba(245,158,11,0.08);'
        : (isUnresponsive ? 'background: rgba(245,158,11,0.04);' : (isOnline ? 'background: rgba(16,185,129,0.03);' : ''));

      rowsHtml += `
        <tr style="${rowBgStyle}">
          <td style="color:var(--text-dim); font-size:0.8rem; font-family:'JetBrains Mono';">${idx + 1}</td>
          <td>
            <div class="student-cell">
              <div class="student-avatar" style="${avatarBorder} ${avatarBg}" title="${noAbsen ? 'Nomor Absen: ' + noAbsen : 'Inisial Peserta'}">${escapeHtml(avatarText)}</div>
              <div class="student-meta">
                <div style="display:flex; align-items:center; gap:6px; flex-wrap:wrap;">
                  ${noAbsen ? `<span class="badge" style="background:rgba(59,130,246,0.18); color:#60a5fa; border:1px solid rgba(59,130,246,0.35); font-size:0.75rem; padding:1px 6px; font-weight:700; border-radius:4px;" title="Nomor Absen di Kelas">Absen ${escapeHtml(noAbsen)}</span>` : ''}
                  <span class="student-name" style="font-weight:600; color:#ffffff; font-size:0.925rem;">${escapeHtml(studentName)}</span>
                </div>
                <span class="student-sub">
                  @${escapeHtml(u.username || '')}
                  ${u.idnumber ? ` &bull; <span style="color:var(--text-dim);">NIS: ${escapeHtml(u.idnumber)}</span>` : ''}
                  ${tahunMasuk ? ` &bull; <span style="color:#94a3b8;" title="Tahun Penerimaan Siswa">Angkatan ${escapeHtml(tahunMasuk)}</span>` : ''}
                </span>
              </div>
            </div>
          </td>
          <td>
            <div style="display:flex; flex-direction:column; gap:2px;">
              <span class="badge badge-primary" style="font-weight:600; width:max-content;">${escapeHtml(className || u.department || '—')}</span>
              <div style="font-size:0.725rem; color:var(--text-dim); display:flex; align-items:center; gap:4px;">
                <span>${escapeHtml(gradeName || 'Moodle Cohort')}</span>
                ${tahunMasuk ? `<span>&bull; Th. ${escapeHtml(tahunMasuk)}</span>` : ''}
              </div>
            </div>
          </td>
          <td>${deviceCellHtml}</td>
          <td>${statusBadge}</td>
          <td>${quizHtml}</td>
          <td>
            ${pingHtml}
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
    const latestByPlatform = computeLatestBuildByPlatform(state.liveUsers);
    state.deviceBlocked.forEach((d, idx) => {
      const name = `${d.firstname || ''} ${d.lastname || ''}`.trim() || d.username || 'Siswa';
      const reason = d.block_reason || 'Terdeteksi keluar dari aplikasi / minimize';
      const timeStr = d.blocked_at ? new Date(d.blocked_at * 1000).toLocaleTimeString('id-ID') : '—';
      const escSecs = d.seconds_until_escalation ?? 0;
      const escalateText = escSecs > 0 ? `Auto-suspend dalam ${Math.ceil(escSecs / 60)} mnt` : 'Siap eskalasi';
      const dPlat = (d.platform || '').toLowerCase();
      const dPlatBadge = dPlat === 'ios'
        ? '<span class="badge badge-ios">&#x1F34E; iOS</span>'
        : (dPlat === 'android'
          ? '<span class="badge badge-android">&#x1F916; Android</span>'
          : '<span class="badge badge-secondary" style="opacity:0.6;">&#x1F4F1; Perangkat</span>');
      const verBadge = renderAppVersionBadge(d.app_version, d.app_build, dPlat, latestByPlatform);

      html += `
        <tr>
          <td style="color:var(--text-dim); font-size:0.8rem; font-family:'JetBrains Mono';">${idx + 1}</td>
          <td>
            <div class="student-meta">
              <span class="student-name">${escapeHtml(name)}</span>
              <span class="student-sub">ID: ${d.userid} &bull; Model: ${escapeHtml(d.model || 'Unknown Device')}</span>
              <div style="margin-top:4px; display:flex; align-items:center; gap:6px; flex-wrap:wrap;">
                ${dPlatBadge}
                ${verBadge}
              </div>
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
      const reason = (s.reason || '').toLowerCase();
      const appVer = (s.app_version || '').toLowerCase();
      const appBuild = s.app_build ? String(s.app_build) : '';
      const plat = (s.platform || '').toLowerCase();
      const model = (s.device_model || '').toLowerCase();
      return name.includes(q) || uname.includes(q) || email.includes(q) || reason.includes(q)
        || appVer.includes(q) || (appBuild && appBuild.includes(q)) || plat.includes(q) || model.includes(q);
    });

    if (countEl) countEl.textContent = `${filtered.length} akun`;

    if (filtered.length === 0) {
      tbody.innerHTML = `
        <tr>
          <td colspan="8">
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
    const latestByPlatform = computeLatestBuildByPlatform(state.liveUsers);
    filtered.forEach((s, idx) => {
      const name = `${s.firstname || ''} ${s.lastname || ''}`.trim() || s.username;
      const isSelected = state.selectedSuspendedIds.has(s.userid);
      const timeStr = s.timemodified ? new Date(s.timemodified * 1000).toLocaleString('id-ID') : '—';
      const reasonText = (s.reason || '').trim() || 'Disuspend oleh pengawas / sistem';
      const sPlat = (s.platform || '').toLowerCase();
      const platBadge = sPlat === 'ios'
        ? '<span class="badge badge-ios">&#x1F34E; iOS / Apple</span>'
        : (sPlat === 'android'
          ? '<span class="badge badge-android">&#x1F916; Android</span>'
          : '<span class="badge badge-secondary" style="opacity:0.55;">— Tidak diketahui</span>');
      const verBadge = renderAppVersionBadge(s.app_version, s.app_build, sPlat, latestByPlatform);
      const modelHtml = s.device_model
        ? `<span style="font-size:0.71rem; color:var(--text-dim); max-width:170px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;" title="Model HP: ${escapeHtml(s.device_model)}">${escapeHtml(s.device_model)}</span>`
        : '';

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
          <td>
            <div style="display:flex; flex-direction:column; align-items:flex-start; gap:4px;">
              ${platBadge}
              ${verBadge}
              ${modelHtml}
            </div>
          </td>
          <td>
            <span style="display:inline-block; padding:4px 8px; border-radius:6px; background:rgba(239,68,68,0.14); border:1px solid rgba(239,68,68,0.3); color:#fca5a5; font-size:0.78rem; line-height:1.35;">
              ${escapeHtml(reasonText)}
            </span>
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

  /* ─── PROCTOR RESCUE CODE (TAB 3) ─────────────────────────────────────────── */
  async function loadRescueCode() {
    const input = document.getElementById('rescue-code-input');
    const statusText = document.getElementById('rescue-code-status');
    if (!input) return;

    try {
      if (statusText) statusText.textContent = 'Memuat kode darurat proktor...';
      const res = await fetch('../local/dosman_ujian/rescue_code.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        cache: 'no-store',
        body: JSON.stringify({
          token: state.token,
          action: 'get'
        })
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();

      if (data.success && typeof data.code === 'string') {
        input.value = data.code;
        if (statusText) {
          statusText.innerHTML = `<span style="color:var(--success);">&#x2705; Kode darurat aktif (${data.code.length} karakter) &bull; Klik ikon mata di atas untuk melihat.</span>`;
        }
      } else {
        throw new Error(data.message || 'Gagal memuat kode darurat');
      }
    } catch (e) {
      if (statusText) {
        statusText.innerHTML = `<span style="color:var(--danger);">&#x274C; Gagal memuat kode darurat: ${escapeHtml(e.message)}</span>`;
      }
    }
  }

  async function saveRescueCode(newCode) {
    const statusText = document.getElementById('rescue-code-status');
    if (statusText) statusText.textContent = 'Menyimpan kode darurat ke server...';

    try {
      const res = await fetch('../local/dosman_ujian/rescue_code.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          action: 'set',
          code: newCode
        })
      });
      const data = await res.json();

      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Kode Darurat Tersimpan!',
          text: `Kode Kirim Darurat Proktor diperbarui: "${newCode}"`,
          timer: 2200,
          showConfirmButton: false
        });
        loadRescueCode();
      } else {
        throw new Error(data.message || 'Gagal menyimpan kode darurat');
      }
    } catch (e) {
      Swal.fire({
        icon: 'error',
        title: 'Gagal Menyimpan Kode Darurat',
        text: e.message
      });
      if (statusText) {
        statusText.innerHTML = `<span style="color:var(--danger);">&#x274C; ${escapeHtml(e.message)}</span>`;
      }
    }
  }

  function setupRescueCodeControls() {
    const toggleBtn = document.getElementById('btn-toggle-rescue');
    const input = document.getElementById('rescue-code-input');
    if (toggleBtn && input) {
      toggleBtn.addEventListener('click', function () {
        state.rescueCodeVisible = !state.rescueCodeVisible;
        input.type = state.rescueCodeVisible ? 'text' : 'password';
        toggleBtn.innerHTML = state.rescueCodeVisible ? '&#x1F648;' : '&#x1F441;';
      });
    }

    const btnGen = document.getElementById('btn-rescue-random');
    if (btnGen) {
      btnGen.addEventListener('click', function () {
        const randomNum = String(Math.floor(100000 + Math.random() * 900000));
        if (input) {
          input.value = randomNum;
          input.type = 'text';
          state.rescueCodeVisible = true;
          if (toggleBtn) toggleBtn.innerHTML = '&#x1F648;';
        }
        saveRescueCode(randomNum);
      });
    }

    const btnSave = document.getElementById('btn-rescue-save');
    if (btnSave) {
      btnSave.addEventListener('click', function () {
        const val = input ? input.value.trim() : '';
        if (val.length < 4) {
          Swal.fire({
            icon: 'warning',
            title: 'Kode Terlalu Pendek',
            text: 'Kode Kirim Darurat Proktor minimal 4 karakter.'
          });
          return;
        }
        saveRescueCode(val);
      });
    }
  }

  /* ─── NETWORK ACCESS MODE (LOKAL/OFFLINE VS ONLINE) ──────────────────────── */
  function updateNetworkModeUI() {
    const isLocalOnly = state.networkAccessMode === 'local_only';
    const quickBtn = document.getElementById('btn-network-mode-quick');
    if (quickBtn) {
      if (isLocalOnly) {
        quickBtn.className = 'btn btn-danger btn-sm';
        quickBtn.innerHTML = '&#x1F512; Mode: Lokal/Offline Saja';
        quickBtn.title = 'Klik untuk membuka akses agar bisa juga lewat Internet/Kuota (Online)';
      } else {
        quickBtn.className = 'btn btn-success btn-sm';
        quickBtn.innerHTML = '&#x1F310; Mode: Lokal &amp; Online';
        quickBtn.title = 'Klik untuk memaksa siswa hanya bisa akses lewat Wi-Fi EXAM DOSMAN (Lokal/Offline)';
      }
    }

    const statusEl = document.getElementById('network-mode-status');
    if (statusEl) {
      if (isLocalOnly) {
        statusEl.innerHTML = '<span style="color:#f87171;">&#x1F512; AKTIF: LOKAL / OFFLINE SAJA</span><div style="font-size:0.78rem; color:var(--text-muted); margin-top:4px; font-family:inherit;">Siswa hanya dapat login &amp; memulai ujian lewat Wi-Fi lokal sekolah (EXAM DOSMAN / LAN). Akses data seluler/luar ditolak.</div>';
      } else {
        statusEl.innerHTML = '<span style="color:#34d399;">&#x1F310; AKTIF: LOKAL &amp; ONLINE</span><div style="font-size:0.78rem; color:var(--text-muted); margin-top:4px; font-family:inherit;">Siswa dapat mengikuti ujian baik dari Wi-Fi lokal sekolah maupun dari Internet / kuota seluler.</div>';
      }
    }

    const btnLocal = document.getElementById('btn-net-local-only');
    const btnBoth = document.getElementById('btn-net-both');
    if (btnLocal && btnBoth) {
      btnLocal.style.outline = isLocalOnly ? '2px solid #fff' : 'none';
      btnLocal.style.opacity = isLocalOnly ? '1' : '0.78';
      btnBoth.style.outline = !isLocalOnly ? '2px solid #fff' : 'none';
      btnBoth.style.opacity = !isLocalOnly ? '1' : '0.78';
    }
  }

  async function loadNetworkMode() {
    try {
      const res = await fetch('../local/dosman_ujian/network_mode.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        cache: 'no-store',
        body: JSON.stringify({
          token: state.token,
          action: 'get'
        })
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (data.success && (data.mode === 'local_only' || data.mode === 'both')) {
        state.networkAccessMode = data.mode;
        state.pluginConfig.network_access_mode = data.mode;
        updateNetworkModeUI();
      }
    } catch (e) {
      const statusEl = document.getElementById('network-mode-status');
      if (statusEl) {
        statusEl.innerHTML = `<span style="color:var(--danger);">&#x274C; Gagal memuat mode jaringan: ${escapeHtml(e.message)}</span>`;
      }
    }
  }

  async function saveNetworkMode(targetMode) {
    const isLocalOnly = targetMode === 'local_only';
    const confirmRes = await Swal.fire({
      title: isLocalOnly ? 'Paksa Mode Lokal / Offline Saja?' : 'Izinkan Akses Lokal & Online?',
      html: isLocalOnly
        ? 'Siswa yang mengakses menggunakan <strong>data seluler / internet luar</strong> akan otomatis ditolak dan diminta menyambung ke Wi-Fi lokal sekolah (<strong>EXAM DOSMAN</strong>).<br><br><small style="color:#94a3b8;">Guru, Proktor, Admin, dan Dashboard tetap bisa diakses dari mana saja.</small>'
        : 'Siswa akan kembali diizinkan login dan mengikuti ujian baik melalui <strong>Wi-Fi lokal sekolah</strong> maupun <strong>Internet / kuota seluler</strong>.',
      icon: isLocalOnly ? 'warning' : 'question',
      showCancelButton: true,
      confirmButtonText: isLocalOnly ? 'Ya, Paksa Lokal Saja' : 'Ya, Izinkan Online & Lokal',
      cancelButtonText: 'Batal',
      confirmButtonColor: isLocalOnly ? '#f59e0b' : '#10b981',
      cancelButtonColor: '#475569',
    });

    if (!confirmRes.isConfirmed) return;

    try {
      const res = await fetch('../local/dosman_ujian/network_mode.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          action: 'set',
          mode: targetMode
        })
      });
      const data = await res.json();
      if (!res.ok || !data.success) {
        throw new Error(data.message || `Gagal mengubah mode jaringan (HTTP ${res.status})`);
      }

      state.networkAccessMode = data.mode === 'local_only' ? 'local_only' : 'both';
      state.pluginConfig.network_access_mode = state.networkAccessMode;
      updateNetworkModeUI();

      Swal.fire({
        icon: 'success',
        title: 'Mode Jaringan Diperbarui!',
        text: data.message || 'Pengaturan berhasil disimpan.',
        timer: 2200,
        showConfirmButton: false
      });
      loadLiveUsers();
    } catch (e) {
      Swal.fire({
        icon: 'error',
        title: 'Gagal Mengubah Mode',
        text: e.message
      });
    }
  }

  function toggleNetworkModeQuick() {
    const nextMode = state.networkAccessMode === 'local_only' ? 'both' : 'local_only';
    saveNetworkMode(nextMode);
  }

  function setupNetworkModeControls() {
    updateNetworkModeUI();
    const btnLocal = document.getElementById('btn-net-local-only');
    const btnBoth = document.getElementById('btn-net-both');
    if (btnLocal) {
      btnLocal.addEventListener('click', function () {
        saveNetworkMode('local_only');
      });
    }
    if (btnBoth) {
      btnBoth.addEventListener('click', function () {
        saveNetworkMode('both');
      });
    }
  }

  /* ─── FILTERS & SEARCH SETUP ─────────────────────────────────────────────── */
  function setupFilters() {
    const searchLive = document.getElementById('search-live');
    if (searchLive) {
      searchLive.value = '';
      searchLive.addEventListener('input', renderLiveMonitorTable);

      // Bersihkan autofill browser (Chrome/Edge Password Manager sering otomatis mengisi username proktor ke input teks)
      const clearBrowserAutofill = () => {
        const val = (searchLive.value || '').trim();
        const uname = (state.username || '').trim();
        if (val && uname && val.toLowerCase() === uname.toLowerCase()) {
          searchLive.value = '';
          renderLiveMonitorTable();
        }
      };
      setTimeout(clearBrowserAutofill, 50);
      setTimeout(clearBrowserAutofill, 200);
      setTimeout(clearBrowserAutofill, 500);
    }

    const filterGrade = document.getElementById('filter-grade');
    if (filterGrade) {
      filterGrade.addEventListener('change', () => {
        rebuildClassFilterOptions();
        renderLiveMonitorTable();
      });
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

  async function pauseStudent(userId, name) {
    const res = await Swal.fire({
      title: 'Jeda Ujian Siswa?',
      html: `Ujian <strong>${escapeHtml(name)}</strong> akan dijeda sementara.<br><small style="color:var(--text-muted)">Layar HP siswa akan tertutup pemberitahuan jeda sampai Anda melanjutkannya.</small>`,
      icon: 'warning',
      showCancelButton: true,
      confirmButtonText: 'Ya, Jeda Ujian',
      cancelButtonText: 'Batal',
      confirmButtonColor: '#f59e0b',
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
          lock_status: 3
        })
      });
      const data = await response.json();
      if (data.success) {
        Swal.fire({
          icon: 'success',
          title: 'Ujian Dijeda',
          text: `Sesi ujian "${name}" berhasil dijeda.`,
          timer: 2000,
          showConfirmButton: false
        });
        loadLiveUsers();
      } else {
        throw new Error(data.error || 'Gagal menjeda ujian siswa');
      }
    } catch (e) {
      Swal.fire({ icon: 'error', title: 'Error', text: e.message });
    }
  }

  /* ─── BROADCAST ANNOUNCEMENT ────────────────────────────────────────────── */
  function openBroadcastModal() {
    const modal = document.getElementById('modal-broadcast');
    if (!modal) return;

    modal.style.display = 'flex';

    // Reset input & alert
    const inputMsg = document.getElementById('bc-input-message');
    if (inputMsg) {
      inputMsg.value = '';
      setTimeout(() => inputMsg.focus(), 100);
    }
    setBroadcastFeedback('', '');

    // Fetch status siaran aktif secara background
    loadActiveBroadcastStatus();
  }

  function closeBroadcastModal() {
    const modal = document.getElementById('modal-broadcast');
    if (modal) modal.style.display = 'none';
  }

  async function loadActiveBroadcastStatus() {
    const activeBox  = document.getElementById('bc-active-container');
    const activeText = document.getElementById('bc-active-text');
    const activeMeta = document.getElementById('bc-active-meta');
    if (!activeBox) return;

    try {
      const res = await fetch(`../local/dosman_ujian/broadcast_message.php?token=${encodeURIComponent(state.token || '')}&t=${Date.now()}`);
      if (res.ok) {
        const d = await res.json();
        if (d.broadcast) {
          activeBox.style.display = 'block';
          if (activeText) activeText.textContent = `"${d.broadcast.message}"`;
          if (activeMeta) {
            const expDate = new Date(d.broadcast.expires_at * 1000);
            activeMeta.textContent = `Disiarkan oleh: ${d.broadcast.sender || 'Proktor'} • Berakhir pukul ${expDate.toLocaleTimeString('id-ID')}`;
          }
          return;
        }
      }
    } catch (_) {}

    activeBox.style.display = 'none';
  }

  async function submitBroadcast() {
    const inputMsg  = document.getElementById('bc-input-message');
    const selectDur = document.getElementById('bc-select-duration');
    const btnSubmit = document.getElementById('btn-submit-broadcast');

    const msg = (inputMsg ? inputMsg.value : '').trim();
    if (!msg) {
      setBroadcastFeedback('Tuliskan pesan pengumuman terlebih dahulu!', 'error');
      if (inputMsg) inputMsg.focus();
      return;
    }

    const dur = selectDur ? parseInt(selectDur.value, 10) : 1800;

    if (btnSubmit) {
      btnSubmit.disabled = true;
      btnSubmit.innerHTML = '<span>⏳ Mengirim Siaran...</span>';
    }

    try {
      const resp = await fetch('../local/dosman_ujian/broadcast_message.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          apikey: API_KEY,
          message: msg,
          expires_in: dur,
          duration_minutes: Math.round(dur / 60),
          sender: state.username || 'Proktor CBT'
        })
      });

      const resData = await resp.json();
      if (resData.success) {
        setBroadcastFeedback('✅ Pengumuman berhasil dikirim ke seluruh HP siswa!', 'success');
        loadActiveBroadcastStatus();
        if (inputMsg) inputMsg.value = '';
        setTimeout(() => {
          closeBroadcastModal();
        }, 1500);
      } else {
        setBroadcastFeedback(resData.message || 'Gagal mengirim pengumuman', 'error');
      }
    } catch (e) {
      setBroadcastFeedback('Gagal menghubungi server: ' + e.message, 'error');
    } finally {
      if (btnSubmit) {
        btnSubmit.disabled = false;
        btnSubmit.innerHTML = '<span>🚀 Kirim ke Semua Siswa</span>';
      }
    }
  }

  async function retractBroadcast() {
    const btnRetract = document.getElementById('btn-retract-broadcast');
    if (btnRetract) {
      btnRetract.disabled = true;
      btnRetract.textContent = 'Menarik...';
    }

    try {
      const resp = await fetch('../local/dosman_ujian/broadcast_message.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token: state.token,
          apikey: API_KEY,
          retract: true,
          message: ''
        })
      });

      const resData = await resp.json();
      if (resData.success) {
        setBroadcastFeedback('ℹ️ Pengumuman aktif berhasil ditarik.', 'info');
        const activeBox = document.getElementById('bc-active-container');
        if (activeBox) activeBox.style.display = 'none';
      } else {
        setBroadcastFeedback(resData.message || 'Gagal menarik pengumuman', 'error');
      }
    } catch (e) {
      setBroadcastFeedback('Gagal menghubungi server: ' + e.message, 'error');
    } finally {
      if (btnRetract) {
        btnRetract.disabled = false;
        btnRetract.textContent = '🗑️ Tarik Siaran';
      }
    }
  }

  function setBroadcastFeedback(msg, type) {
    const alertEl = document.getElementById('bc-feedback-alert');
    if (!alertEl) return;
    if (!msg) {
      alertEl.style.display = 'none';
      return;
    }

    alertEl.style.display = 'block';
    if (type === 'success') {
      alertEl.style.background = 'rgba(22,163,74,0.15)';
      alertEl.style.border = '1px solid rgba(34,197,94,0.3)';
      alertEl.style.color = '#4ade80';
    } else if (type === 'error') {
      alertEl.style.background = 'rgba(220,38,38,0.15)';
      alertEl.style.border = '1px solid rgba(239,68,68,0.3)';
      alertEl.style.color = '#f87171';
    } else {
      alertEl.style.background = 'rgba(59,130,246,0.15)';
      alertEl.style.border = '1px solid rgba(96,165,250,0.3)';
      alertEl.style.color = '#93c5fd';
    }
    alertEl.textContent = msg;
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
    pauseStudent: pauseStudent,
    openBroadcastModal: openBroadcastModal,
    closeBroadcastModal: closeBroadcastModal,
    submitBroadcast: submitBroadcast,
    retractBroadcast: retractBroadcast,
    resetStudentSession: resetStudentSession,
    suspendStudent: suspendStudent,
    unsuspendStudent: unsuspendStudent,
    unblockDevice: unblockDevice,
    toggleSuspendedSelect: toggleSuspendedSelect,
    setListMode: setListMode,
    setVersionFilter: setVersionFilter,
    toggleNetworkModeQuick: toggleNetworkModeQuick,
    setNetworkMode: saveNetworkMode,
    onGradeChange: function() {
      rebuildClassFilterOptions();
      renderLiveMonitorTable();
    },
    onClassChange: function() {
      renderLiveMonitorTable();
    },
    onFilterChange: function() {
      rebuildVersionFilterAndSummary();
      renderLiveMonitorTable();
    },
    refreshData: function() {
      state.countdown = 10;
      refreshAllData(false);
    },
  };

  // Launch when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
