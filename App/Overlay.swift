import AppKit
import Core

/// A click-through window over the text field that draws squiggles under flagged words.
@MainActor
final class OverlayController {
    struct Mark {
        /// AX screen coordinates (top-left origin).
        let rect: CGRect
        let category: SuggestionCategory
    }

    private let panel: NSPanel
    private let view = SquiggleView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    /// `area` is the visible part of the field, in AX coordinates; marks outside it are clipped.
    func show(area: CGRect, marks: [Mark]) {
        guard !marks.isEmpty, area.width > 0, area.height > 0 else { return hide() }
        let frame = Self.cocoa(area)
        panel.setFrame(frame, display: false)
        view.marks = marks.map { mark in
            let r = Self.cocoa(mark.rect)
            return (CGRect(x: r.minX - frame.minX, y: r.minY - frame.minY, width: r.width, height: r.height), mark.category)
        }
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        view.marks = []
        panel.orderOut(nil)
    }

    /// AX coordinates have their origin at the top-left of the main screen; Cocoa's at the bottom-left.
    static func cocoa(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

final class SquiggleView: NSView {
    var marks: [(rect: CGRect, category: SuggestionCategory)] = []

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            color(for: mark.category).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.5
            let y = mark.rect.minY + 1.5
            let step: CGFloat = 2.5
            var x = mark.rect.minX
            path.move(to: CGPoint(x: x, y: y))
            var up = true
            while x < mark.rect.maxX {
                x = min(x + step, mark.rect.maxX)
                path.line(to: CGPoint(x: x, y: up ? y + 1.5 : y - 1.5))
                up.toggle()
            }
            path.stroke()
        }
    }

    private func color(for category: SuggestionCategory) -> NSColor {
        switch category {
        case .spelling: .systemRed
        case .grammar, .punctuation: .systemOrange
        case .clarity, .concise: .systemBlue
        }
    }
}
