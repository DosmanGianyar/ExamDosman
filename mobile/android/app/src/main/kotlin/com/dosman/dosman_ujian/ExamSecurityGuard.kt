package com.dosman.dosman_ujian

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.display.DisplayManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Display
import android.view.accessibility.AccessibilityManager
import androidx.annotation.VisibleForTesting
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.io.File

/**
 * State machine terpusat untuk status kiosk, cooldown lock task,
 * dedup event Bluetooth, serta keputusan pelanggaran loop 1-detik di Android.
 */
class KioskGuardStateMachine {

    var kioskActive: Boolean = false
    var inExamMode: Boolean = false
    var isReviewerAccount: Boolean = false
    var wasPinnedSuccessfully: Boolean = false
    var lastStartLockTaskMs: Long = 0L
        private set
    private var bluetoothViolationFired: Boolean = false

    enum class PinLoopAction {
        NONE,
        UNPIN_VIOLATION,
        SPLIT_SCREEN_VIOLATION,
        VIRTUAL_ENV_VIOLATION,
        CLONED_APP_VIOLATION,
    }

    /**
     * Debounce `startLockTask()` agar toast sistem "App pinned" tidak berulang.
     * Kembalikan `true` bila cooldown sudah lewat dan diperbolehkan mengeksekusi.
     */
    fun tryConsumeStartLockTaskCooldown(
        nowMs: Long = System.currentTimeMillis(),
        cooldownMs: Long = 5_000L,
    ): Boolean {
        if (lastStartLockTaskMs > 0L && (nowMs - lastStartLockTaskMs) < cooldownMs) {
            return false
        }
        lastStartLockTaskMs = nowMs
        return true
    }

    /**
     * Evaluasi satu tick loop pemantau pin (dipanggil tiap 1 detik dari UI thread).
     */
    fun evaluatePinLoopTick(
        pinLoopOn: Boolean,
        isLockTaskActive: Boolean,
        isSplitScreen: Boolean,
        isVirtualEnv: Boolean,
        isClonedApp: Boolean,
    ): PinLoopAction {
        if (!kioskActive || !pinLoopOn || isReviewerAccount) {
            return PinLoopAction.NONE
        }

        if (!isLockTaskActive) {
            if (wasPinnedSuccessfully) {
                if (inExamMode) {
                    return PinLoopAction.UNPIN_VIOLATION
                }
                // Baru di layar daftar mapel/kuis: reset status tanpa alarm/suspend.
                wasPinnedSuccessfully = false
            }
        } else {
            wasPinnedSuccessfully = true
        }

        if (inExamMode) {
            if (isSplitScreen) return PinLoopAction.SPLIT_SCREEN_VIOLATION
            if (isVirtualEnv) return PinLoopAction.VIRTUAL_ENV_VIOLATION
            if (isClonedApp) return PinLoopAction.CLONED_APP_VIOLATION
        }

        return PinLoopAction.NONE
    }

    /**
     * Deduplikasi event audio Bluetooth (mis. TWS yang mendaftarkan A2DP + SCO bersamaan)
     * agar `onBluetoothAudioConnected` hanya dipicu sekali per sesi kiosk aktif.
     */
    fun shouldDispatchBluetoothViolation(): Boolean {
        if (!kioskActive || !inExamMode || isReviewerAccount || bluetoothViolationFired) {
            return false
        }
        bluetoothViolationFired = true
        return true
    }

    /**
     * Reset seluruh flag saat kiosk berhenti agar sesi login/ujian berikutnya bersih,
     * termasuk mereset cooldown `lastStartLockTaskMs` bila logout & login ulang < 5 dtk.
     */
    fun resetOnStopKiosk() {
        kioskActive = false
        inExamMode = false
        wasPinnedSuccessfully = false
        lastStartLockTaskMs = 0L
        bluetoothViolationFired = false
    }
}

/**
 * Helper keamanan native Android yang terisolasi dari JNI FlutterEngine
 * agar dapat diuji langsung lewat Robolectric di banyak versi SDK.
 */
