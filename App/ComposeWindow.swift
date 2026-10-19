import AppKit

/// The "Writing window" (⌃⌥Space): write with full checking, then paste the text back into the app that was in
/// front, or copy it (decision 0016). The checker follows its text view like any other app's field.
@MainActor
final class ComposeWindowController: NSObject, NSWindowDelegate {
    static let title = "Writing window"

    /// Our own process gets no AX change notifications, so the window reports its changes itself.
    var onTextEvent: ((FocusTracker.Event) -> Void)?

    /// Always on the next run-loop turn: a change can come from inside an AX call on our own process (accepting a
    /// fix sets the selection), and reading AX again from there deadlocks (decision 0016).
    private func report(_ event: FocusTracker.Event) {
        DispatchQueue.main.async { [weak self] in self?.onTextEvent?(event) }
    }
    /// Called when the window becomes or stops being the key window, so the tracker re-attaches.
    var onFocusChange: (() -> Void)?

    private(set) var window: NSWindow?
    private var textView: NSTextView!
    /// The app to paste back into: the one in front when the window opened.
    private(set) var previousApp: NSRunningApplication?

    var isKey: Bool { window?.isKeyWindow ?? false }
    var isVisible: Bool { window?.isVisible ?? false }
    var text: String {
        get { textView?.string ?? "" }
        set { makeWindow(); textView.string = newValue; textChanged() }
    }

    func toggle() {
        if isKey { close() } else { show() }
    }

    func show() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            previousApp = front
        }
        makeWindow()
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    /// Esc: hide, keep the draft, give focus back.
    func close() {
        window?.orderOut(nil)
        previousApp?.activate()
    }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        close()
    }

    /// Pastes into the previous app with ⌘V, then restores the user's clipboard. Clears the draft.
    func pasteBack() {
        let text = text
        guard !text.isEmpty else { return close() }
        let pasteboard = NSPasteboard.general
        let saved = Clipboard.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        window?.orderOut(nil)
        let target = previousApp
        target?.activate()
        Task { @MainActor in
            // Wait for the app to be in front before pasting, or ⌘V goes nowhere.
            for _ in 0..<50 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target?.processIdentifier {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(150))
            Clipboard.sendCommandV()
            try? await Task.sleep(for: .milliseconds(400))
            Clipboard.restore(saved, to: pasteboard)
            self.textView.string = ""
            self.textChanged()
        }
    }

    private func makeWindow() {
        guard window == nil else { return }
        let window = ComposeWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        window.setFrameAutosaveName("WritingWindow")

        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as? NSTextView
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.allowsUndo = true
        // Our underlines only: the system's own spelling and substitutions would compete with them.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        let paste = NSButton(title: "Paste back", target: self, action: #selector(pasteClicked))
        paste.keyEquivalent = "\r"
        paste.keyEquivalentModifierMask = .command
        paste.bezelColor = .controlAccentColor
        let hint = NSTextField(labelWithString: "⌘⏎ paste back · Esc close")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [hint, NSView(), copy, paste])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack

        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(.geometryChanged) }
        }
        self.window = window
    }

    private func textChanged() { report(.valueChanged) }

    @objc private func copyClicked() { copyText() }
    @objc private func pasteClicked() { pasteBack() }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { onFocusChange?() }
    func windowDidResignKey(_ notification: Notification) { onFocusChange?() }
    func windowDidMove(_ notification: Notification) { report(.geometryChanged) }
    func windowDidResize(_ notification: Notification) { report(.geometryChanged) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}

/// The text view passes Esc up as `cancelOperation:`.
private final class ComposeWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
