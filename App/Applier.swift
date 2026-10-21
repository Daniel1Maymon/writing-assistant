import AppKit
import Core
import OSLog

private let log = Logger(subsystem: "com.danielmaymon.WritingAssistant", category: "apply")

/// Writes a fix into another app's field: through Accessibility first, then by pasting.
@MainActor
enum Applier {
    enum Outcome: String {
        case accessibility, paste
        /// The text at the span isn't `original` any more; nothing was written.
        case refused
        case failed
    }

    static func apply(in element: AXElement, range: NSRange, original: String, replacement: String,
                      forcePaste: Bool = false) async -> Outcome {
        guard let before = element.value,
              let expected = applyEdit(to: before, range: range, original: original, replacement: replacement)
        else { return .refused }

        if !forcePaste {
            if element.setSelectedRange(range) == .success, element.setSelectedText(replacement) == .success {
                if await waitForValue(expected.text, in: element, timeout: .milliseconds(200)) {
                    element.setSelectedRange(NSRange(location: expected.caret, length: 0))
                    return .accessibility
                }
            }
            // Some apps accept the call but change nothing; if they changed something else, don't paste on top.
            if element.value != before {
                log.error("AX write changed the field unexpectedly; not pasting")
                return .failed
            }
        }
        return await paste(replacement, over: range, in: element, expecting: expected)
    }

    private static func paste(_ replacement: String, over range: NSRange, in element: AXElement,
                              expecting expected: AppliedEdit) async -> Outcome {
        guard element.setSelectedRange(range) == .success else { return .failed }
        let pasteboard = NSPasteboard.general
        let saved = Clipboard.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
        Clipboard.sendCommandV()

        // Wait for the paste to land before giving the user's clipboard back.
        let landed = await waitForValue(expected.text, in: element, timeout: .seconds(1))
        try? await Task.sleep(for: .milliseconds(50))
        Clipboard.restore(saved, to: pasteboard)
        return landed ? .paste : .failed
    }

    /// Some apps update their AX value a moment after the change.
    private static func waitForValue(_ text: String, in element: AXElement, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if element.value == text { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Saving and restoring the user's clipboard around a paste.
enum Clipboard {
    static func sendCommandV() { send(9, .maskCommand) }

    /// ⌃E ⌃U: end of line, then delete the line. The same in bash, zsh, Claude Code and tmux (decision 0020).
    static func clearTerminalLine() {
        send(14, .maskControl)
        send(32, .maskControl)
    }

    private static func send(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