object ExamSecurityGuard {

    private const val EXPECTED_PACKAGE_NAME = "com.dosman.dosman_ujian"
    private const val SPLIT_AREA_RATIO_THRESHOLD = 0.72

    private val nonZeroUserRegex = Regex("""/user/([1-9]\d*)/""")
    private val androidAppInstallHashRegex = Regex(
        """(/app/)(?:~~[^/]+/)?(com\.dosman\.dosman_ujian)-[^/]+""",
    )
    private val anyAndroidAppInstallHashRegex = Regex(
        """(/data/app/)(?:~~[^/\s]+/)?([a-z0-9._]+)-[^/\s]+""",
    )

    /**
     * Kata kunci KUAT pada Build.* — hanya muncul di VM/emulator sungguhan,
     * tidak pernah dipakai ROM HP fisik (Samsung, Xiaomi, Vivo, Oppo, Itel, Infinix, dll).
     */
    private val strongVmKeywords = listOf(
        "virtualmaster", "virtual_master", "virtualandroid", "twoyi",
        "vmos", "vphonegaga", "f1vm", "x8sandbox", "goldfish", "ranchu",
        "vbox", "noxplayer", "bignox", "genymotion", "sdk_gphone", "google_sdk",
        "andyos", "ttvm", "aosp_x86", "generic_x86",
    )

    /**
     * Kata kunci LEMAH — tidak pernah cukup sendirian untuk memvonis VM.
     */
    private val weakVmKeywords = listOf(
        "emulator", "simulator",
    )

    /** File khas VMOS / Nox / VirtualBox — tidak ada di HP fisik. */
    private val strongVmPaths = listOf(
        "/dev/vboxguest",
        "/dev/vboxuser",
        "/system/lib/libc_vmos.so",
        "/system/bin/vmos_daemon",
        "/system/bin/nox-prop",
        "/ueventd.vmos.rc",
        "/init.vmos.rc",
    )

    /**
     * File sisa QEMU/goldfish yang terbukti IKUT TERBAWA di sebagian ROM HP fisik
     * berbasis MediaTek / Unisoc (mis. Vivo seri Y, Itel, Tecno) → sinyal lemah.
     */
    private val weakVmPaths = listOf(
        "/dev/socket/qemud",
        "/dev/qemu_pipe",
        "/dev/goldfish_pipe",
        "/system/bin/qemu-props",
        "/init.ranchu.rc",
        "/init.goldfish.rc",
    )

    /**
     * Penanda pustaka/engine container atau hook yang di-inject ke PROSES KITA SENDIRI
     * (/proc/self/maps). Sengaja berpatok pada paket/pustaka spesifik agar tidak bentrok
     * dengan nama komponen OEM (mis. fitur App Clone Vivo / Dual App Transsion).
     */
    private val containerMarkers = listOf(
        "virtualmaster", "virtual_master", "virtual-master",
        "com.clone.android.dual.space", "dual.space", "dualspace",
        "virtualandroid", "virtual_android", "com.pspace",
        "com.vmos", "libvmos", "/vmos/", "com.vphone", "vphonegaga", "com.f1vm", "f1player",
        "com.x8zs", "x8sandbox", "io.twoyi", "/twoyi/", "com.gspace", "com.ourplay",
        "niunaijun.blackbox", "blackboxcore", "com.virtualapp", "io.va.exposed",
        "com.lody.virtual", "lbe.parallel", "parallel.space", "com.excelliance",
        "libsandhook", "sandhook", "libpine.so", "libepic.so",
        "libwhale.so", "libdobby.so", "frida-agent", "frida-gadget",
        "lsposed", "edxposed", "xposedbridge", "libproot", "/proot/",
    )

