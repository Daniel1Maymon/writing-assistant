import AppKit
import Core
import SwiftUI

/// The small button just after a selection (decision 0019). A non-activating panel, like the card, so a click on it
/// leaves the focus and the selection in the app.
@MainActor
final class SelectionButtonController {
    private let panel: NSPanel
    private static let size = CGSize(width: 24, height: 24)
    var onClick: (() -> Void)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: SelectionButtonView { [weak self] in self?.onClick?() })
    }

    var isVisible: Bool { panel.isVisible }

    /// The button's frame in AX coordinates, for the debug socket.
    var axFrame: CGRect? { panel.isVisible ? OverlayController.cocoa(panel.frame) : nil }

    /// Places the button just after `lastCharacter` (AX coordinates), centred on its line.
    func show(after lastCharacter: CGRect) {
        let char = OverlayController.cocoa(lastCharacter)
        let frame = CGRect(x: char.maxX + 4, y: char.midY - Self.size.height / 2, width: Self.size.width, height: Self.size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

private struct SelectionButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Check this")
        .frame(width: 24, height: 24)
    }
}

/// The card for an on-demand check: "Checking…", then the corrected text and other ways to say it.
@MainActor
final class ManualCardController {
    enum Phase: Equatable {
        case checking
        case result(ManualResult)
        case failed(String)
    }

    private let panel: NSPanel
    private var anchor = CGRect.zero
    private(set) var phase: Phase?
    /// Called with the chosen text and whether it's the correction (rather than an alternative).
    var onPick: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

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

    /// The choices in the order shown: the correction first (unless it looks good), then the alternatives.
    var choices: [(text: String, correction: Bool)] {
        guard case .result(let result) = phase else { return [] }
        return (result.looksGood ? [] : [(result.corrected, true)]) + result.alternatives.map { ($0, false) }
    }

    /// Opens under `selection` (AX coordinates).
    func show(_ phase: Phase, under selection: CGRect) {
        anchor = selection
        update(phase)
    }

    func update(_ phase: Phase) {
        self.phase = phase
        let view = ManualCardView(phase: phase, choices: choices) { [weak self] action in
            switch action {
            case .pick(let index):
                guard let self, choices.indices.contains(index) else { return }
                onPick?(choices[index].text, choices[index].correction)
            case .close:
                self?.onClose?()
            }
        }
        let hosting = FirstClickHostingView(rootView: view)
        let size = hosting.fittingSize
        panel.contentView = hosting
        let below = OverlayController.cocoa(anchor)
        var origin = CGPoint(x: below.minX, y: below.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(below) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY { origin.y = below.maxY + 4 }  // no room below: open above
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        phase = nil
        panel.orderOut(nil)
    }

    func contains(cocoaPoint: CGPoint) -> Bool { panel.isVisible && panel.frame.contains(cocoaPoint) }

    #if DEBUG
    var snapshotPNG: Data? { panel.isVisible ? panel.contentView?.pngData() : nil }
    #endif
}

private struct ManualCardView: View {
    enum Action { case pick(Int), close }

    let phase: ManualCardController.Phase
    let choices: [(text: String, correction: Bool)]
    let perform: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .result(let result):
                if result.looksGood {
                    Label("Looks good", systemImage: "checkmark.circle.fill")
                        .font(.callout.bold())
                        .foregroundStyle(.green)
                } else {
                    Text("Corrected").font(.caption.bold()).foregroundStyle(.red)
                    if !result.reason.isEmpty {
                        Text(result.reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    if !choice.correction, index == 0 || choices[index - 1].correction {
                        Text("Other ways to say it").font(.caption.bold()).foregroundStyle(.blue)
                    }
                    Button { perform(.pick(index)) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text(choice.text)
                                .fontWeight(index == 0 ? .bold : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if index == 0 {
                                Text("⌥⏎").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.text)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(index == 0 ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()
            HStack {
                Button("Close") { perform(.close) }
                    .buttonStyle(.link)
                Spacer()
                Text("Esc").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
