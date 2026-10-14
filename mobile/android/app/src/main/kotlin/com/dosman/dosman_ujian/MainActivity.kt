package com.dosman.dosman_ujian

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.app.NotificationManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.Settings
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val lockdownChannel = "com.dosman.ujian/lockdown"
    private val mainHandler = Handler(Looper.getMainLooper())

    private var kioskActive           = false   // kiosk sedang berjalan
    private var backLocked            = false   // Back button dikunci
    private var pinLoopOn             = false   // loop 1-detik berjalan
    private var wasPinnedSuccessfully = false   // true setelah lock task pertama kali aktif
    private var currentUserId: Int    = 0       // ID siswa yang sedang login
    private var alarmToneGenerator: ToneGenerator? = null
    private var unpinAlarmCount       = 0

    // Debounce startLockTask(): cegah pesan "App pinned" muncul berkali-kali saat startup.
    private var lastStartLockTaskMs     = 0L
    private val startLockTaskCooldownMs = 5_000L

    // Runnable bernama agar bisa dibatalkan di stopKiosk() jika belum terpicu.
    private val startPinLoopDelayed: Runnable = Runnable { startPinLoop() }

    // Filter DND sebelum ujian dimulai — dikembalikan saat exitLockTask
    private var previousDndFilter = NotificationManager.INTERRUPTION_FILTER_UNKNOWN

    // Referensi channel untuk mengirim event ke Flutter (split-screen, overlay, dll.)
    private var flutterChannel: MethodChannel? = null

    // Deteksi overlay: jika focus hilang lebih dari 5 detik saat kiosk aktif → overlay asing
    private var overlayCheckRunnable: Runnable? = null
    private val overlayThresholdMs   = 5_000L

    // Deteksi screen cast / mirroring: DisplayListener memantau display baru saat kiosk aktif
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            if (!kioskActive) return
            mainHandler.post {
                flutterChannel?.invokeMethod("onScreenCastDetected", null)
            }
        }
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {}
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun isLockTaskActive(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
    }

    private fun isDeviceOwner(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        return dpm.isDeviceOwnerApp(packageName)
    }

    private fun whitelistLockTask() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val dpm  = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val comp = ComponentName(this, ExamDeviceAdmin::class.java)
            if (dpm.isDeviceOwnerApp(packageName)) dpm.setLockTaskPackages(comp, arrayOf(packageName))
        } catch (_: Exception) {}
    }

    /**
     * Panggil startLockTask() dengan debounce: pesan "App pinned" hanya tampil
     * sekali per [startLockTaskCooldownMs] milidetik, berapapun kali fungsi ini dipanggil.
     * Return true jika startLockTask() benar-benar dieksekusi, false jika masih cooldown.
     */
    private fun startLockTaskDebounced(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastStartLockTaskMs < startLockTaskCooldownMs) return false
        lastStartLockTaskMs = now
        try { whitelistLockTask() } catch (_: Exception) {}
        try { startLockTask() }     catch (_: Exception) {}
        return true
    }

    /** Pin app saat pertama masuk kiosk. Debounced agar pesan "App pinned" hanya muncul sekali. */
    private fun requestPin() {
        if (!kioskActive) return
        startLockTaskDebounced()
    }

    /**
     * Loop 1 detik: pantau apakah lock task masih aktif.
     * Jika lock task hilang setelah berhasil pinned → bunyikan alarm, beritahu Flutter,
     * lalu tutup app. Tidak ada percobaan re-pin.
     */
    private val pinLoop: Runnable = object : Runnable {
        override fun run() {
            if (!kioskActive || !pinLoopOn) return
            if (!isLockTaskActive()) {
                if (wasPinnedSuccessfully) {
                    // Siswa berhasil mencabut pin → bunyikan alarm keras dan suspend akun siswa!
                    forceMaxVolume()
                    playUnpinAlert()

                    // Kirim HTTP POST suspend akun siswa dari native thread sebagai pengaman utama
                    triggerNativeStudentSuspension(currentUserId)

                    // Beritahu Flutter agar UI beralih ke BlockedScreen dan memproses suspensi
                    mainHandler.post {
                        flutterChannel?.invokeMethod("onLockTaskLost", null)
                    }
                    stopKiosk()
                    return
                }
                // Belum pernah berhasil pinned — masih dalam proses aktivasi awal, tunggu.
            } else {
                if (!wasPinnedSuccessfully) wasPinnedSuccessfully = true
            }
            mainHandler.postDelayed(this, 1_000L)
        }
    }

    private fun startPinLoop() {
        mainHandler.removeCallbacks(pinLoop)
        pinLoopOn = true
        mainHandler.post(pinLoop)
    }

    private fun stopKiosk() {
        mainHandler.removeCallbacks(pinLoop)
        mainHandler.removeCallbacks(startPinLoopDelayed)  // batalkan jika belum terpicu
        pinLoopOn             = false
        kioskActive           = false
        wasPinnedSuccessfully = false
        try {
            val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            dm.unregisterDisplayListener(displayListener)
        } catch (_: Exception) {}
    }

    /**
     * Paksa volume STREAM_ALARM ke maksimum dan ringer mode ke normal.
     * STREAM_ALARM berbunyi bahkan saat HP di-silent/vibrate — tidak butuh permission khusus
     * selain MODIFY_AUDIO_SETTINGS yang sudah ada di manifest.
     */
    private fun forceMaxVolume() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.ringerMode = AudioManager.RINGER_MODE_NORMAL
            val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, maxVol, 0)
        } catch (_: Exception) {}
    }

    /**
     * Putar nada alarm mendesak dan berulang saat siswa mencabut pin.
     * Menggunakan STREAM_ALARM volume maksimal agar terdengar jelas oleh pengawas di ruangan.
     */
    private fun playUnpinAlert() {
        try {
            forceMaxVolume()
            alarmToneGenerator?.release()
            alarmToneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100)
            unpinAlarmCount = 0
            val handler = Handler(Looper.getMainLooper())
            val alarmRunnable = object : Runnable {
                override fun run() {
                    if (unpinAlarmCount < 10) { // Bunyikan 10 kali berulang (~11 detik)
                        try {
                            forceMaxVolume()
                            alarmToneGenerator?.startTone(ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK, 850)
                        } catch (_: Exception) {}
                        unpinAlarmCount++
                        handler.postDelayed(this, 1100L)
                    } else {
                        try { alarmToneGenerator?.release() } catch (_: Exception) {}
                        alarmToneGenerator = null
                    }
                }
            }
            handler.post(alarmRunnable)
        } catch (_: Exception) {}
    }

    /**
     * Kirim permintaan suspend akun siswa langsung dari native background thread.
     */
    private fun triggerNativeStudentSuspension(userId: Int) {
        if (userId <= 0) return
        Thread {
            try {
                val url = java.net.URL("https://lms.sman1-gianyar.sch.id:9443/local/dosman_ujian/suspend_student.php")
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.doOutput = true

                val json = org.json.JSONObject().apply {
                    put("apikey", "dosman-exam-sman1gianyar-2024")
                    put("userid", userId)
                    put("reason", "Siswa memaksa melepas pinned screen (alarm aktif)")
                }

                conn.outputStream.use { os ->
                    os.write(json.toString().toByteArray(Charsets.UTF_8))
                }
                val code = conn.responseCode
                android.util.Log.i("DosmanExam", "Native suspend student $userId HTTP status: $code")
            } catch (e: Exception) {
                android.util.Log.e("DosmanExam", "Native suspend student error", e)
            }
        }.start()
    }

    // ── DND (Do Not Disturb) ──────────────────────────────────────────────────

    private fun isDndGranted(): Boolean {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.isNotificationPolicyAccessGranted
    }

    /** Aktifkan DND saat kiosk dimulai — simpan filter sebelumnya untuk di-restore.
     *  Guard isDndGranted() dihapus: beberapa ROM (Vivo FuntouchOS) melaporkan false
     *  meski user sudah memberi izin. Coba set filter langsung; tangkap SecurityException
     *  jika benar-benar tidak ada izin. */
    private fun enableDnd() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            previousDndFilter = nm.currentInterruptionFilter
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE)
        } catch (_: Exception) {}
    }

    /**
     * Buka halaman izin DND dengan 3 fallback intent.
     * Beberapa HP (Samsung, Xiaomi MIUI, OPPO ColorOS) memblokir intent pertama
     * sehingga perlu dicoba alternatifnya.
     *
     * Urutan:
     * 1. ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS — halaman khusus izin DND (standar Android)
     * 2. ACTION_APP_NOTIFICATION_SETTINGS          — pengaturan notifikasi per-app (Samsung/MIUI fallback)
     * 3. ACTION_APPLICATION_DETAILS_SETTINGS       — detail aplikasi (last resort)
     */
    private fun openDndSettingsWithFallback(): Boolean {
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        val candidates = listOf(
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                .apply { addFlags(flags) },
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .apply {
                    addFlags(flags)
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                },
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .apply {
                    addFlags(flags)
                    data = Uri.fromParts("package", packageName, null)
                },
        )
        for (intent in candidates) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) { /* coba berikutnya */ }
        }
        return false
    }

    /** Kembalikan DND ke kondisi sebelum ujian saat kiosk dimatikan. */
    private fun disableDnd() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val restore = if (
                previousDndFilter == NotificationManager.INTERRUPTION_FILTER_UNKNOWN ||
                previousDndFilter == NotificationManager.INTERRUPTION_FILTER_NONE
            ) {
                NotificationManager.INTERRUPTION_FILTER_ALL
            } else {
                previousDndFilter
            }
            nm.setInterruptionFilter(restore)
            previousDndFilter = NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        } catch (_: Exception) {}
    }

    // ── System bars ───────────────────────────────────────────────────────────

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun showSystemBars() {
        WindowInsetsControllerCompat(window, window.decorView)
            .show(WindowInsetsCompat.Type.systemBars())
        WindowCompat.setDecorFitsSystemWindows(window, true)
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /** Setiap kali app kembali ke depan: sembunyikan system bar, paksa volume alarm. */
    override fun onResume() {
        super.onResume()
        if (!kioskActive) return
        try { hideSystemBars() } catch (_: Exception) {}
        if (wasPinnedSuccessfully) forceMaxVolume()
        // Tidak ada requestPin() di sini — pin hanya sekali saat enterLockTask.
        // Deteksi unpin dan penutupan app ditangani oleh pinLoop.
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && kioskActive) {
            try { hideSystemBars() } catch (_: Exception) {}
            // Focus kembali — batalkan pengecekan overlay yang pending
            overlayCheckRunnable?.let { mainHandler.removeCallbacks(it) }
            overlayCheckRunnable = null
        } else if (!hasFocus && kioskActive && wasPinnedSuccessfully) {
            // Focus hilang saat kiosk aktif DAN app sudah berhasil terpinned.
            // Sebelum pinned, focus hilang karena dialog "App pinned" — wajar, bukan overlay.
            // Jadwalkan pengecekan: jika masih tidak ada focus setelah [overlayThresholdMs],
            // kemungkinan besar ada overlay app asing di atas layar ujian.
            overlayCheckRunnable?.let { mainHandler.removeCallbacks(it) }
            val check = Runnable {
                overlayCheckRunnable = null
                if (!hasWindowFocus() && kioskActive) {
                    flutterChannel?.invokeMethod("onOverlayDetected", null)
                }
            }
            overlayCheckRunnable = check
            mainHandler.postDelayed(check, overlayThresholdMs)
        }
    }

    /**
     * Deteksi split-screen / multi-window saat kiosk aktif.
     * Android 7.0+ (API 24) memungkinkan siswa membuka dua app bersamaan.
     * Ketika terdeteksi: coba re-pin (debounced) + kirim event ke Flutter untuk trigger blokir.
     */
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        if (isInMultiWindowMode && kioskActive) {
            // Coba paksa full-screen kembali (berhasil di beberapa device) — debounced
            startLockTaskDebounced()
            // Beritahu Flutter untuk memicu alur pelanggaran
            mainHandler.post {
                flutterChannel?.invokeMethod("onSplitScreenDetected", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (backLocked) return
        super.onBackPressed()
    }

    // ── MethodChannel ─────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            lockdownChannel
        )
        flutterChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {

                "enableLockdown" -> {
                    try {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCKDOWN_ERROR", e.message, null)
                    }
                }

                "disableLockdown" -> {
                    try {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCKDOWN_ERROR", e.message, null)
                    }
                }

                "setUserId" -> {
                    val uid = call.argument<Int>("userId") ?: 0
                    if (uid > 0) currentUserId = uid
                    result.success(true)
                }

                "enterLockTask" -> {
                    val uid = call.argument<Int>("userId") ?: 0
                    if (uid > 0) currentUserId = uid
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
                        result.success(false); return@setMethodCallHandler
                    }
                    try {
                        hideSystemBars()
                        kioskActive = true
                        enableDnd()
                        requestPin()  // tampilkan "App pinned" sekali di sini
                        if (!isDeviceOwner()) {
                            // Tunda loop 3 detik agar startLockTask() pertama sempat
                            // aktif sebelum loop mulai mengecek — mencegah re-pin langsung
                            // yang menampilkan pesan "App pinned" lagi.
                            mainHandler.postDelayed(startPinLoopDelayed, 3_000L)
                        }
                        // Mulai pantau display baru (screen cast / mirroring)
                        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                        dm.registerDisplayListener(displayListener, mainHandler)
                        result.success(true)
                    } catch (e: Exception) {
                        stopKiosk()
                        result.success(false)
                    }
                }

                "exitLockTask" -> {
                    stopKiosk()
                    disableDnd()
                    try { stopLockTask()   } catch (_: Exception) {}
                    try { showSystemBars() } catch (_: Exception) {}
                    result.success(true)
                }

                "checkScreenCast" -> {
                    // Cek apakah ada display tambahan (mirroring / Chromecast / screen recorder virtual display).
                    // Display.TYPE_BUILT_IN = 1 (layar fisik utama). Jika ada display lain, kemungkinan screen cast.
                    val casting = try {
                        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                        val displays = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
                        } else {
                            @Suppress("DEPRECATION")
                            dm.displays.filter { it.displayId != Display.DEFAULT_DISPLAY }
                                .toTypedArray()
                        }
                        displays.isNotEmpty()
                    } catch (_: Exception) { false }
                    result.success(casting)
                }

                "lockBackButton"   -> { backLocked = true;  result.success(true) }
                "unlockBackButton" -> { backLocked = false; result.success(true) }

                "isScreenPinningEnabled" -> result.success(
                    try { Settings.Secure.getInt(contentResolver, "lock_to_app_enabled", 0) == 1 }
                    catch (_: Exception) { false }
                )

                "openScreenPinningSettings" -> {
                    val candidates = listOf(
                        "android.settings.SCREEN_PINNING_SETTINGS",
                        Settings.ACTION_SECURITY_SETTINGS,
                        Settings.ACTION_SETTINGS,
                    )
                    var opened = false
                    for (action in candidates) {
                        try {
                            startActivity(Intent(action).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
                            opened = true; break
                        } catch (_: Exception) {}
                    }
                    result.success(opened)
                }

                "checkAccessibilityServices" -> {
                    // Kembalikan daftar accessibility service pihak ketiga yang aktif.
                    // Service sistem (com.android.*, android.*) dan app sendiri diabaikan.
                    val systemPrefixes = listOf(
                        "com.android.", "android.", "com.google.android.",
                        "com.samsung.android.", "com.miui.", "com.huawei.",
                    )
                    try {
                        val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
                        val active = am.getEnabledAccessibilityServiceList(
                            AccessibilityServiceInfo.FEEDBACK_ALL_MASK
                        )
                        val suspicious = active
                            .filter { info ->
                                val pkg = info.resolveInfo.serviceInfo.packageName
                                pkg != packageName &&
                                systemPrefixes.none { pkg.startsWith(it) }
                            }
                            .map { info ->
                                info.resolveInfo.serviceInfo
                                    .loadLabel(packageManager).toString()
                            }
                        result.success(suspicious)
                    } catch (_: Exception) {
                        result.success(emptyList<String>())
                    }
                }

                "checkSecurityFlags" -> {
                    // Cek USB Debugging dan Developer Options.
                    // Keduanya tidak butuh permission khusus — readable oleh semua app.
                    val adbEnabled = try {
                        Settings.Global.getInt(
                            contentResolver,
                            Settings.Global.ADB_ENABLED, 0
                        ) == 1
                    } catch (_: Exception) { false }

                    val devOptions = try {
                        Settings.Global.getInt(
                            contentResolver,
                            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0
                        ) == 1
                    } catch (_: Exception) { false }

                    result.success(mapOf(
                        "usbDebugging"  to adbEnabled,
                        "developerMode" to devOptions,
                    ))
                }

                "checkRootStatus" -> {
                    // Deteksi root tanpa library eksternal.
                    // Tiga sinyal independen: (1) su binary, (2) build tags, (3) root app packages.
                    // Minimal satu sinyal positif → kemungkinan besar device di-root.

                    // (1) Cari binary 'su' di path umum
                    val suPaths = listOf(
                        "/system/bin/su", "/system/xbin/su", "/sbin/su",
                        "/system/su", "/system/bin/.ext/su", "/system/usr/we-need-root/su",
                        "/system/app/Superuser.apk", "/data/local/su", "/data/local/bin/su",
                        "/data/local/xbin/su",
                    )
                    val suFound = suPaths.any { java.io.File(it).exists() }

                    // (2) Build tag "test-keys" — ROM custom/rooted sering tidak signed dengan release-keys
                    val testKeys = Build.TAGS?.contains("test-keys") == true

                    // (3) Paket root management apps yang umum dipakai
                    val rootPackages = listOf(
                        "com.topjohnwu.magisk",       // Magisk
                        "eu.chainfire.supersu",        // SuperSU
                        "com.koushikdutta.superuser",  // CWM Superuser
                        "com.noshufou.android.su",     // ChainsDD Superuser
                        "com.thirdparty.superuser",
                        "com.yellowes.su",
                        "com.kingroot.kinguser",       // KingRoot
                        "com.kingo.root",              // KingoRoot
                        "com.smedialink.oneclickroot",
                        "com.zhiqupk.root.global",
                        "com.alephzain.framaroot",
                    )
                    val rootAppFound = rootPackages.any { pkg ->
                        try {
                            packageManager.getPackageInfo(pkg, 0)
                            true
                        } catch (_: Exception) { false }
                    }

                    result.success(mapOf(
                        "suBinaryFound" to suFound,
                        "testKeys"      to testKeys,
                        "rootAppFound"  to rootAppFound,
                        "isRooted"      to (suFound || testKeys || rootAppFound),
                    ))
                }

                "isLockTaskActive" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                        result.success(true)
                    } else {
                        result.success(isLockTaskActive())
                    }
                }

                /** Tidak dipakai lagi — re-pin dihapus, app langsung tutup jika unpin. */
                "requestScreenPin" -> result.success(false)

                "checkVpn" -> {
                    // Cek apakah ada koneksi VPN aktif via NetworkCapabilities.
                    // TRANSPORT_VPN true = ada interface VPN terhubung saat ini.
                    val vpnActive = try {
                        val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                            as android.net.ConnectivityManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val active = cm.activeNetwork
                            val caps   = if (active != null) cm.getNetworkCapabilities(active) else null
                            caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true
                        } else {
                            @Suppress("DEPRECATION")
                            cm.activeNetworkInfo?.typeName?.contains("VPN", ignoreCase = true) == true
                        }
                    } catch (_: Exception) { false }
                    result.success(vpnActive)
                }

                "checkBluetoothAudio" -> {
                    try {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val isBt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                            devices.any { dev ->
                                dev.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                                dev.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && dev.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
                            }
                        } else {
                            @Suppress("DEPRECATION")
                            am.isBluetoothA2dpOn || am.isBluetoothScoOn
                        }
                        result.success(isBt)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                "isScreenInteractive" -> {
                    // true  = layar menyala & interaktif (siswa mungkin pindah app)
                    // false = layar mati / screen-off (siswa mungkin sedang mengerjakan soal di kertas)
                    val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                    result.success(pm.isInteractive)
                }

                "isDndPermissionGranted" -> result.success(isDndGranted())

                "openDndSettings" -> result.success(openDndSettingsWithFallback())

                "openWifiSettings" -> {
                    startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                    result.success(null)
                }

                "keepScreenOn" -> {
                    runOnUiThread {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }

                "clearScreenOn" -> {
                    runOnUiThread {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }
}