    /** Penanda mount namespace yang hanya dibuat oleh aplikasi VM/container pihak ketiga. */
    private val containerMountMarkers = listOf(
        "virtualmaster", "virtual_master", "com.clone.android.dual.space", "dual.space", "dualspace",
        "virtualandroid", "virtual_android", "com.pspace", "com.vmos", "/vmos/",
        "com.vphone", "vphonegaga", "x8sandbox", "f1player", "io.twoyi", "/twoyi/",
        "com.x8zs", "com.f1vm", "com.gspace", "com.ourplay", "com.lody.virtual",
        "io.va.exposed", "niunaijun.blackbox", "com.excelliance", "lbe.parallel", "parallel.space",
    )

    private val hookClasses = listOf(
        "de.robv.android.xposed.XposedBridge",
        "com.lody.virtual.client.core.VirtualCore",
        "io.va.exposed.ExposedApplication",
        "top.niunaijun.blackbox.BlackBoxCore",
        "com.swift.sandhook.SandHook",
    )

    private val cloneMarkers = listOf(
        "parallel", "dual", "virtualmaster", "virtualapp",
        "clone", "multi", "twoyi", "blackbox", "vmos", "vphone",
    )

    private val accessibilitySystemPrefixes = listOf(
        "com.android.", "android.", "com.google.android.",
        "com.samsung.android.", "com.miui.", "com.huawei.",
    )

