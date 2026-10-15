import AppKit
import Core
import SwiftUI

/// What the card's buttons do. Implemented by CheckController.
@MainActor
protocol CardActions: AnyObject {
    func accept(_ suggestion: Suggestion, replacementIndex: Int)
    func dismiss(_ suggestion: Suggestion)
    func ignoreRule(of suggestion: Suggestion)
    func addToDictionary(_ suggestion: Suggestion)
}

/// The suggestion card: a small panel under the flagged word. It never takes focus from the app being typed in.
@MainActor
final class CardController {
    private let panel: NSPanel
    private(set) var suggestion: Suggestion?
    weak var actions: CardActions?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    var isVisible: Bool { panel.isVisible }

    /// `wordRect` is in AX coordinates (top-left origin).
    func show(_ suggestion: Suggestion, under wordRect: CGRect) {
        self.suggestion = suggestion
        let view = CardView(suggestion: suggestion) { [weak self] action in self?.perform(action, on: suggestion) }
        let hosting = FirstClickHostingView(rootView: view)
        let size = hosting.fittingSize
        panel.contentView = hosting
        let word = OverlayController.cocoa(wordRect)
        var origin = CGPoint(x: word.minX, y: word.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(word) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY { origin.y = word.maxY + 4 }  // no room below: open above
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        suggestion = nil
        panel.orderOut(nil)
    }

    func contains(cocoaPoint: CGPoint) -> Bool { panel.isVisible && panel.frame.contains(cocoaPoint) }

    private func perform(_ action: CardView.Action, on suggestion: Suggestion) {
        hide()
        switch action {
        case .accept(let index): actions?.accept(suggestion, replacementIndex: index)
        case .dismiss: actions?.dismiss(suggestion)
        case .ignoreRule: actions?.ignoreRule(of: suggestion)
        case .addToDictionary: actions?.addToDictionary(suggestion)
        }
    }
}

/// Buttons in a panel that isn't key must react to the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct CardView: View {
    enum Action { case accept(Int), dismiss, ignoreRule, addToDictionary }

    let suggestion: Suggestion
    let perform: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if suggestion.replacements.isEmpty {
                Text(suggestion.original).strikethrough().font(.body)
                Text("No suggestion").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(suggestion.replacements.enumerated()), id: \.offset) { index, replacement in
                    Button { perform(.accept(index)) } label: {
                        HStack(spacing: 6) {
                            Text(suggestion.original).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption)
                            Text(replacement.isEmpty ? "(remove)" : replacement).bold()
                            Spacer(minLength: 0)
                            if index == 0 {
                                Text("⌥⏎").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(index == 0 ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()
            HStack(spacing: 12) {
                Button("Dismiss") { perform(.dismiss) }
                Button("Ignore rule") { perform(.ignoreRule) }
                    .disabled(suggestion.ruleId == nil)
                if suggestion.category == .spelling {
                    Button("Add to dictionary") { perform(.addToDictionary) }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
