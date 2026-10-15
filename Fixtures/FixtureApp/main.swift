import AppKit

// A tiny app for scripts/m2-check.py (decision 0006). It takes JSON commands on /tmp/wa-fixture.sock
// and changes its fields with insertText, the same path as typing, so Accessibility notifications fire.

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 640, height: 420),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let textView: NSTextView
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 120, width: 600, height: 280))
    let field = NSTextField(frame: NSRect(x: 20, y: 70, width: 600, height: 24))
    let secure = NSSecureTextField(frame: NSRect(x: 20, y: 30, width: 600, height: 24))
    var server: LineSocketServer?

    override init() {
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 280))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "WA Fixture"
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        for view in [scroll, field, secure] as [NSView] { window.contentView?.addSubview(view) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        let server = LineSocketServer(path: "/tmp/wa-fixture.sock") { line in
            await MainActor.run { [weak self] in self?.run(line) ?? "{}" }
        }
        try? server.start()
        self.server = server
    }

    func run(_ line: String) -> String {
        guard let command = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let name = command["cmd"] as? String else { return #"{"ok":false}"# }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        switch name {
        case "set":
            // Select all, then "type" the new text over it.
            let target = editor(command["field"] as? String)
            target.insertText(command["text"] as? String ?? "", replacementRange: NSRange(location: 0, length: target.string.utf16.count))
        case "replace":
            // Replace the first occurrence of `from` with `to`, as typing would.
            let target = editor(command["field"] as? String)
            let range = (target.string as NSString).range(of: command["from"] as? String ?? "")
            guard range.location != NSNotFound else { return #"{"ok":false}"# }
            target.insertText(command["to"] as? String ?? "", replacementRange: range)
        case "focus":
            _ = editor(command["field"] as? String)
        case "move":
            var frame = window.frame
            frame.origin.x += command["dx"] as? CGFloat ?? 0
            window.setFrame(frame, display: true)
        default:
            return #"{"ok":false}"#
        }
        return #"{"ok":true}"#
    }

    /// Focuses a field and returns the text view that edits it (field editors for the single-line fields).
    private func editor(_ name: String?) -> NSTextView {
        switch name {
        case "field", "secure":
            let control: NSTextField = name == "secure" ? secure : field
            window.makeFirstResponder(control)
            return (control.currentEditor() as? NSTextView) ?? textView
        default:
            window.makeFirstResponder(textView)
            return textView
        }
    }
}

let app = NSApplication.shared
let delegate = Fixture()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