    private val suPaths = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su",
        "/system/su", "/system/bin/.ext/su", "/system/usr/we-need-root/su",
        "/system/app/Superuser.apk", "/data/local/su", "/data/local/bin/su",
        "/data/local/xbin/su",
    )

    private val rootPackages = listOf(
        "com.topjohnwu.magisk",
        "eu.chainfire.supersu",
        "com.koushikdutta.superuser",
        "com.noshufou.android.su",
        "com.thirdparty.superuser",
        "com.yellowes.su",
        "com.kingroot.kinguser",
        "com.kingo.root",
        "com.smedialink.oneclickroot",
        "com.zhiqupk.root.global",
        "com.alephzain.framaroot",
    )

    @Volatile
    private var cachedProcVmSignal: String? = null

    @Volatile
    private var cachedProcScanned: Boolean = false

    @VisibleForTesting
    fun resetProcCacheForTesting() {
        cachedProcVmSignal = null
        cachedProcScanned = false
    }

    /** Hasil deteksi VM beserta kode sinyal (dikirim ke server untuk audit false-positive). */
    data class VmDetectionResult(
        val isVirtual: Boolean,
        val strongSignals: List<String>,
        val weakSignals: List<String>,
    ) {
        fun describe(): String {
            val parts = mutableListOf<String>()
            if (strongSignals.isNotEmpty()) parts += "strong=" + strongSignals.joinToString(",")
            if (weakSignals.isNotEmpty()) parts += "weak=" + weakSignals.joinToString(",")
            return parts.joinToString("; ")
        }
    }

    /** Minimal jumlah sinyal lemah (tanpa sinyal kuat) agar dianggap VM. */
    private const val WEAK_SIGNAL_THRESHOLD = 2

    fun deviceLabel(): String =
        "${Build.MANUFACTURER.orEmpty()} ${Build.MODEL.orEmpty()} (Android ${Build.VERSION.RELEASE.orEmpty()})".trim()

    private fun readSystemProperty(key: String): String {
        return try {
            val sp = Class.forName("android.os.SystemProperties")
            val get = sp.getMethod("get", String::class.java, String::class.java)
            (get.invoke(null, key, "") as? String)?.trim()?.lowercase() ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    /**
     * Pindai HANYA proses kita sendiri:
     * - /proc/self/maps     → pustaka engine VM/hook yang ter-inject ke aplikasi ini
     * - /proc/self/mountinfo → mount khusus container pihak ketiga
     *
     * /proc/mounts dan /proc/net/unix sengaja TIDAK dipindai lagi karena bersifat
     * system-wide (berisi socket/mount aplikasi lain & layanan OEM) dan memicu
     * false-positive di HP fisik Vivo / Itel.
     */
    private fun scanOwnProcessForContainer(): String? {
        if (cachedProcScanned) return cachedProcVmSignal

        var signal: String? = null
        try {
            signal = scanFileForMarkers("/proc/self/maps", containerMarkers, "maps")
            if (signal == null) {
                signal = scanFileForMarkers("/proc/self/mountinfo", containerMountMarkers, "mount")
            }
        } catch (_: Exception) {}

        cachedProcVmSignal = signal
        cachedProcScanned = true
        return signal
    }

    @VisibleForTesting
    fun matchContainerLine(
        rawLine: String,
        markers: List<String> = containerMarkers,
        tag: String = "maps",
    ): String? {
        val sanitized = anyAndroidAppInstallHashRegex.replace(rawLine.lowercase(), "$1$2")
        for (marker in markers) {
            if (sanitized.contains(marker)) return "$tag:$marker"
        }
        return null
    }

    @VisibleForTesting
    fun matchMountLine(rawLine: String): String? =
        matchContainerLine(rawLine, containerMountMarkers, "mount")

    private fun scanFileForMarkers(path: String, markers: List<String>, tag: String): String? {
        val f = File(path)
        if (!f.exists() || !f.canRead()) return null
        f.bufferedReader().useLines { lines ->
            for (rawLine in lines) {
                matchContainerLine(rawLine, markers, tag)?.let { return it }
            }
        }
        return null
    }

    /**
     * Deteksi VM / emulator berbasis skor:
     * - 1 sinyal KUAT  → VM (VMOS, Virtual Master, emulator SDK, hook engine, dll.)
     * - sinyal LEMAH   → baru dianggap VM bila ≥ [WEAK_SIGNAL_THRESHOLD] sinyal muncul bersamaan
     *
     * Sinyal lemah = artefak yang ternyata juga ada di HP fisik murah (sisa file qemu di ROM
     * MediaTek/Unisoc, properti init.svc.qemud, jumlah sensor sangat sedikit, dll).
     */
    fun detectVirtualEnvironment(
        context: Context,
        isReviewerAccount: Boolean = false,
        bypassProcCacheForTesting: Boolean = false,
        weakPathsOverride: List<String>? = null,
        propertyReader: (String) -> String = ::readSystemProperty,
    ): VmDetectionResult {
        if (isReviewerAccount) return VmDetectionResult(false, emptyList(), emptyList())

        val strong = mutableListOf<String>()
        val weak = mutableListOf<String>()

        try {
            val fields = mapOf(
                "fingerprint" to Build.FINGERPRINT,
                "model" to Build.MODEL,
                "manufacturer" to Build.MANUFACTURER,
                "brand" to Build.BRAND,
                "device" to Build.DEVICE,
                "product" to Build.PRODUCT,
                "hardware" to Build.HARDWARE,
                "board" to Build.BOARD,
            ).mapValues { it.value.orEmpty().lowercase() }

            strongKw@ for (kw in strongVmKeywords) {
                for ((name, value) in fields) {
                    if (value.contains(kw)) {
                        strong += "build_$name:$kw"
                        break@strongKw
                    }
                }
            }
            weakKw@ for (kw in weakVmKeywords) {
                for ((name, value) in fields) {
                    if (value.contains(kw)) {
                        weak += "build_$name:$kw"
                        break@weakKw
                    }
                }
            }

            if (propertyReader("ro.kernel.qemu") == "1") strong += "prop:ro.kernel.qemu"
            if (propertyReader("ro.boot.qemu") == "1") weak += "prop:ro.boot.qemu"
            if (propertyReader("init.svc.qemud") == "running") weak += "prop:init.svc.qemud"
            val virtualProp = propertyReader("ro.hardware.virtual")
            if (virtualProp.isNotEmpty() && virtualProp != "0" && virtualProp != "false") {
                weak += "prop:ro.hardware.virtual"
            }

            for (path in strongVmPaths) {
                if (File(path).exists()) strong += "file:$path"
            }
            val weakHit = (weakPathsOverride ?: weakVmPaths).firstOrNull { File(it).exists() }
            if (weakHit != null) weak += "file:$weakHit"

            val ldPreload = (System.getenv("LD_PRELOAD") ?: "").lowercase()
            val prootTmp = System.getenv("PROOT_TMP_DIR") ?: ""
            if (prootTmp.isNotEmpty()) strong += "env:PROOT_TMP_DIR"
            if (ldPreload.isNotEmpty() && ldPreload.contains("/data/")) strong += "env:LD_PRELOAD"

            val loader = context.classLoader
            if (loader != null) {
                for (cls in hookClasses) {
                    try {
                        Class.forName(cls, false, loader)
                        strong += "class:${cls.substringAfterLast('.')}"
                        break
                    } catch (_: Throwable) {}
                }
            }

            if (!bypassProcCacheForTesting) {
                scanOwnProcessForContainer()?.let { strong += it }
            }

            val sm = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            if (sm != null) {
                // HP fisik termurah (Itel/Vivo entry-level) bisa hanya punya 1 sensor
                // (accelerometer). Hanya 0 sensor yang dihitung, itupun sebagai sinyal lemah.
                if (sm.getSensorList(Sensor.TYPE_ALL).isEmpty()) weak += "sensors:0"
            }
        } catch (_: Exception) {}

        val isVirtual = strong.isNotEmpty() || weak.size >= WEAK_SIGNAL_THRESHOLD
        return VmDetectionResult(isVirtual, strong, weak)
    }

    /**
     * Deteksi apakah aplikasi berjalan di Virtual Machine (VMOS, Virtual Master, dll.)
     * atau Android emulator. Akun reviewer dikecualikan agar dapat melewati review store.
     */
    fun isVirtualMachineOrEmulator(
        context: Context,
        isReviewerAccount: Boolean = false,
        bypassProcCacheForTesting: Boolean = false,
    ): Boolean = detectVirtualEnvironment(
        context,
        isReviewerAccount,
        bypassProcCacheForTesting,
    ).isVirtual

    /**
     * Evaluasi murni deteksi ruang ganda / cloned app tanpa ketergantungan host APK path,
     * membersihkan hash acak instalasi resmi Android 11+ (`/data/app/~~hash==/pkg-hash==`)
     * agar huruf acak Base64 tidak memicu false-positive `"dual"`/`"multi"`/`"vmos"`.
     */
    fun evaluateClonedPathsAndUid(
        pathsToCheck: List<String>,
        packageName: String,
        processUid: Int,
        isReviewerAccount: Boolean = false,
    ): Boolean {
        if (isReviewerAccount) return false

        val userId = processUid / 100_000
        if (userId != 0) {
            return true
        }

        if (packageName != EXPECTED_PACKAGE_NAME) {
            return true
        }

        for (rawPath in pathsToCheck) {
            val lower = rawPath.lowercase()
            if (nonZeroUserRegex.containsMatchIn(lower)) {
                return true
            }
            val sanitized = androidAppInstallHashRegex.replace(lower, "$1$2")
            for (marker in cloneMarkers) {
                if (sanitized.contains(marker)) {
                    return true
                }
            }
        }

        return false
    }

    fun isClonedOrDualApp(
        context: Context,
        isReviewerAccount: Boolean = false,
        processUid: Int = Process.myUid(),
    ): Boolean {
        if (isReviewerAccount) return false
        return try {
            val paths = listOfNotNull(
                runCatching { context.filesDir?.absolutePath }.getOrNull(),
                runCatching { context.filesDir?.canonicalPath }.getOrNull(),
                context.applicationInfo?.dataDir,
                context.applicationInfo?.sourceDir,
                context.applicationInfo?.nativeLibraryDir,
            )
            evaluateClonedPathsAndUid(
                pathsToCheck = paths,
                packageName = context.packageName,
                processUid = processUid,
                isReviewerAccount = false,
            )
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Evaluasi murni kondisi split-screen / PiP / floating window dari dimensi layar.
     */
    fun evaluateWindowBoundsSplit(
        isInMultiWindow: Boolean,
        isInPip: Boolean,
        imeVisible: Boolean,
        currentWidth: Int,
        currentHeight: Int,
        maxWidth: Int,
        maxHeight: Int,
        sdkInt: Int = Build.VERSION.SDK_INT,
    ): Boolean {
        if (isInMultiWindow || isInPip) return true
        if (imeVisible) return false
        if (currentWidth <= 0 || currentHeight <= 0 || maxWidth <= 0 || maxHeight <= 0) {
            return false
        }

        val currentArea = currentWidth.toLong() * currentHeight.toLong()
        val maxArea = maxWidth.toLong() * maxHeight.toLong()
        if (maxArea <= 0L) return false

        val areaRatio = currentArea.toDouble() / maxArea.toDouble()
        if (sdkInt >= Build.VERSION_CODES.R) {
            return areaRatio < SPLIT_AREA_RATIO_THRESHOLD
        }

        val widthRatio = currentWidth.toDouble() / maxWidth.toDouble()
        val heightRatio = currentHeight.toDouble() / maxHeight.toDouble()
        return areaRatio < SPLIT_AREA_RATIO_THRESHOLD &&
            (widthRatio < 0.85 || heightRatio < 0.65)
    }

    fun isSplitScreenOrFloating(activity: Activity): Boolean {
        return try {
            val multiWin = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                activity.isInMultiWindowMode
            val pip = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                activity.isInPictureInPictureMode
            if (multiWin || pip) return true

            val decorView = activity.window?.decorView
            val imeVisible = if (decorView != null) {
                ViewCompat.getRootWindowInsets(decorView)
                    ?.isVisible(WindowInsetsCompat.Type.ime()) == true
            } else {
                false
            }
            if (imeVisible) return false

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val wm = activity.windowManager
                val currentBounds = wm.currentWindowMetrics.bounds
                val maxBounds = wm.maximumWindowMetrics.bounds
                evaluateWindowBoundsSplit(
                    isInMultiWindow = false,
                    isInPip = false,
                    imeVisible = false,
                    currentWidth = currentBounds.width(),
                    currentHeight = currentBounds.height(),
                    maxWidth = maxBounds.width(),
                    maxHeight = maxBounds.height(),
                    sdkInt = Build.VERSION.SDK_INT,
                )
            } else {
                @Suppress("DEPRECATION")
                val display = activity.windowManager.defaultDisplay
                val realMetrics = DisplayMetrics()
                @Suppress("DEPRECATION")
                display.getRealMetrics(realMetrics)
                evaluateWindowBoundsSplit(
                    isInMultiWindow = false,
                    isInPip = false,
                    imeVisible = false,
                    currentWidth = decorView?.width ?: 0,
                    currentHeight = decorView?.height ?: 0,
                    maxWidth = realMetrics.widthPixels,
                    maxHeight = realMetrics.heightPixels,
                    sdkInt = Build.VERSION.SDK_INT,
                )
            }
        } catch (_: Exception) {
            false
        }
    }

    fun isBluetoothAudioDeviceType(
        deviceType: Int,
        sdkInt: Int = Build.VERSION.SDK_INT,
    ): Boolean {
        return deviceType == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
            deviceType == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            (sdkInt >= Build.VERSION_CODES.S && deviceType == AudioDeviceInfo.TYPE_BLE_HEADSET)
    }

    fun isBluetoothAudioConnected(context: Context): Boolean {
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { dev ->
                    isBluetoothAudioDeviceType(dev.type, Build.VERSION.SDK_INT)
                }
            } else {
                @Suppress("DEPRECATION")
                am.isBluetoothA2dpOn || am.isBluetoothScoOn
            }
        } catch (_: Exception) {
            false
        }
    }

    fun isPresentationDisplayActive(context: Context, displayId: Int? = null): Boolean {
        return try {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val presDisplays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
            presDisplays.any { d ->
                d.displayId != Display.DEFAULT_DISPLAY &&
                    d.state != Display.STATE_OFF &&
                    (displayId == null || d.displayId == displayId)
            }
        } catch (_: Exception) {
            false
        }
    }

    fun isLockTaskActive(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        } catch (_: Exception) {
            false
        }
    }

    fun isScreenPinningEnabled(context: Context): Boolean {
        return try {
            Settings.Secure.getInt(context.contentResolver, "lock_to_app_enabled", 0) == 1
        } catch (_: Exception) {
            false
        }
    }

    fun getNormalizedAndroidId(context: Context): String {
        return try {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
                ?.trim()
                ?.lowercase()
                ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    fun checkVpnActive(context: Context): Boolean {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val active = cm.activeNetwork
                val caps = if (active != null) cm.getNetworkCapabilities(active) else null
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            } else {
                @Suppress("DEPRECATION")
                cm.activeNetworkInfo?.typeName?.contains("VPN", ignoreCase = true) == true
            }
        } catch (_: Exception) {
            false
        }
    }

    fun checkSecurityFlags(context: Context): Map<String, Boolean> {
        val adbEnabled = try {
            Settings.Global.getInt(
                context.contentResolver,
                Settings.Global.ADB_ENABLED,
                0,
            ) == 1
        } catch (_: Exception) {
            false
        }

        val devOptions = try {
            Settings.Global.getInt(
                context.contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0,
            ) == 1
        } catch (_: Exception) {
            false
        }

        return mapOf(
            "usbDebugging" to adbEnabled,
            "developerMode" to devOptions,
        )
    }

    fun checkRootStatus(
        context: Context,
        suSearchPaths: List<String> = suPaths,
        buildTags: String? = Build.TAGS,
    ): Map<String, Boolean> {
        val suFound = suSearchPaths.any { File(it).exists() }
        val testKeys = buildTags?.contains("test-keys") == true
        val rootAppFound = rootPackages.any { pkg ->
            try {
                context.packageManager.getPackageInfo(pkg, 0)
                true
            } catch (_: Exception) {
                false
            }
        }
        return mapOf(
            "suBinaryFound" to suFound,
            "testKeys" to testKeys,
            "rootAppFound" to rootAppFound,
            "isRooted" to (suFound || testKeys || rootAppFound),
        )
    }

    fun getSuspiciousAccessibilityServices(context: Context): List<String> {
        return try {
            val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
            val active = am.getEnabledAccessibilityServiceList(
                AccessibilityServiceInfo.FEEDBACK_ALL_MASK,
            )
            active.filter { info ->
                val pkg = info.resolveInfo?.serviceInfo?.packageName ?: return@filter false
                pkg != context.packageName &&
                    accessibilitySystemPrefixes.none { pkg.startsWith(it) }
            }.map { info ->
                info.resolveInfo.serviceInfo.loadLabel(context.packageManager).toString()
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun resolveDndRestoreFilter(previousFilter: Int): Int {
        return if (
            previousFilter == NotificationManager.INTERRUPTION_FILTER_UNKNOWN ||
            previousFilter == NotificationManager.INTERRUPTION_FILTER_NONE
        ) {
            NotificationManager.INTERRUPTION_FILTER_ALL
        } else {
            previousFilter
        }
    }

    fun buildDndSettingsIntents(packageName: String): List<Intent> {
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        return listOf(
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).apply { addFlags(flags) },
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                addFlags(flags)
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            },
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                addFlags(flags)
                data = Uri.fromParts("package", packageName, null)
            },
        )
    }

    fun buildScreenPinningSettingsIntents(): List<Intent> {
        return listOf(
            "android.settings.SCREEN_PINNING_SETTINGS",
            Settings.ACTION_SECURITY_SETTINGS,
            Settings.ACTION_SETTINGS,
        ).map { action ->
            Intent(action).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        }
    }
}
