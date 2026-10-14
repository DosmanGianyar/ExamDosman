import Flutter
import UIKit
import CFNetwork

@main
@objc class AppDelegate: FlutterAppDelegate {

    private let lockdownChannel = "com.dosman.ujian/lockdown"
    private var flutterChannel: FlutterMethodChannel?
    private var isLockdownActive = false
    private var privacyOverlay: UIView?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(name: lockdownChannel, binaryMessenger: controller.binaryMessenger)
        flutterChannel = channel

        setupMethodChannel(channel: channel)
        setupNotificationObservers()

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
                UIApplication.shared.isIdleTimerDisabled = false
                self.hidePrivacyOverlay()
                result(true)

            case "isLockTaskActive", "isGuidedAccessActive":
                result(UIAccessibility.isGuidedAccessEnabled)

            case "enterLockTask":
                // Di iOS, "Lock Task" setara dengan status Guided Access (Akses Terpandu)
                self.isLockdownActive = true
                UIApplication.shared.isIdleTimerDisabled = true
                result(UIAccessibility.isGuidedAccessEnabled)

            case "exitLockTask":
                self.isLockdownActive = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.hidePrivacyOverlay()
                result(true)

            case "checkScreenCast":
                let isCasting = UIScreen.screens.count > 1 || UIScreen.main.isCaptured
                result(isCasting)

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
                // Di iOS navigasi dikontrol oleh AppBar / gestur Flutter
                result(true)

            case "keepScreenOn":
                UIApplication.shared.isIdleTimerDisabled = true
                result(true)

            case "clearScreenOn":
                UIApplication.shared.isIdleTimerDisabled = false
                result(true)

            case "isScreenInteractive":
                let interactive = UIApplication.shared.applicationState == .active
                result(interactive)

            case "isDndPermissionGranted":
                result(true)

            case "openDndSettings":
                result(false)

            case "isScreenPinningEnabled":
                result(UIAccessibility.isGuidedAccessEnabled)

            case "openScreenPinningSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    if UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        result(true)
                        return
                    }
                }
                result(false)

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
    }

    @objc private func didTakeScreenshot() {
        guard isLockdownActive else { return }
        flutterChannel?.invokeMethod("onScreenshotDetected", arguments: nil)
    }

    @objc private func screenCaptureChanged() {
        guard isLockdownActive else { return }
        if UIScreen.main.isCaptured || UIScreen.screens.count > 1 {
            flutterChannel?.invokeMethod("onScreenCastDetected", arguments: nil)
        }
    }

    @objc private func guidedAccessChanged() {
        guard isLockdownActive else { return }
        if !UIAccessibility.isGuidedAccessEnabled {
            // Pengawas atau siswa menonaktifkan Guided Access saat ujian aktif
            flutterChannel?.invokeMethod("onLockTaskLost", arguments: nil)
        }
    }

    // MARK: - App Lifecycle Privacy Overlay (App Switcher Protection)

    override func applicationWillResignActive(_ application: UIApplication) {
        super.applicationWillResignActive(application)
        if isLockdownActive {
            showPrivacyOverlay()
        }
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        super.applicationDidBecomeActive(application)
        hidePrivacyOverlay()
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
