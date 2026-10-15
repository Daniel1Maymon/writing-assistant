import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.danielmaymon.WritingAssistant", category: "focus")

/// Follows the text field the user is typing in, in whatever app is frontmost.
/// Reports focus, value and geometry changes through `onEvent`, on the main thread.
@MainActor
final class FocusTracker {
    enum Event { case focusChanged, valueChanged, geometryChanged }

    var onEvent: ((Event) -> Void)?
    private(set) var focused: AXElement?
    private(set) var app: NSRunningApplication?

    private var observer: AXObserver?
    private var appElement: AXElement?
    private var watchedElement: AXElement?
    private var watchedWindow: AXElement?
    private var activationToken: NSObjectProtocol?
    private var appNotificationAdded = false
    private var retryTimer: Timer?

    private static let elementNotifications = ["AXValueChanged", "AXSelectedTextChanged", "AXUIElementDestroyed"]
    private static let windowNotifications = ["AXMoved", "AXResized"]

    func start() {
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.attach(to: app) }
        }
        attach(to: NSWorkspace.shared.frontmostApplication)
        // An app that just launched or activated may not answer AX yet; keep trying until it does.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfNeeded() }
        }
    }

    private func retryIfNeeded() {
        guard let observer, let appElement else { return }
        if !appNotificationAdded {
            addAppNotification(observer, appElement)
        }
        if focused == nil, appElement.focusedElement != nil {
            refreshFocus()
        }
    }

    private func addAppNotification(_ observer: AXObserver, _ appElement: AXElement) {
        let result = AXObserverAddNotification(observer, appElement.ref, "AXFocusedUIElementChanged" as CFString, selfPointer)
        appNotificationAdded = result == .success || result == .notificationAlreadyRegistered
        if !appNotificationAdded {
            log.info("Focus notification not added yet: AX error \(result.rawValue, privacy: .public)")
        }
    }

    /// Re-reads the focused element, e.g. when a notification may have been missed.
    func refreshFocus() {
        unwatchElement()
        focused = appElement?.focusedElement
        log.info("Focus: \(self.app?.bundleIdentifier ?? "-", privacy: .public) \(self.focused?.role ?? "nothing", privacy: .public)")
        if let observer, let focused {
            for name in Self.elementNotifications {
                let result = AXObserverAddNotification(observer, focused.ref, name as CFString, selfPointer)
                if result != .success {
                    log.info("\(name, privacy: .public) not added: AX error \(result.rawValue, privacy: .public)")
                }
            }
            watchedElement = focused
            if let window = focused.window {
                for name in Self.windowNotifications {
                    AXObserverAddNotification(observer, window.ref, name as CFString, selfPointer)
                }
                watchedWindow = window
            }
        }
        onEvent?(.focusChanged)
    }

    private var selfPointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func attach(to app: NSRunningApplication?) {
        detach()
        // Our own menu doesn't count as typing somewhere: keep nothing focused.
        guard let app, app.processIdentifier != getpid() else {
            onEvent?(.focusChanged)
            return
        }
        self.app = app
        let pid = app.processIdentifier
        var created: AXObserver?
        guard AXObserverCreate(pid, focusTrackerCallback, &created) == .success, let created else {
            onEvent?(.focusChanged)
            return
        }
        observer = created
        appElement = .application(pid)
        addAppNotification(created, appElement!)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        refreshFocus()
    }

    private func detach() {
        unwatchElement()
        if let observer {
            if let appElement {
                AXObserverRemoveNotification(observer, appElement.ref, "AXFocusedUIElementChanged" as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appNotificationAdded = false
        appElement = nil
        focused = nil
        app = nil
    }

    private func unwatchElement() {
        guard let observer else { return }
        if let watchedElement {
            for name in Self.elementNotifications {
                AXObserverRemoveNotification(observer, watchedElement.ref, name as CFString)
            }
        }
        if let watchedWindow {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, watchedWindow.ref, name as CFString)
            }
        }
        watchedElement = nil
        watchedWindow = nil
    }

    fileprivate func handle(_ notification: String) {
        switch notification {
        case "AXFocusedUIElementChanged", "AXUIElementDestroyed": refreshFocus()
        case "AXValueChanged": onEvent?(.valueChanged)
        default: onEvent?(.geometryChanged)
        }
    }
}

/// AX calls this on the main run loop (the observer's source is added there).
private func focusTrackerCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { tracker.handle(name) }
}
