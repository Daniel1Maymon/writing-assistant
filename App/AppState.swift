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
    @Published private(set) var saveAcceptedFixes = true
    /// Today's AI use for the menu, e.g. "AI today: 12 checks · $0.0011".
    @Published private(set) var aiSummary = "AI checks: off (no key)"
    @Published private(set) var aiCapReached = false
    @Published private(set) var hasKey = false

    /// For the debug socket.
    static weak var shared: AppState?

    /// Values from `.env` (debug builds only). Never logged or shown.
    private(set) var env: [String: String] = [:]
    private var permissionTimer: Timer?
    private var checker: CheckController?

    func start() {
        Self.shared = self
        UserDefaults.standard.register(defaults: [CheckController.saveFixesKey: true])
        saveAcceptedFixes = UserDefaults.standard.bool(forKey: CheckController.saveFixesKey)
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
        checker.onUsageChange = { [weak self] ledger, capReached in self?.showUsage(ledger, capReached: capReached) }
        self.checker = checker
        setTierTwo(enabled: true)
        #if DEBUG
        DebugServer.start(controller: checker)
        #endif
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Accepted fixes go to the local mistake log only while this is on.
    func setSaveAcceptedFixes(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: CheckController.saveFixesKey)
        saveAcceptedFixes = enabled
    }

    // MARK: Tier 2 (OpenRouter)

    private static let defaultModels = ["anthropic/claude-haiku-5.5", "openai/gpt-6-luna"]

    /// Debug builds use `.env` first; every build falls back to the Keychain (DESIGN.md → Secrets).
    private var apiKey: String? {
        #if DEBUG
        if let key = env["OPENROUTER_API_KEY"], !key.isEmpty { return key }
        #endif
        return KeychainStore.read()
    }

    func setTierTwo(enabled: Bool) {
        guard let checker else { return }
        let key = enabled ? apiKey : nil
        hasKey = apiKey != nil
        let models = [env["OPENROUTER_MODEL"] ?? Self.defaultModels[0], env["OPENROUTER_FALLBACK_MODEL"] ?? Self.defaultModels[1]]
        let base = URL(string: env["OPENROUTER_BASE_URL"] ?? "") ?? URL(string: "https://openrouter.ai/api/v1")!
        checker.configureTierTwo(models: models, cap: Int(env["DAILY_REQUEST_CAP"] ?? "") ?? 1000,
                                 send: key.map { OpenRouterTransport.make(key: $0, baseURL: base) })
        if key == nil {
            aiSummary = hasKey ? "AI checks: off" : "AI checks: off (no key)"
            aiCapReached = false
        }
        log.info("Tier 2: \(key == nil ? "off" : "on", privacy: .public)")
    }

    private func showUsage(_ ledger: UsageLedger, capReached: Bool) {
        let today = ledger.day == UsageLedger.dayKey(Date()) ? ledger : UsageLedger()
        aiSummary = String(format: "AI today: %d checks · $%.4f", today.requests, today.cost)
        aiCapReached = capReached
    }

    /// Asks for the OpenRouter key and saves it in the Keychain. The key is never logged or shown.
    func askForKey() {
        let alert = NSAlert()
        alert.messageText = "OpenRouter key"
        alert.informativeText = "Paste your OpenRouter API key. It's stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, KeychainStore.save(key) else { return }
        setTierTwo(enabled: true)
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
