package com.dosman.dosman_ujian

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageInfo
import android.hardware.Sensor
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBuild
import org.robolectric.shadows.ShadowNetworkCapabilities
import org.robolectric.shadows.ShadowSensor
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30, 34])
class ExamSecurityGuardTest {

    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        ExamSecurityGuard.resetProcCacheForTesting()
        ShadowBuild.reset()
        configureRealOemProfile(
            manufacturer = "samsung",
            brand = "samsung",
            model = "SM-A155F",
            device = "a15",
            product = "a15nsxx",
            hardware = "mt6789",
            board = "a15",
            fingerprint = "samsung/a15nsxx/a15:14/UP1A.231005.007/A155FXXU2BXC1:user/release-keys",
            display = "UP1A.231005.007.A155FXXU2BXC1",
            host = "21DJ6514",
        )
        setSensorsCount(3)
    }

    @After
    fun tearDown() {
        ExamSecurityGuard.resetProcCacheForTesting()
        ShadowBuild.reset()
    }

    private fun configureRealOemProfile(
        manufacturer: String,
        brand: String,
        model: String,
        device: String,
        product: String,
        hardware: String,
        board: String,
        fingerprint: String,
        display: String,
        host: String,
    ) {
        ShadowBuild.setManufacturer(manufacturer)
        ShadowBuild.setBrand(brand)
        ShadowBuild.setModel(model)
        ShadowBuild.setDevice(device)
        ShadowBuild.setProduct(product)
        ShadowBuild.setHardware(hardware)
        ShadowBuild.setBoard(board)
        ShadowBuild.setFingerprint(fingerprint)
        ReflectionHelpers.setStaticField(Build::class.java, "DISPLAY", display)
        ReflectionHelpers.setStaticField(Build::class.java, "HOST", host)
    }

    private fun setSensorsCount(count: Int) {
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val shadowSm = shadowOf(sm)
        // Hapus referensi Sensor exact agar ShadowSensorManager benar-benar mengosongkan daftar
        for (existing in sm.getSensorList(Sensor.TYPE_ALL).toList()) {
            shadowSm.removeSensor(existing)
        }
        val types = listOf(Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_PROXIMITY)
        for (i in 0 until count.coerceAtMost(types.size)) {
            shadowSm.addSensor(ShadowSensor.newInstance(types[i]))
        }
        assertEquals(count.coerceAtMost(types.size), sm.getSensorList(Sensor.TYPE_ALL).size)
    }

    // ─── Grup A: Profil OEM Fisik vs VM / Emulator ────────────────────────────

    @Test
    fun `5 profil HP OEM nyata dengan 2-3 sensor tidak pernah memicu false-positive VM`() {
        val profiles = listOf(
            arrayOf("samsung", "samsung", "SM-A155F", "a15", "a15nsxx", "mt6789", "a15", "samsung/a15/a15:14/UP1A:user/release-keys", "UP1A", "build1"),
            arrayOf("Xiaomi", "Redmi", "23021RAA2Y", "tapas", "tapas_global", "qcom", "bengal", "Redmi/tapas_global/tapas:13/TKQ1:user/release-keys", "TKQ1", "miui-builder"),
            arrayOf("vivo", "vivo", "V2207", "PD2226F_EX", "PD2226F_EX", "mt6765", "k65v1_64_bsp", "vivo/V2207/PD2226:13/TP1A:user/release-keys", "TP1A", "compiler"),
            arrayOf("OPPO", "OPPO", "CPH2577", "OP594FL1", "CPH2577", "mt6833", "k6833v1_64", "OPPO/CPH2577/OP594FL1:14/UP1A:user/release-keys", "UP1A", "dg02-pool"),
            arrayOf("realme", "realme", "RMX3710", "RE58B2L1", "RMX3710", "ums9230", "ums9230_2h10", "realme/RMX3710/RE58B2L1:13/TP1A:user/release-keys", "TP1A", "jenkins"),
        )
        setSensorsCount(2) // HP entry-level sering hanya punya 2 sensor
        for (p in profiles) {
            configureRealOemProfile(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9])
            assertFalse(
                "OEM ${p[0]} ${p[2]} salah terdeteksi VM!",
                ExamSecurityGuard.isVirtualMachineOrEmulator(
                    context,
                    isReviewerAccount = false,
                    bypassProcCacheForTesting = true,
                ),
            )
        }
    }

    @Test
    fun `VM, emulator ranchu-sdk_gphone, dan device dengan 1 sensor terdeteksi VM kecuali reviewer`() {
        val vmCases = listOf("vmos", "virtualmaster", "sdk_gphone64_x86_64", "ranchu")
        for (kw in vmCases) {
            configureRealOemProfile("unknown", kw, kw, kw, kw, kw, kw, "aosp/$kw:13:userdebug/test-keys", kw, kw)
            assertTrue(
                "VM keyword '$kw' gagal terdeteksi",
                ExamSecurityGuard.isVirtualMachineOrEmulator(context, isReviewerAccount = false, bypassProcCacheForTesting = true),
            )
            assertFalse(
                "Akun reviewer harus kebal dari deteksi VM '$kw'",
                ExamSecurityGuard.isVirtualMachineOrEmulator(context, isReviewerAccount = true, bypassProcCacheForTesting = true),
            )
        }

        // Kembali ke profil Samsung normal: HP fisik termurah dengan 1 sensor TIDAK boleh dianggap VM
        configureRealOemProfile("samsung", "samsung", "SM-A155F", "a15", "a15nsxx", "mt6789", "a15", "samsung/a15:14/UP1A:user/release-keys", "UP1A", "host")
        setSensorsCount(1)
        assertFalse(
            ExamSecurityGuard.isVirtualMachineOrEmulator(context, isReviewerAccount = false, bypassProcCacheForTesting = true),
        )
    }

    @Test
    fun `Vivo dan Itel fisik dengan sisa artefak qemu tunggal tidak dianggap VM`() {
        val tmpQemu = java.io.File.createTempFile("qemud", ".sock").apply { deleteOnExit() }
        val profiles = listOf(
            arrayOf("vivo", "vivo", "V2333", "PD2333F_EX", "PD2333F_EX", "mt6769", "k69v1_64", "vivo/PD2333F_EX/PD2333F_EX:14/UP1A:user/release-keys", "UP1A.231005.007", "compiler02"),
            arrayOf("vivo", "vivo", "V2204", "PD2204F_EX", "PD2204F_EX", "ums9230", "s9863a1h10", "vivo/PD2204F_EX/PD2204F_EX:12/SP1A:user/release-keys", "SP1A.210812.003", "compiler"),
            arrayOf("ITEL", "Itel", "itel A665L", "itel-A665L", "A665L-OP", "mt6761", "aosp_arm_go", "Itel/A665L-OP/itel-A665L:13/TP1A:user/release-keys", "A665L-H6120ABC-T-OP", "jenkins"),
            arrayOf("ITEL", "Itel", "itel S665L", "itel-S665L", "S665L-GL", "ums9230", "generic_arm64", "Itel/S665L-GL/itel-S665L:13/TP1A:user/release-keys", "S665L-F8131ABC", "builder"),
        )
        setSensorsCount(1)
        for (p in profiles) {
            configureRealOemProfile(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9])
            // Satu sinyal lemah (sisa file qemu) + init.svc.qemud="stopped" → bukan VM
            val r1 = ExamSecurityGuard.detectVirtualEnvironment(
                context,
                bypassProcCacheForTesting = true,
                weakPathsOverride = listOf(tmpQemu.absolutePath),
                propertyReader = { key -> if (key == "init.svc.qemud") "stopped" else "" },
            )
            assertFalse("${p[0]} ${p[2]} salah terdeteksi VM: ${r1.describe()}", r1.isVirtual)
            assertTrue(r1.strongSignals.isEmpty())
        }
    }

    @Test
    fun `gabungan beberapa sinyal lemah atau satu sinyal kuat tetap terdeteksi VM`() {
        val tmpQemu = java.io.File.createTempFile("qemu_pipe", ".dev").apply { deleteOnExit() }
        setSensorsCount(0)
        val weakCombo = ExamSecurityGuard.detectVirtualEnvironment(
            context,
            bypassProcCacheForTesting = true,
            weakPathsOverride = listOf(tmpQemu.absolutePath),
            propertyReader = { key -> if (key == "init.svc.qemud") "running" else "" },
        )
        assertTrue(weakCombo.describe(), weakCombo.isVirtual)
        assertTrue(weakCombo.weakSignals.size >= 2)

        setSensorsCount(3)
        val strongQemu = ExamSecurityGuard.detectVirtualEnvironment(
            context,
            bypassProcCacheForTesting = true,
            weakPathsOverride = emptyList(),
            propertyReader = { key -> if (key == "ro.kernel.qemu") "1" else "" },
        )
        assertTrue(strongQemu.isVirtual)
        assertTrue(strongQemu.strongSignals.contains("prop:ro.kernel.qemu"))

        val reviewer = ExamSecurityGuard.detectVirtualEnvironment(
            context,
            isReviewerAccount = true,
            bypassProcCacheForTesting = true,
            propertyReader = { "1" },
        )
        assertFalse(reviewer.isVirtual)
    }

    @Test
    fun `matchContainerLine kebal path OEM Vivo-Itel & hash Android 11+ tapi mendeteksi lib VM nyata`() {
        val oemAndHashLines = listOf(
            "7a123000-7a124000 r-xp 00000000 fc:00 1234 /vendor/lib64/libvivo_blackbox.so",
            "7a125000-7a126000 r--p 00000000 fc:00 1235 /system/priv-app/VivoMultiApp/base.apk",
            "7a127000-7a128000 r--p 00000000 fc:00 1236 /system/app/TranDualApp/TranDualApp.apk",
            "7a129000-7a12a000 r-xp 00000000 fc:00 1237 /data/app/~~VmOsF1vM99==/com.dosman.dosman_ujian-X8zSTwOyI==/base.apk",
        )
        for (line in oemAndHashLines) {
            assertEquals(
                "OEM / hash path salah terdeteksi container: $line",
                null,
                ExamSecurityGuard.matchContainerLine(line),
            )
        }

        val realVmAndHookLines = listOf(
            "7b000000-7b001000 r-xp 00000000 fc:00 2001 /data/app/~~abc==/com.vmos.pro-xyz==/lib/arm64/libvmos.so",
            "7b002000-7b003000 r-xp 00000000 fc:00 2002 /data/local/tmp/frida-agent-64.so",
            "7b004000-7b005000 r--p 00000000 fc:00 2003 /data/app/~~abc==/com.x8zs.sandbox-xyz==/base.apk",
            "7b006000-7b007000 r-xp 00000000 fc:00 2004 /data/data/top.niunaijun.blackboxa/lib/arm64/libblackbox.so",
            "7b008000-7b009000 r-xp 00000000 fc:00 2005 /data/adb/lspd/framework/lsposed.dex",
        )
        for (line in realVmAndHookLines) {
            val matched = ExamSecurityGuard.matchContainerLine(line)
            assertTrue("VM/hook gagal terdeteksi: $line", matched != null)
        }

        // Virtual Master & container mountinfo detection vs Vivo OEM mount ignore
        assertTrue(
            "Virtual Master mountinfo gagal terdeteksi",
            ExamSecurityGuard.matchMountLine(
                "42 29 0:51 / /data/user/0/com.clone.android.dual.space/osimg/r rw,nosuid,nodev",
            ) != null,
        )
        assertEquals(
            "Mount Vivo OEM tidak boleh terdeteksi sebagai VM",
            null,
            ExamSecurityGuard.matchMountLine(
                "43 29 253:1 /vivo-common/blackbox /data/vivo-common/blackbox rw,relatime",
            ),
        )
    }

    // ─── Grup B: Cloned / Dual App & Sanitasi Hash Android 11+ ───────────────

    @Test
    fun `path instalasi resmi Android 11+ dengan substring random dual-multi-vmos tidak memicu false-positive cloned`() {
        val officialPaths = listOf(
            "/data/user/0/com.dosman.dosman_ujian/files",
            "/data/user/0/com.dosman.dosman_ujian",
            "/data/app/~~DuAl1234VmOs==/com.dosman.dosman_ujian-MuLtI99==/base.apk",
            "/data/app/~~DuAl1234VmOs==/com.dosman.dosman_ujian-MuLtI99==/lib/arm64",
        )
        assertFalse(
            ExamSecurityGuard.evaluateClonedPathsAndUid(
                pathsToCheck = officialPaths,
                packageName = "com.dosman.dosman_ujian",
                processUid = 10234, // User ID 0 (utama)
                isReviewerAccount = false,
            ),
        )
    }

    @Test
    fun `Xiaomi Dual Apps, Work Profile UID!=0, Parallel Space, dan package clone terdeteksi akurat`() {
        val cleanPaths = listOf("/data/user/0/com.dosman.dosman_ujian/files")
        // UID user 999 (Xiaomi Dual Apps)
        assertTrue(
            ExamSecurityGuard.evaluateClonedPathsAndUid(cleanPaths, "com.dosman.dosman_ujian", 99910234),
        )
        // UID user 10 (Work Profile / Island / Secure Folder)
        assertTrue(
            ExamSecurityGuard.evaluateClonedPathsAndUid(cleanPaths, "com.dosman.dosman_ujian", 1010234),
        )
        // Reviewer pada userId 10 tetap diizinkan
        assertFalse(
            ExamSecurityGuard.evaluateClonedPathsAndUid(cleanPaths, "com.dosman.dosman_ujian", 1010234, isReviewerAccount = true),
        )
        // Path Dual Space / Parallel Space / /user/999/
        assertTrue(
            ExamSecurityGuard.evaluateClonedPathsAndUid(
                listOf("/data/user/999/com.dosman.dosman_ujian/files"),
                "com.dosman.dosman_ujian",
                10234,
            ),
        )
        assertTrue(
            ExamSecurityGuard.evaluateClonedPathsAndUid(
                listOf("/data/user/0/com.lbe.parallel.intl/virtual/data/app/com.dosman.dosman_ujian/base.apk"),
                "com.dosman.dosman_ujian",
                10234,
            ),
        )
        // Package name clone berbeda
        assertTrue(
            ExamSecurityGuard.evaluateClonedPathsAndUid(cleanPaths, "com.dosman.dosman_ujian.clone", 10234),
        )
    }

    // ─── Grup C: Split-Screen, PiP, Keyboard IME, Floating Window ────────────

    @Test
    fun `split-screen, PiP, floating window vs keyboard IME dan layar penuh API 29-34`() {
        assertTrue(ExamSecurityGuard.evaluateWindowBoundsSplit(true, false, false, 1080, 2200, 1080, 2400, 34))
        assertTrue(ExamSecurityGuard.evaluateWindowBoundsSplit(false, true, false, 1080, 2200, 1080, 2400, 34))

        // Keyboard IME terbuka menyusutkan tinggi jendela → TIDAK boleh dianggap split-screen
        assertFalse(ExamSecurityGuard.evaluateWindowBoundsSplit(false, false, true, 1080, 1200, 1080, 2400, 34))

        // Layar penuh normal dengan system/navigation bar
        assertFalse(ExamSecurityGuard.evaluateWindowBoundsSplit(false, false, false, 1080, 2240, 1080, 2400, 34))

        // Floating window < 72% area pada API 34 & API 29
        assertTrue(ExamSecurityGuard.evaluateWindowBoundsSplit(false, false, false, 600, 900, 1080, 2400, 34))
        assertTrue(ExamSecurityGuard.evaluateWindowBoundsSplit(false, false, false, 600, 900, 1080, 2400, 29))
    }

    // ─── Grup D: KioskGuardStateMachine Lifecycle, Cooldown & Bluetooth Dedup ─

    @Test
    fun `state machine menolak false alarm di CourseList, menangkap unpin saat ujian, dan mereset cooldown di stopKiosk`() {
        val sm = KioskGuardStateMachine()
        sm.kioskActive = true
        sm.inExamMode = false

        // Sempat ter-pin lalu pin lepas di CourseList (!inExamMode) → NONE + reset wasPinnedSuccessfully
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.NONE,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = true, isSplitScreen = false, isVirtualEnv = false, isClonedApp = false),
        )
        assertTrue(sm.wasPinnedSuccessfully)
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.NONE,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = false, isSplitScreen = false, isVirtualEnv = false, isClonedApp = false),
        )
        assertFalse(sm.wasPinnedSuccessfully)

        // Masuk mode ujian → pin aktif → tiba-tiba pin dilepas → UNPIN_VIOLATION
        sm.inExamMode = true
        sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = true, isSplitScreen = false, isVirtualEnv = false, isClonedApp = false)
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.UNPIN_VIOLATION,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = false, isSplitScreen = false, isVirtualEnv = false, isClonedApp = false),
        )

        // Pelanggaran mid-exam lain saat tetap pinned
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.SPLIT_SCREEN_VIOLATION,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = true, isSplitScreen = true, isVirtualEnv = false, isClonedApp = false),
        )
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.VIRTUAL_ENV_VIOLATION,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = true, isSplitScreen = false, isVirtualEnv = true, isClonedApp = false),
        )
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.CLONED_APP_VIOLATION,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = true, isSplitScreen = false, isVirtualEnv = false, isClonedApp = true),
        )

        // Reviewer kebal terhadap seluruh aksi loop & bluetooth
        sm.isReviewerAccount = true
        assertEquals(
            KioskGuardStateMachine.PinLoopAction.NONE,
            sm.evaluatePinLoopTick(pinLoopOn = true, isLockTaskActive = false, isSplitScreen = true, isVirtualEnv = true, isClonedApp = true),
        )
        assertFalse(sm.shouldDispatchBluetoothViolation())

        // Cooldown startLockTask 5 detik & resetOnStopKiosk
        assertTrue(sm.tryConsumeStartLockTaskCooldown(nowMs = 10_000L))
        assertFalse(sm.tryConsumeStartLockTaskCooldown(nowMs = 12_000L))
        assertTrue(sm.tryConsumeStartLockTaskCooldown(nowMs = 15_100L))
        sm.resetOnStopKiosk()
        assertTrue(sm.tryConsumeStartLockTaskCooldown(nowMs = 15_500L))

        // Dedup event Bluetooth (A2DP + SCO bersamaan hanya memicu 1x)
        sm.isReviewerAccount = false
        sm.kioskActive = true
        sm.inExamMode = true
        assertTrue(sm.shouldDispatchBluetoothViolation())
        assertFalse(sm.shouldDispatchBluetoothViolation())
        assertTrue(ExamSecurityGuard.isBluetoothAudioDeviceType(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, 34))
        assertTrue(ExamSecurityGuard.isBluetoothAudioDeviceType(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, 30))
        assertTrue(ExamSecurityGuard.isBluetoothAudioDeviceType(AudioDeviceInfo.TYPE_BLE_HEADSET, 34))
        assertFalse(ExamSecurityGuard.isBluetoothAudioDeviceType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, 34))
        assertFalse(ExamSecurityGuard.isBluetoothAudioDeviceType(AudioDeviceInfo.TYPE_WIRED_HEADSET, 34))
    }

    // ─── Grup E: Android System Services Nyata via Robolectric Shadows ────────

    @Test
    fun `Shadow ActivityManager, Settings, ConnectivityManager, PackageManager, dan DND bekerja akurat`() {
        // ActivityManager LockTaskMode
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        shadowOf(am).setLockTaskModeState(ActivityManager.LOCK_TASK_MODE_NONE)
        assertFalse(ExamSecurityGuard.isLockTaskActive(context))
        shadowOf(am).setLockTaskModeState(ActivityManager.LOCK_TASK_MODE_PINNED)
        assertTrue(ExamSecurityGuard.isLockTaskActive(context))

        // Screen pinning & Android ID
        Settings.Secure.putInt(context.contentResolver, "lock_to_app_enabled", 1)
        assertTrue(ExamSecurityGuard.isScreenPinningEnabled(context))
        Settings.Secure.putString(context.contentResolver, Settings.Secure.ANDROID_ID, "  A1B2C3D4E5F60708  ")
        assertEquals("a1b2c3d4e5f60708", ExamSecurityGuard.getNormalizedAndroidId(context))

        // ADB & Developer options
        Settings.Global.putInt(context.contentResolver, Settings.Global.ADB_ENABLED, 1)
        Settings.Global.putInt(context.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0)
        val flags = ExamSecurityGuard.checkSecurityFlags(context)
        assertEquals(true, flags["usbDebugging"])
        assertEquals(false, flags["developerMode"])

        // VPN vs Wi-Fi
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val activeNet: Network = cm.activeNetwork!!
        val wifiCaps = ShadowNetworkCapabilities.newInstance()
        shadowOf(wifiCaps).addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        shadowOf(cm).setNetworkCapabilities(activeNet, wifiCaps)
        assertFalse(ExamSecurityGuard.checkVpnActive(context))

        val vpnCaps = ShadowNetworkCapabilities.newInstance()
        shadowOf(vpnCaps).addTransportType(NetworkCapabilities.TRANSPORT_VPN)
        shadowOf(cm).setNetworkCapabilities(activeNet, vpnCaps)
        assertTrue(ExamSecurityGuard.checkVpnActive(context))

        // Root detection via installed package Magisk vs clean
        assertFalse(ExamSecurityGuard.checkRootStatus(context, suSearchPaths = emptyList(), buildTags = "release-keys")["isRooted"]!!)
        val magiskPkg = PackageInfo().apply { packageName = "com.topjohnwu.magisk" }
        shadowOf(context.packageManager).installPackage(magiskPkg)
        val rootStatus = ExamSecurityGuard.checkRootStatus(context, suSearchPaths = emptyList(), buildTags = "release-keys")
        assertEquals(true, rootStatus["rootAppFound"])
        assertEquals(true, rootStatus["isRooted"])

        // DND restore & fallback intents
        assertEquals(NotificationManager.INTERRUPTION_FILTER_ALL, ExamSecurityGuard.resolveDndRestoreFilter(NotificationManager.INTERRUPTION_FILTER_NONE))
        assertEquals(NotificationManager.INTERRUPTION_FILTER_ALL, ExamSecurityGuard.resolveDndRestoreFilter(NotificationManager.INTERRUPTION_FILTER_UNKNOWN))
        assertEquals(NotificationManager.INTERRUPTION_FILTER_PRIORITY, ExamSecurityGuard.resolveDndRestoreFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY))
        assertEquals(3, ExamSecurityGuard.buildDndSettingsIntents(context.packageName).size)
        assertEquals(3, ExamSecurityGuard.buildScreenPinningSettingsIntents().size)
    }
}
