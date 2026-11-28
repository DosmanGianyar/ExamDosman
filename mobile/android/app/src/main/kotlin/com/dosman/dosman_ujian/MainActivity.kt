package com.dosman.dosman_ujian

import android.app.ActivityManager
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val lockdownChannel = "com.dosman.ujian/lockdown"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val guardState = KioskGuardStateMachine()

    private var backLocked = false
    private var pinLoopOn = false
    private var currentUserId: Int = 0
    private var alarmToneGenerator: ToneGenerator? = null
    private var alarmRunnable: Runnable? = null
    private var unpinAlarmCount = 0
    private var audioDeviceCallback: AudioDeviceCallback? = null

    // Runnable bernama agar bisa dibatalkan di stopKiosk() jika belum terpicu.
    private val startPinLoopDelayed: Runnable = Runnable { startPinLoop() }

    // Filter DND sebelum ujian dimulai — dikembalikan saat exitLockTask.
    private var previousDndFilter = NotificationManager.INTERRUPTION_FILTER_UNKNOWN

    // Referensi channel untuk mengirim event ke Flutter (split-screen, unpin, bluetooth, dll.).
    private var flutterChannel: MethodChannel? = null

    private fun isDeviceOwner(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        return dpm.isDeviceOwnerApp(packageName)
    }

    private fun whitelistLockTask() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val comp = ComponentName(this, ExamDeviceAdmin::class.java)
            if (dpm.isDeviceOwnerApp(packageName)) {
                dpm.setLockTaskPackages(comp, arrayOf(packageName))
            }
        } catch (_: Exception) {}
    }

    /**
     * Panggil startLockTask() dengan debounce: pesan "App pinned" hanya tampil
     * sekali per [cooldownMs], berapapun kali fungsi ini dipanggil.
     */
    private fun startLockTaskDebounced(): Boolean {
        if (!guardState.tryConsumeStartLockTaskCooldown()) return false
        try { whitelistLockTask() } catch (_: Exception) {}
        try { startLockTask() } catch (_: Exception) {}
        return true
    }

    /** Pin app saat pertama masuk kiosk. Debounced agar pesan "App pinned" hanya muncul sekali. */
    private fun requestPin() {
        if (!guardState.kioskActive) return
        startLockTaskDebounced()
    }

    /**
     * Loop 1 detik: pantau apakah lock task masih aktif, dan cegah kecurangan:
     * - Pinned screen dilepas
     * - Split-screen / floating window
     * - Virtual machine (VMOS, VPhone, dll.)
     * - Dual apps / cloned apps
     */
    private val pinLoop: Runnable = object : Runnable {
        override fun run() {
            val vmResult = ExamSecurityGuard.detectVirtualEnvironment(
                this@MainActivity,
                guardState.isReviewerAccount,
            )
            val action = guardState.evaluatePinLoopTick(
                pinLoopOn = pinLoopOn,
                isLockTaskActive = ExamSecurityGuard.isLockTaskActive(this@MainActivity),
                isSplitScreen = ExamSecurityGuard.isSplitScreenOrFloating(this@MainActivity),
                isVirtualEnv = vmResult.isVirtual,
                isClonedApp = ExamSecurityGuard.isClonedOrDualApp(
                    this@MainActivity,
                    guardState.isReviewerAccount,
                ),
            )

            when (action) {
                KioskGuardStateMachine.PinLoopAction.UNPIN_VIOLATION -> {
                    forceMaxVolume()
                    playUnpinAlert()
                    triggerNativeStudentSuspension(
                        currentUserId,
                        "Siswa memaksa melepas pinned screen (alarm aktif)",
                    )
                    mainHandler.post {
                        flutterChannel?.invokeMethod("onLockTaskLost", null)
                    }
                    stopKiosk()
                    return
                }
                KioskGuardStateMachine.PinLoopAction.SPLIT_SCREEN_VIOLATION -> {
                    forceMaxVolume()
                    playUnpinAlert()
                    triggerNativeStudentSuspension(
                        currentUserId,
                        "Siswa menggunakan split screen / floating window saat ujian",
                    )
                    mainHandler.post {
                        flutterChannel?.invokeMethod("onSplitScreenDetected", null)
                    }
                    stopKiosk()
                    return
                }
                KioskGuardStateMachine.PinLoopAction.VIRTUAL_ENV_VIOLATION -> {
                    forceMaxVolume()
                    val detail = "${ExamSecurityGuard.deviceLabel()} | ${vmResult.describe()}"
                    triggerNativeStudentSuspension(
                        currentUserId,
                        "Siswa menjalankan aplikasi di Virtual Machine [$detail]",
                    )
                    mainHandler.post {
                        flutterChannel?.invokeMethod(
                            "onVirtualEnvironmentDetected",
                            mapOf("detail" to detail),
                        )
                    }
                    stopKiosk()
                    return
                }
                KioskGuardStateMachine.PinLoopAction.CLONED_APP_VIOLATION -> {
                    forceMaxVolume()
                    triggerNativeStudentSuspension(
                        currentUserId,
                        "Siswa menjalankan aplikasi di Dual App / Ruang Ganda",
                    )
                    mainHandler.post {
                        flutterChannel?.invokeMethod("onClonedAppDetected", null)
                    }
                    stopKiosk()
                    return
                }
                KioskGuardStateMachine.PinLoopAction.NONE -> Unit
            }

            if (guardState.kioskActive && pinLoopOn && !guardState.isReviewerAccount) {
                mainHandler.postDelayed(this, 1_000L)
            }
        }
    }

    private fun startPinLoop() {
        mainHandler.removeCallbacks(pinLoop)
        pinLoopOn = true
        mainHandler.post(pinLoop)
    }

    private fun stopKiosk() {
        mainHandler.removeCallbacks(pinLoop)
        mainHandler.removeCallbacks(startPinLoopDelayed)
        pinLoopOn = false
        guardState.resetOnStopKiosk()
        unregisterBluetoothAudioListener()
    }

    private fun registerBluetoothAudioListener() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val callback = object : AudioDeviceCallback() {
                    override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                        val hasBt = addedDevices?.any { dev ->
                            ExamSecurityGuard.isBluetoothAudioDeviceType(dev.type, Build.VERSION.SDK_INT)
                        } == true
                        if (hasBt && guardState.shouldDispatchBluetoothViolation()) {
                            mainHandler.post {
                                flutterChannel?.invokeMethod("onBluetoothAudioConnected", null)
                            }
                        }
                    }
                }
                audioDeviceCallback = callback
                am.registerAudioDeviceCallback(callback, mainHandler)
            } catch (_: Exception) {}
        }
    }

    private fun unregisterBluetoothAudioListener() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioDeviceCallback?.let {
                    am.unregisterAudioDeviceCallback(it)
                }
                audioDeviceCallback = null
            } catch (_: Exception) {}
        }
    }

    /**
     * Paksa volume STREAM_ALARM ke maksimum dan ringer mode ke normal.
     * Dipisah blok try-catch agar kegagalan ubah ringerMode (bila izin DND belum
     * diberikan) tidak membatalkan penaikan volume STREAM_ALARM.
     */
    private fun forceMaxVolume() {
        val am = try {
            getSystemService(Context.AUDIO_SERVICE) as AudioManager
        } catch (_: Exception) {
            return
        }
        try {
            am.ringerMode = AudioManager.RINGER_MODE_NORMAL
        } catch (_: Exception) {}
        try {
            val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, maxVol, 0)
        } catch (_: Exception) {}
    }

    private fun stopUnpinAlert() {
        alarmRunnable?.let { mainHandler.removeCallbacks(it) }
        alarmRunnable = null
        try { alarmToneGenerator?.stopTone() } catch (_: Exception) {}
        try { alarmToneGenerator?.release() } catch (_: Exception) {}
        alarmToneGenerator = null
    }

    /**
     * Putar nada alarm mendesak sebanyak 10x berulang (~10 detik) saat siswa
     * melepas pin layar / split screen saat ujian aktif.
     */
    private fun playUnpinAlert() {
        try {
            stopUnpinAlert()
            disableDnd()
            forceMaxVolume()
            alarmToneGenerator = ToneGenerator(AudioManager.STREAM_ALARM, 100)
            unpinAlarmCount = 0
            val runnable = object : Runnable {
                override fun run() {
                    if (unpinAlarmCount < 10) {
                        try {
                            forceMaxVolume()
                            val gen = alarmToneGenerator ?: ToneGenerator(AudioManager.STREAM_ALARM, 100).also {
                                alarmToneGenerator = it
                            }
                            gen.stopTone()
                            gen.startTone(ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK, 800)
                        } catch (_: Exception) {}
                        unpinAlarmCount++
                        mainHandler.postDelayed(this, 1_000L)
                    } else {
                        stopUnpinAlert()
                    }
                }
            }
            alarmRunnable = runnable
            mainHandler.post(runnable)
        } catch (_: Exception) {}
    }

    /**
     * Kirim permintaan suspend akun siswa langsung dari native background thread.
     */
    private fun triggerNativeStudentSuspension(
        userId: Int,
        reason: String = "Siswa memaksa melepas pinned screen (alarm aktif)",
    ) {
        if (userId <= 0 || guardState.isReviewerAccount) return
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
                    put("reason", reason)
                }

                conn.outputStream.use { os ->
                    os.write(json.toString().toByteArray(Charsets.UTF_8))
                }
                val code = conn.responseCode
                android.util.Log.i("DosmanExam", "Native suspend student $userId ($reason) HTTP status: $code")
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

    /** Aktifkan DND saat kiosk dimulai — simpan filter sebelumnya untuk di-restore. */
    private fun enableDnd() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            previousDndFilter = nm.currentInterruptionFilter
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE)
        } catch (_: Exception) {}
    }

    private fun openDndSettingsWithFallback(): Boolean {
        for (intent in ExamSecurityGuard.buildDndSettingsIntents(packageName)) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {}
        }
        return false
    }

    /** Kembalikan DND ke kondisi sebelum ujian saat kiosk dimatikan. */
    private fun disableDnd() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.setInterruptionFilter(ExamSecurityGuard.resolveDndRestoreFilter(previousDndFilter))
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

    override fun onResume() {
        super.onResume()
        if (!guardState.kioskActive) return
        try { hideSystemBars() } catch (_: Exception) {}
        if (guardState.isReviewerAccount) return
        if (guardState.wasPinnedSuccessfully) forceMaxVolume()

        if (guardState.inExamMode && ExamSecurityGuard.isSplitScreenOrFloating(this)) {
            forceMaxVolume()
            playUnpinAlert()
            triggerNativeStudentSuspension(
                currentUserId,
                "Siswa menggunakan split screen / floating window saat ujian",
            )
            mainHandler.post {
                flutterChannel?.invokeMethod("onSplitScreenDetected", null)
            }
            stopKiosk()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && guardState.kioskActive) {
            try { hideSystemBars() } catch (_: Exception) {}
            try { window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) } catch (_: Exception) {}
        }
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        if (guardState.inExamMode && isInMultiWindowMode && guardState.kioskActive && !guardState.isReviewerAccount) {
            forceMaxVolume()
            playUnpinAlert()
            triggerNativeStudentSuspension(
                currentUserId,
                "Siswa menggunakan split screen / floating window saat ujian",
            )
            mainHandler.post {
                flutterChannel?.invokeMethod("onSplitScreenDetected", null)
            }
            stopKiosk()
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (backLocked) return
        super.onBackPressed()
    }

    override fun onDestroy() {
        stopKiosk()
        stopUnpinAlert()
        super.onDestroy()
    }

    // ── MethodChannel ─────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            lockdownChannel,
        )
        flutterChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {

                "setReviewerMode" -> {
                    guardState.isReviewerAccount = call.argument<Boolean>("isReviewer") ?: false
                    result.success(true)
                }

                "setExamMode" -> {
                    guardState.inExamMode = call.argument<Boolean>("active") ?: false
                    result.success(true)
                }

                "getAndroidId" -> {
                    result.success(ExamSecurityGuard.getNormalizedAndroidId(this))
                }

                "checkVirtualEnvironment" -> {
                    result.success(
                        ExamSecurityGuard.isVirtualMachineOrEmulator(
                            this,
                            guardState.isReviewerAccount,
                        ),
                    )
                }

                "getVirtualEnvironmentDetail" -> {
                    val r = ExamSecurityGuard.detectVirtualEnvironment(
                        this,
                        guardState.isReviewerAccount,
                    )
                    result.success(
                        mapOf(
                            "isVirtual" to r.isVirtual,
                            "detail" to "${ExamSecurityGuard.deviceLabel()} | ${r.describe()}",
                        ),
                    )
                }

                "checkClonedApp" -> {
                    result.success(
                        ExamSecurityGuard.isClonedOrDualApp(
                            this,
                            guardState.isReviewerAccount,
                        ),
                    )
                }

                "isSplitScreenActive" -> {
                    result.success(ExamSecurityGuard.isSplitScreenOrFloating(this))
                }

                "enableLockdown" -> {
                    try {
                        // FLAG_SECURE: blokir screenshot & screen recording (hasil jadi hitam).
                        // Akun reviewer Play/App Store dikecualikan agar bisa mengambil tangkapan layar.
                        if (guardState.isReviewerAccount) {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
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
                        guardState.kioskActive = true
                        if (guardState.isReviewerAccount) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        enableDnd()
                        registerBluetoothAudioListener()
                        requestPin()
                        if (!isDeviceOwner()) {
                            mainHandler.postDelayed(startPinLoopDelayed, 3_000L)
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        stopKiosk()
                        result.success(false)
                    }
                }

                "exitLockTask" -> {
                    val preserveAlarm = call.argument<Boolean>("preserveAlarm") ?: false
                    stopKiosk()
                    if (!preserveAlarm) {
                        stopUnpinAlert()
                    }
                    disableDnd()
                    try { stopLockTask() } catch (_: Exception) {}
                    try { showSystemBars() } catch (_: Exception) {}
                    result.success(true)
                }

                "checkScreenCast" -> {
                    result.success(ExamSecurityGuard.isPresentationDisplayActive(this))
                }

                "lockBackButton" -> { backLocked = true; result.success(true) }
                "unlockBackButton" -> { backLocked = false; result.success(true) }

                "isScreenPinningEnabled" -> {
                    result.success(ExamSecurityGuard.isScreenPinningEnabled(this))
                }

                "openScreenPinningSettings" -> {
                    var opened = false
                    for (intent in ExamSecurityGuard.buildScreenPinningSettingsIntents()) {
                        try {
                            startActivity(intent)
                            opened = true; break
                        } catch (_: Exception) {}
                    }
                    result.success(opened)
                }

                "checkAccessibilityServices" -> {
                    result.success(ExamSecurityGuard.getSuspiciousAccessibilityServices(this))
                }

                "checkSecurityFlags" -> {
                    result.success(ExamSecurityGuard.checkSecurityFlags(this))
                }

                "checkRootStatus" -> {
                    result.success(ExamSecurityGuard.checkRootStatus(this))
                }

                "isLockTaskActive" -> {
                    result.success(ExamSecurityGuard.isLockTaskActive(this))
                }

                "requestScreenPin" -> {
                    try {
                        whitelistLockTask()
                        startLockTask()
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                "checkVpn" -> {
                    result.success(ExamSecurityGuard.checkVpnActive(this))
                }

                "checkBluetoothAudio" -> {
                    result.success(ExamSecurityGuard.isBluetoothAudioConnected(this))
                }

                "isScreenInteractive" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                    result.success(pm.isInteractive)
                }

                "isDndPermissionGranted" -> result.success(isDndGranted())

                "openDndSettings" -> result.success(openDndSettingsWithFallback())

                "openWifiSettings" -> {
                    val releaseLockTask = call.argument<Boolean>("releaseLockTask") ?: false
                    fun launchWifiPanel(): Boolean {
                        val candidates = mutableListOf<Intent>()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            candidates += Intent(Settings.Panel.ACTION_WIFI)
                            candidates += Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
                        }
                        candidates += Intent(Settings.ACTION_WIFI_SETTINGS)
                        for (intent in candidates) {
                            try {
                                startActivity(intent)
                                return true
                            } catch (_: Exception) {}
                        }
                        return false
                    }

                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val inLockTask = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
                    } else {
                        @Suppress("DEPRECATION")
                        am.isInLockTaskMode
                    }
                    if (inLockTask) {
                        if (!releaseLockTask || guardState.inExamMode) {
                            result.success(false)
                        } else {
                            guardState.wasPinnedSuccessfully = false
                            try { stopLockTask() } catch (_: Exception) {}
                            mainHandler.postDelayed(
                                { result.success(launchWifiPanel()) },
                                300L,
                            )
                        }
                    } else {
                        result.success(launchWifiPanel())
                    }
                }

                "openAppSettings" -> {
                    try {
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null),
                        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
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

                "getAppFilesDir" -> {
                    result.success(filesDir.absolutePath)
                }

                else -> result.notImplemented()
            }
        }
    }
}
