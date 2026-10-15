import AppKit
import ApplicationServices
import Core
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "com.danielmaymon.WritingAssistant", category: "app")

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var envSummary = ".env: not loaded"
    @Published private(set) var probeSummary: String?

    /// Values from `.env` (debug builds only). Never logged or shown.
    private(set) var env: [String: String] = [:]
    private var permissionTimer: Timer?
    private var checker: CheckController?

    func start() {
        loadEnv()
        registerLoginItemOnFirstRun()
        refreshLaunchAtLogin()

        // Asking with the prompt option shows the system dialog once when the app isn't trusted yet.
        // The literal is the value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects as a mutable global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        log.info("Accessibility trusted at launch: \(self.accessibilityGranted, privacy: .public)")
        startCheckingIfAllowed()

        // There is no reliable callback when the user flips the switch, so poll until granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.refreshAccessibility() }
        }
    }

    private func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            log.info("Accessibility trusted changed: \(trusted, privacy: .public)")
            startCheckingIfAllowed()
        }
    }

    /// Reading other apps' text needs the Accessibility permission, so checking starts once it's granted.
    private func startCheckingIfAllowed() {
        guard accessibilityGranted, checker == nil else { return }
        let checker = CheckController()
        checker.start()
        self.checker = checker
        #if DEBUG
        DebugServer.start(controller: checker)
        #endif
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Launch at login

    private func registerLoginItemOnFirstRun() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        setLaunchAtLogin(true)
        UserDefaults.standard.set(true, forKey: key)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        log.info("Login item status: \(status.rawValue, privacy: .public)")
    }

    // MARK: .env (debug only)

    private func loadEnv() {
        #if DEBUG
        guard let path = Bundle.main.object(forInfoDictionaryKey: "WAEnvPath") as? String, !path.isEmpty else {
            envSummary = ".env: no path in this build"
            return
        }
        do {
            env = try EnvFile.load(from: URL(fileURLWithPath: path))
            envSummary = env.isEmpty ? ".env: not found" : ".env: \(env.count) keys loaded"
        } catch {
            envSummary = ".env: unreadable"
        }
        log.info("\(self.envSummary, privacy: .public)")
        #endif
    }

    // MARK: Spell checker probe

    func runProbe() {
        let report = SpellProbe.run()
        probeSummary = "Probe: " + report.summary
        log.info("Probe: \(report.summary, privacy: .public)")
        do {
            let url = try SpellProbe.write(report)
            log.info("Probe written to \(url.path, privacy: .public)")
        } catch {
            log.error("Probe write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
