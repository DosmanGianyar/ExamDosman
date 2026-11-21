import Flutter
import UIKit
import CFNetwork
import AudioToolbox
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {

    private let lockdownChannel = "com.dosman.ujian/lockdown"
    private var flutterChannel: FlutterMethodChannel?
    private var isLockdownActive = false
    private var isExamMode = false
    private var wasGuidedAccessEnabled = false
    private var isReviewerMode = false
    private var isScreenLocked = false
    private var bluetoothViolationReported = false
    private var privacyOverlay: UIView?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: lockdownChannel, binaryMessenger: controller.binaryMessenger)
            flutterChannel = channel
            setupMethodChannel(channel: channel)
        }
        setupNotificationObservers()

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - MethodChannel Setup

    private func setupMethodChannel(channel: FlutterMethodChannel) {
        channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else {
                result(FlutterError(code: "UNAVAILABLE", message: "AppDelegate deallocated", details: nil))
                return
            }

            switch call.method {
            case "enableLockdown":
                self.isLockdownActive = true
                UIApplication.shared.isIdleTimerDisabled = true
                result(true)

            case "disableLockdown":
                self.isLockdownActive = false
                self.isExamMode = false
                self.wasGuidedAccessEnabled = false
                self.bluetoothViolationReported = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.hidePrivacyOverlay()
                result(true)

            case "setExamMode":
                let active = (call.arguments as? [String: Any])?["active"] as? Bool ?? false
                self.isExamMode = active
                if active {
                    if UIAccessibility.isGuidedAccessEnabled {
                        self.wasGuidedAccessEnabled = true
                    }
                } else {
                    self.wasGuidedAccessEnabled = false
                    self.bluetoothViolationReported = false
                }
                result(true)

            case "getAndroidId":
                result("")

            case "setReviewerMode":
                let isReviewer = (call.arguments as? [String: Any])?["isReviewer"] as? Bool ?? false
                self.isReviewerMode = isReviewer
                result(true)

            case "setUserId":
                result(true)

            case "unpinPasswordAck":
                self.isLockdownActive = false
                self.isExamMode = false
                self.wasGuidedAccessEnabled = false
                self.bluetoothViolationReported = false
                result(true)

            case "checkVirtualEnvironment", "checkClonedApp", "isSplitScreenActive":
                result(false)

            case "isLockTaskActive", "isGuidedAccessActive", "isScreenPinningEnabled":
                if self.isReviewerMode {
                    result(true)
                } else {
                    result(UIAccessibility.isGuidedAccessEnabled)
                }

            case "enterLockTask", "requestScreenPin":
                self.isLockdownActive = true
                self.wasGuidedAccessEnabled = UIAccessibility.isGuidedAccessEnabled
                UIApplication.shared.isIdleTimerDisabled = true
                result(true)

            case "exitLockTask":
                self.isLockdownActive = false
                self.isExamMode = false
                self.wasGuidedAccessEnabled = false
                self.bluetoothViolationReported = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.hidePrivacyOverlay()
                result(true)

            case "checkScreenCast":
                result(self.isScreenCapturedOrExternal())

            case "checkBluetoothAudio":
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let isBt = outputs.contains { port in
                    port.portType == .bluetoothA2DP ||
                    port.portType == .bluetoothHFP ||
                    port.portType == .bluetoothLE
                }
                result(isBt)

            case "checkVpn":
                result(self.isVpnActive())

            case "checkSecurityFlags":
                result([
                    "usbDebugging": false,
                    "developerMode": false
                ])

            case "checkAccessibilityServices":
                result([String]())

            case "checkRootStatus":
                let rooted = self.isJailbroken()
                result([
                    "suBinaryFound": false,
                    "testKeys": false,
                    "rootAppFound": rooted,
                    "isRooted": rooted
                ])

            case "lockBackButton", "unlockBackButton":
                result(true)

            case "keepScreenOn":
                UIApplication.shared.isIdleTimerDisabled = true
                result(true)

            case "clearScreenOn":
                UIApplication.shared.isIdleTimerDisabled = false
                result(true)

            case "isScreenInteractive":
                // Saat aplikasi masuk background (_onAppPaused), applicationState sudah bukan .active.
                // Gunakan flag isScreenLocked (dari protectedDataWillBecomeUnavailableNotification)
                // agar minimize ke app lain tetap terdeteksi sebagai layar menyala (interactive = true).
                result(!self.isScreenLocked)

            case "isDndPermissionGranted":
                result(true)

            case "openDndSettings":
                result(false)

            case "openWifiSettings":
                if UIAccessibility.isGuidedAccessEnabled {
                    result(false)
                    return
                }
                if let url = URL(string: UIApplication.openSettingsURLString),
                   UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:]) { success in
                        result(success)
                    }
                    return
                }
                result(false)

            case "openScreenPinningSettings", "openAppSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    if UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url, options: [:]) { success in
                            result(success)
                        }
                        return
                    }
                }
                result(false)

            case "getAppFilesDir":
                if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    result(dir.path)
                } else if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    result(doc.path)
                } else {
                    result(NSTemporaryDirectory())
                }

            case "getKatexBaseDir":
                let katexPath = (Bundle.main.bundlePath as NSString)
                    .appendingPathComponent("Frameworks/App.framework/flutter_assets/assets/katex")
                if FileManager.default.fileExists(atPath: (katexPath as NSString).appendingPathComponent("katex.min.js")) {
                    result(katexPath.hasSuffix("/") ? katexPath : katexPath + "/")
                } else {
                    result(nil)
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - Notification Observers (Official Apple APIs)

    private func setupNotificationObservers() {
        // Deteksi screenshot
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        // Deteksi screen recording / AirPlay
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenCaptureChanged),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )

        // Deteksi perubahan status Guided Access
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(guidedAccessChanged),
            name: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil
        )

        // Deteksi koneksi audio Bluetooth
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Deteksi layar terkunci (tombol Power / auto-lock) vs minimize biasa
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
    }

    private func isScreenCapturedOrExternal() -> Bool {
        let currentScreen = self.window?.windowScene?.screen ?? UIScreen.main
        return currentScreen.isCaptured || UIScreen.screens.count > 1
    }

    @objc private func screenDidLock() {
        DispatchQueue.main.async { [weak self] in
            self?.isScreenLocked = true
        }
    }

    @objc private func screenDidUnlock() {
        DispatchQueue.main.async { [weak self] in
            self?.isScreenLocked = false
        }
    }

    @objc private func audioRouteChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let isBt = outputs.contains { port in
                port.portType == .bluetoothA2DP ||
                port.portType == .bluetoothHFP ||
                port.portType == .bluetoothLE
            }
            if !isBt {
                self.bluetoothViolationReported = false
                return
            }
            if self.isLockdownActive && self.isExamMode && !self.isReviewerMode && !self.bluetoothViolationReported {
                self.bluetoothViolationReported = true
                self.flutterChannel?.invokeMethod("onBluetoothAudioConnected", arguments: nil)
            }
        }
    }

    @objc private func didTakeScreenshot() {
        // iOS tidak mengizinkan aplikasi memblokir screenshot; yang bisa dilakukan
        // adalah mendeteksi lalu melaporkannya sebagai pelanggaran ke server.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.isLockdownActive, !self.isReviewerMode else { return }
            self.flutterChannel?.invokeMethod("onScreenshotDetected", arguments: nil)
        }
    }

    @objc private func screenCaptureChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.isLockdownActive else { return }
            if self.isScreenCapturedOrExternal() {
                if !self.isReviewerMode {
                    self.showPrivacyOverlay()
                }
                self.flutterChannel?.invokeMethod("onScreenCastDetected", arguments: nil)
            } else {
                if UIApplication.shared.applicationState == .active {
                    self.hidePrivacyOverlay()
                }
            }
        }
    }

    @objc private func guidedAccessChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let enabled = UIAccessibility.isGuidedAccessEnabled
            if enabled {
                if self.isLockdownActive {
                    self.wasGuidedAccessEnabled = true
                }
                return
            }
            // Jika Akses Terpadu dimatikan oleh siswa saat ujian aktif
            if self.isLockdownActive && self.isExamMode && self.wasGuidedAccessEnabled && !self.isReviewerMode {
                self.wasGuidedAccessEnabled = false
                self.flutterChannel?.invokeMethod("onLockTaskLost", arguments: nil)
            }
        }
    }

    // MARK: - App Lifecycle Privacy Overlay (App Switcher Protection)

    override func applicationWillResignActive(_ application: UIApplication) {
        super.applicationWillResignActive(application)
        if isLockdownActive && !isReviewerMode {
            showPrivacyOverlay()
        }
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        super.applicationDidBecomeActive(application)
        isScreenLocked = false
        if isLockdownActive {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        if !(isLockdownActive && !isReviewerMode && isScreenCapturedOrExternal()) {
            hidePrivacyOverlay()
        }
    }

    private func showPrivacyOverlay() {
        guard privacyOverlay == nil, let window = self.window else { return }
        let blur = UIBlurEffect(style: .dark)
        let effectView = UIVisualEffectView(effect: blur)
        effectView.frame = window.bounds
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel()
        label.text = "🔒 Dosman Exam Terkunci"
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor)
        ])

        window.addSubview(effectView)
        self.privacyOverlay = effectView
    }

    private func hidePrivacyOverlay() {
        privacyOverlay?.removeFromSuperview()
        privacyOverlay = nil
    }

    // MARK: - Security Helpers (Official, Store-Compliant)

    private func isVpnActive() -> Bool {
        guard let cfDict = CFNetworkCopySystemProxySettings() else { return false }
        let nsDict = cfDict.takeRetainedValue() as NSDictionary
        guard let keys = nsDict["__SCOPED__"] as? NSDictionary else { return false }
        for key in keys.allKeys {
            if let keyStr = key as? String {
                let lower = keyStr.lowercased()
                if lower.contains("tap") || lower.contains("tun") || lower.contains("ppp") || lower.contains("ipsec") {
                    return true
                }
            }
        }
        return false
    }

    private func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/usr/bin/ssh"
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        let testPath = "/private/jailbreak_test_\(UUID().uuidString).txt"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            return false
        }
        #endif
    }
}
