import AppKit
import Core
import OSLog

private let log = Logger(subsystem: "com.danielmaymon.WritingAssistant", category: "check")

/// Ties it together: focused field → changed sentences → tier 1 → underlines.
@MainActor
final class CheckController {
    struct Counters: Codable {
        var checks = 0
        var sentencesChecked = 0
        var secureSkips = 0
        var lastRecheckMs: Double?
        var harperStarts = 0
        var fallbackChecks = 0
        /// Checks that ran to the end, and how many sentences the last of them checked.
        var completedChecks = 0
        var lastDirtyCount = 0
    }

    private let tracker = FocusTracker()
    private let overlay = OverlayController()
    let harper = HarperClient()
    private var document = DocumentState()
    private var element: AXElement?
    private var debounce: Task<Void, Never>?
    private var geometryTimer: Timer?
    private(set) var counters = Counters()
    /// The last drawn underlines, for the debug socket.
    private(set) var drawn: [(placed: PlacedSuggestion, rect: CGRect)] = []

    private static let debounceDelay = Duration.milliseconds(400)

    func start() {
        tracker.onEvent = { [weak self] event in self?.handle(event) }
        tracker.start()
        // Catches scrolling, which has no AX notification of its own. Cheap: one AX call per underline.
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
    }

    var focusedApp: NSRunningApplication? { tracker.app }
    var focusedElement: AXElement? { element }

    private func handle(_ event: FocusTracker.Event) {
        switch event {
        case .focusChanged:
            // Apps re-announce focus on the same field (e.g. a click inside it): keep its results then.
            guard tracker.focused != element else { return }
            element = tracker.focused
            document = DocumentState()
            redraw()
            schedule(after: .zero)
        case .valueChanged:
            // Re-split right away so unchanged sentences keep their underlines in the right place.
            if let element, !element.isSecure, let text = element.value {
                _ = document.update(text: text)
            }
            redraw()
            schedule(after: Self.debounceDelay)
        case .geometryChanged:
            redraw()
        }
    }

    private func schedule(after delay: Duration) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    private func check() async {
        guard let element else { return }
        if element.isSecure {
            counters.secureSkips += 1
            return
        }
        guard let text = element.value else { return }
        let started = ContinuousClock.now
        counters.checks += 1
        let dirty = document.update(text: text)

        for sentence in dirty {
            if Task.isCancelled || self.element != element { return }
            let found: [Suggestion]
            do {
                found = try await harper.check(sentence)
            } catch {
                log.error("Harper check failed: \(String(describing: error), privacy: .public)")
                found = SpellFallback.check(sentence)
                counters.fallbackChecks += 1
            }
            if Task.isCancelled || self.element != element { return }
            document.store(found, for: sentence.hash)
            counters.sentencesChecked += 1
        }
        counters.harperStarts = await harper.starts
        counters.completedChecks += 1
        counters.lastDirtyCount = dirty.count
        if !dirty.isEmpty {
            let elapsed = ContinuousClock.now - started
            counters.lastRecheckMs = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
            // Counts and timings only: never the text (CLAUDE.md).
            log.info("Checked \(dirty.count, privacy: .public) sentences in \(self.counters.lastRecheckMs ?? 0, privacy: .public) ms")
        }
        redraw()
    }

    private func redraw() {
        guard let element, !element.isSecure, NSWorkspace.shared.frontmostApplication?.processIdentifier == tracker.app?.processIdentifier,
              let fieldFrame = element.frame else {
            drawn = []
            overlay.hide()
            return
        }
        // A text view inside a scroll view is as tall as its text; only the scroll view's frame is visible.
        let visible = (element.parent.flatMap { $0.role == "AXScrollArea" ? $0.frame : nil } ?? fieldFrame)
            .intersection(fieldFrame)
        drawn = document.placed.compactMap { placed in
            guard let rect = element.bounds(for: placed.range), rect.width > 0 else { return nil }
            let clipped = rect.intersection(visible)
            return clipped.isNull || clipped.width <= 0 ? nil : (placed, clipped)
        }
        overlay.show(area: visible, marks: drawn.map { .init(rect: $0.rect, category: $0.placed.suggestion.category) })
    }
}

/// Used only when Harper can't run: macOS spelling, no grammar.
enum SpellFallback {
    @MainActor
    static func check(_ sentence: Sentence) -> [Suggestion] {
        let checker = NSSpellChecker.shared
        let results = checker.check(sentence.text, range: NSRange(location: 0, length: (sentence.text as NSString).length),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        return results.map { result in
            let word = (sentence.text as NSString).substring(with: result.range)
            let guesses = checker.guesses(forWordRange: result.range, in: sentence.text, language: nil,
                                          inSpellDocumentWithTag: 0) ?? []
            return Suggestion(sentenceHash: sentence.hash, range: result.range, original: word, category: .spelling,
                              message: "Possible spelling mistake", replacements: Array(guesses.prefix(3)),
                              source: .local, ruleId: "mac.spelling")
        }
    }
}
