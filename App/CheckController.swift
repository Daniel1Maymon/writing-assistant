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
        var accepts = 0
        var mistakesLogged = 0
        var mistakeLogFailures = 0
        var lastApply: String?
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
    static let saveFixesKey = "saveAcceptedFixes"

    private let card = CardController()
    /// Check on demand (decision 0019): the button after a selection, and its card.
    private let selectionButton = SelectionButtonController()
    let manualCard = ManualCardController()
    /// What the open on-demand card would replace: the range and the text that was there when it was asked.
    private var manualTarget: (range: NSRange, original: String)?
    private var manualTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    let compose = ComposeWindowController()
    private var hotKey: OptionReturnTap?
    private(set) var ignore: IgnoreList
    private let ignoreURL: URL
    var mistakeLogURL = MistakeLog.defaultURL {
        didSet { mistakeLog = nil }
    }
    private var mistakeLog: MistakeLog?
    /// Tier 2 (OpenRouter). Nil until a key is configured.
    private(set) var tierTwo: TierTwoScheduler?
    private var tierTwoTimer: Timer?
    /// The last key press or mouse click anywhere; tier 2 only runs shortly after one (decision 0014).
    private var lastInput: ContinuousClock.Instant?
    private static let inputWindow = Duration.seconds(10)
    /// Called when today's AI use changes, for the menu.
    var onUsageChange: ((UsageLedger, Bool) -> Void)?
    static let ledgerKey = "tierTwoLedger"

    init(ignoreURL: URL = CheckController.defaultIgnoreURL) {
        self.ignoreURL = ignoreURL
        ignore = IgnoreList.load(from: ignoreURL)
    }

    static var defaultIgnoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WritingAssistant/ignore.json")
    }

    func start() {
        UserDefaults.standard.register(defaults: [Self.saveFixesKey: true])
        card.actions = self
        selectionButton.onClick = { [weak self] in self?.checkOnDemand() }
        manualCard.onPick = { [weak self] text, correction in self?.pickManual(text, correction: correction) }
        manualCard.onClose = { [weak self] in self?.hideManual() }
        tracker.onEvent = { [weak self] event in self?.handle(event) }
        tracker.allowsOwnApp = { [weak self] in self?.compose.isKey ?? false }
        compose.onTextEvent = { [weak self] event in self?.tracker.forward(event) }
        compose.onFocusChange = { [weak self] in self?.tracker.reattach() }
        tracker.start()
        // A global monitor sees clicks in other apps and lets them through; the overlay stays click-through.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                self?.lastInput = .now
                self?.clicked(at: point)
            }
        }
        // The global monitor never sees clicks in our own windows; the Writing window needs them for the card.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                if let self, event.window != nil, event.window === self.compose.window {
                    self.lastInput = .now
                    self.clicked(at: point)
                }
            }
            return event
        }
        hotKey = OptionReturnTap { [weak self] in self?.optionReturn() ?? false }
        hotKey?.onCompose = { [weak self] in self?.compose.toggle() }
        hotKey?.onKeyDown = { [weak self] in self?.lastInput = .now }
        hotKey?.onCheck = { [weak self] in self?.wantsCheckKey() ?? false }
        hotKey?.onEscape = { [weak self] in self?.escape() ?? false }
        if hotKey?.start() != true {
            log.error("Option-Return tap could not start")
        }
        // Catches scrolling, which has no AX notification of its own. Cheap: one AX call per underline.
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.redraw()
                self?.updateSelectionButton()
            }
        }
    }

    /// Starts (or replaces) tier 2. `send` nil turns it off.
    func configureTierTwo(models: [String], cap: Int, send: TierTwoScheduler.Send?) {
        tierTwo = nil
        tierTwoTimer?.invalidate()
        tierTwoTimer = nil
        guard let send else { return }
        let saved = UserDefaults.standard.data(forKey: Self.ledgerKey)
            .flatMap { try? JSONDecoder().decode(UsageLedger.self, from: $0) } ?? UsageLedger()
        let scheduler = TierTwoScheduler(models: models, cap: cap, ledger: saved, send: send,
                                         log: { line in log.info("\(line, privacy: .public)") })
        scheduler.onResult = { [weak self] sentence, found in
            guard let self else { return }
            document.storeLLM(found, for: sentence.hash)
            redraw()
        }
        scheduler.onLedgerChange = { [weak self, weak scheduler] ledger in
            UserDefaults.standard.set(try? JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
            self?.onUsageChange?(ledger, scheduler?.capReached ?? false)
        }
        tierTwo = scheduler
        onUsageChange?(scheduler.ledger, scheduler.capReached)
        // The caret can leave a sentence without any text change (a click elsewhere): look again every second.
        tierTwoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTierTwo() }
        }
    }

    /// Terminal output isn't the user's writing: nothing is checked there (decisions 0013, 0014).
    static let terminals: Set<String> = ["com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2",
                                         "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]

    private func updateTierTwo() {
        guard let tierTwo, let element, !element.isSecure,
              let lastInput, ContinuousClock.now - lastInput < Self.inputWindow else { return }
        let caret = element.selectedRange?.location
        let document = document
        tierTwo.update(sentences: document.sentences, caret: caret) { document.hasLLMResults(for: $0) }
    }

    var focusedApp: NSRunningApplication? { tracker.app }
    var focusedElement: AXElement? { element }

    private func handle(_ event: FocusTracker.Event) {
        switch event {
        case .focusChanged:
            // Apps re-announce focus on the same field (e.g. a click inside it): keep its results then.
            guard tracker.focused != element else { return }
            card.hide()
            hideManual()
            // Terminals and read-only web pages aren't the user's writing (decisions 0013, 0021).
            element = Self.terminals.contains(tracker.app?.bundleIdentifier ?? "") || tracker.focused?.isReadOnlyPage == true
                ? nil : tracker.focused
            document = DocumentState()
            tierTwo?.update(sentences: [], caret: nil) { _ in true }
            redraw()
            schedule(after: .zero)
        case .valueChanged:
            card.hide()
            hideManual()
            // Re-split right away so unchanged sentences keep their underlines in the right place.
            if let element, !element.isSecure, let text = element.value {
                _ = document.update(text: text)
                updateTierTwo()
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
        updateTierTwo()
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

    /// A text view inside a scroll view is as tall as its text; only the scroll view's frame is visible.
    private static func visibleArea(of element: AXElement, frame: CGRect) -> CGRect {
        (element.parent.flatMap { $0.role == "AXScrollArea" ? $0.frame : nil } ?? frame).intersection(frame)
    }

    private func redraw() {
        guard let element, !element.isSecure, NSWorkspace.shared.frontmostApplication?.processIdentifier == tracker.app?.processIdentifier,
              let fieldFrame = element.frame else {
            drawn = []
            overlay.hide()
            return
        }
        let visible = Self.visibleArea(of: element, frame: fieldFrame)
        drawn = document.placed(ignoring: ignore).compactMap { placed in
            guard let rect = element.bounds(for: placed.range), rect.width > 0 else { return nil }
            let clipped = rect.intersection(visible)
            return clipped.isNull || clipped.width <= 0 ? nil : (placed, clipped)
        }
        overlay.show(area: visible, marks: drawn.map {
            .init(rect: $0.rect, category: $0.placed.suggestion.category, rewrite: $0.placed.suggestion.rewrite)
        })
    }
}

// MARK: Card, accept, dismiss

extension CheckController: CardActions {
    enum AcceptResult: String {
        case accessibility, paste, refused, failed, notFound
    }

    /// The suggestion as shown now, with its range in the whole field.
    private func placed(id: String) -> PlacedSuggestion? {
        document.placed(ignoring: ignore).first { $0.suggestion.id == id }
    }

    private func clicked(at cocoaPoint: CGPoint) {
        guard !card.contains(cocoaPoint: cocoaPoint), !manualCard.contains(cocoaPoint: cocoaPoint) else { return }
        hideManual()
        // The squiggle sits just under the text, so give the hit area a little room below. A word beats its
        // sentence; the sentence-wide line is hit only along the bottom of the sentence.
        let hit = drawn.first { item in
            item.placed.suggestion.rewrite == nil && OverlayController.cocoa(item.rect).insetBy(dx: -1, dy: -3).contains(cocoaPoint)
        } ?? drawn.first { item in
            item.placed.suggestion.rewrite != nil && OverlayController.cocoa(Self.rewriteBand(item.rect)).contains(cocoaPoint)
        }
        if let hit {
            card.show(hit.placed.suggestion, under: hit.rect)
        } else {
            card.hide()
        }
    }

    /// Where the dashed sentence line can be clicked (AX coordinates).
    static func rewriteBand(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - 1, y: rect.maxY - 6, width: rect.width + 2, height: 10)
    }

    /// ⌥⏎: returns true when it accepted something, so the key is swallowed.
    private func optionReturn() -> Bool {
        if manualCard.isVisible {
            guard let first = manualCard.choices.first else { return false }
            pickManual(first.text, correction: first.correction)
            return true
        }
        guard let target = card.suggestion ?? suggestionAtCaret()?.suggestion,
              !target.replacements.isEmpty, let placed = placed(id: target.id), let text = element?.value,
              // Positions can be a moment stale (some apps report edits late): only take the key if the word is really there.
              applyEdit(to: text, range: placed.range, original: target.original, replacement: "") != nil
        else { return false }
        card.hide()
        accept(target, replacementIndex: 0)
        return true
    }

    func suggestionAtCaret() -> PlacedSuggestion? {
        guard let element, NSWorkspace.shared.frontmostApplication?.processIdentifier == tracker.app?.processIdentifier,
              let caret = element.selectedRange, caret.length == 0 else { return nil }
        let here = document.placed(ignoring: ignore).filter {
            caret.location >= $0.range.location && caret.location <= NSMaxRange($0.range)
        }
        return here.first { $0.suggestion.rewrite == nil } ?? here.first
    }

    func accept(_ suggestion: Suggestion, replacementIndex: Int) {
        Task { await acceptNow(id: suggestion.id, replacementIndex: replacementIndex) }
    }

    @discardableResult
    func acceptNow(id: String, replacementIndex: Int, forcePaste: Bool = false) async -> AcceptResult {
        guard let placed = placed(id: id), placed.suggestion.replacements.indices.contains(replacementIndex) else {
            return .notFound
        }
        let s = placed.suggestion
        return await replace(range: placed.range, original: s.original, with: s.replacements[replacementIndex],
                             category: s.category, message: s.message, ruleId: s.ruleId, source: s.source,
                             forcePaste: forcePaste)
    }

    /// Writes one fix into the field and, if it landed, logs it. Also used for whole-sentence replacements.
    func replace(range: NSRange, original: String, with replacement: String, category: SuggestionCategory,
                 message: String, ruleId: String?, source: SuggestionSource, forcePaste: Bool = false) async -> AcceptResult {
        guard let element, !element.isSecure else { return .failed }
        let sentence = document.sentences.first { NSIntersectionRange($0.range, range).length > 0 || $0.range.location == range.location }
        let app = tracker.app
        let outcome = await Applier.apply(in: element, range: range, original: original, replacement: replacement,
                                          forcePaste: forcePaste)
        counters.lastApply = outcome.rawValue
        log.info("Apply: \(outcome.rawValue, privacy: .public)")
        guard outcome == .accessibility || outcome == .paste else {
            return outcome == .refused ? .refused : .failed
        }
        counters.accepts += 1
        // Don't wait for the app's change notification: keep positions right for the next ⌥⏎ or click.
        if let text = element.value {
            _ = document.update(text: text)
            redraw()
            schedule(after: .zero)
        }
        if UserDefaults.standard.bool(forKey: Self.saveFixesKey) {
            record(MistakeEntry(createdAt: Date(), appBundleId: app?.bundleIdentifier ?? "",
                                appName: app?.processIdentifier == getpid() ? ComposeWindowController.title
                                    : app?.localizedName ?? "", sentence: sentence?.text ?? original,
                                original: original, replacement: replacement, category: category,
                                message: message, ruleId: ruleId, source: source))
        }
        return outcome == .accessibility ? .accessibility : .paste
    }

    /// A failed write never blocks the fix: it's already in the field.
    private func record(_ entry: MistakeEntry) {
        do {
            if mistakeLog == nil { mistakeLog = try MistakeLog(url: mistakeLogURL) }
            _ = try mistakeLog?.record(entry)
            counters.mistakesLogged += 1
            NotificationCenter.default.post(name: .mistakeRecorded, object: nil)
        } catch {
            mistakeLog = nil
            counters.mistakeLogFailures += 1
            log.error("Mistake log write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func dismiss(_ suggestion: Suggestion) {
        updateIgnore { $0.dismissed.insert(suggestion.id) }
    }

    func ignoreRule(of suggestion: Suggestion) {
        guard let rule = suggestion.ruleId else { return }
        updateIgnore { $0.rules.insert(rule) }
    }

    func addToDictionary(_ suggestion: Suggestion) {
        updateIgnore { $0.dictionary.insert(suggestion.original.lowercased()) }
    }

    func resetIgnore() {
        updateIgnore { $0 = IgnoreList() }
    }

    private func updateIgnore(_ change: (inout IgnoreList) -> Void) {
        change(&ignore)
        do {
            try ignore.save(to: ignoreURL)
        } catch {
            log.error("Ignore list save failed: \(String(describing: error), privacy: .public)")
        }
        redraw()
    }

    func suggestion(id: String) -> Suggestion? { placed(id: id)?.suggestion }

    #if DEBUG
    /// Writes overlay.png and card.png (when shown) into `dir`; returns the paths written.
    func snapshot(to dir: URL) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return [("overlay.png", overlay.snapshotPNG), ("card.png", card.snapshotPNG)].compactMap { name, data in
            let url = dir.appendingPathComponent(name)
            guard let data, (try? data.write(to: url)) != nil else { return nil }
            return url.path
        }
    }
    #endif

    var cardSuggestionId: String? { card.isVisible ? card.suggestion?.id : nil }
}

/// Watches every key press for ⌥⏎ and swallows it only when `handler` used it.
@MainActor
final class OptionReturnTap {
    private let handler: () -> Bool
    private var tap: CFMachPort?
    /// Every key press, swallowed or not.
    var onKeyDown: (() -> Void)?
    /// ⌃⌥Space: open or close the Writing window (decision 0016). Always swallowed.
    var onCompose: (() -> Void)?
    /// ⌃⌥G: check the selection (decision 0019). Swallowed when it returns true.
    var onCheck: (() -> Bool)?
    /// Esc: swallowed when it returns true.
    var onEscape: (() -> Bool)?

    init(handler: @escaping () -> Bool) { self.handler = handler }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<OptionReturnTap>.fromOpaque(info).takeUnretainedValue()
            let type = type.rawValue
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            let swallow = MainActor.assumeIsolated { me.shouldSwallow(type: type, key: key, flags: flags) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func shouldSwallow(type: UInt32, key: Int64, flags: UInt64) -> Bool {
        if type == CGEventType.tapDisabledByTimeout.rawValue || type == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if type == CGEventType.keyDown.rawValue { onKeyDown?() }
        let modifiers = CGEventFlags(rawValue: flags).intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        if type == CGEventType.keyDown.rawValue, key == 49, modifiers == [.maskControl, .maskAlternate], let onCompose {
            DispatchQueue.main.async { onCompose() }  // not inside the tap callback, which must return fast
            return true
        }
        if type == CGEventType.keyDown.rawValue, key == 5, modifiers == [.maskControl, .maskAlternate], let onCheck {
            return onCheck()
        }
        if type == CGEventType.keyDown.rawValue, key == 53, modifiers.isEmpty, let onEscape {
            return onEscape()
        }
        return type == CGEventType.keyDown.rawValue && (key == 36 || key == 76) && modifiers == .maskAlternate && handler()
    }
}

// MARK: Check on demand (decision 0019)

extension CheckController {
    private var isWatchingFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == tracker.app?.processIdentifier
    }

    /// ⌃⌥G, inside the key tap: take the key only when there's a field to check; the work runs after the tap returns.
    fileprivate func wantsCheckKey() -> Bool {
        guard let element, !element.isSecure, isWatchingFront else { return false }
        DispatchQueue.main.async { [weak self] in self?.checkOnDemand() }
        return true
    }

    fileprivate func escape() -> Bool {
        guard manualCard.isVisible else { return false }
        DispatchQueue.main.async { [weak self] in self?.hideManual() }
        return true
    }

    /// Checks the selection, or with no selection the caret's sentence, and opens the card under it.
    func checkOnDemand() {
        guard let element, !element.isSecure, isWatchingFront, let text = element.value,
              let selection = element.selectedRange else { return }
        let ns = text as NSString
        var range = selection
        if range.length == 0 {
            guard let sentence = document.sentences.first(where: {
                selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range)
            }) else { return }
            range = sentence.range
        }
        range = Self.trimmed(range, in: ns)
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return }
        let original = ns.substring(with: range)
        guard original.rangeOfCharacter(from: .letters) != nil else { return }
        let before = document.sentences.last { NSMaxRange($0.range) <= range.location }?.text
        let after = document.sentences.first { $0.range.location >= NSMaxRange(range) }?.text

        card.hide()
        selectionButton.hide()
        manualTask?.cancel()
        manualTarget = (range, original)
        manualCard.show(.checking, under: anchorRect(for: range, in: element))
        guard let tierTwo else {
            manualCard.update(.failed("No AI key yet. Add your OpenRouter key from the menu bar icon."))
            return
        }
        log.info("On-demand check: \(range.length, privacy: .public) characters")
        manualTask = Task { [weak self] in
            do {
                let response = try await tierTwo.checkNow(original, before: before, after: after)
                guard !Task.isCancelled, let self, self.manualTarget?.range == range else { return }
                manualCard.update(.result(response.result))
            } catch {
                guard !Task.isCancelled, let self, self.manualTarget?.range == range else { return }
                let detail = tierTwo.counters.lastError.map { " (\($0))" } ?? ""
                manualCard.update(.failed("Couldn't reach the AI\(detail). Try again in a moment."))
            }
        }
    }

    /// Where to open the card: under the text, or at the mouse when the app can't say where the text is.
    private func anchorRect(for range: NSRange, in element: AXElement) -> CGRect {
        if let rect = element.bounds(for: range), rect.width > 0, rect.height > 0 { return rect }
        let mouse = NSEvent.mouseLocation
        return OverlayController.cocoa(CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1))  // the same flip both ways
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        let text = ns.substring(with: range)
        let leading = text.prefix { $0.isWhitespace }.utf16.count
        let trailing = String(text.reversed().prefix { $0.isWhitespace }).utf16.count
        return NSRange(location: range.location + leading, length: max(range.length - leading - trailing, 0))
    }

    fileprivate func pickManual(_ text: String, correction: Bool) {
        guard let target = manualTarget else { return }
        let reason: String
        if case .result(let result) = manualCard.phase { reason = result.reason } else { reason = "" }
        hideManual()
        Task {
            await replace(range: target.range, original: target.original, with: text,
                          category: correction ? .grammar : .clarity, message: reason,
                          ruleId: correction ? "llm.manual.correction" : "llm.manual.alternative", source: .llm)
        }
    }

    func hideManual() {
        manualTask?.cancel()
        manualTask = nil
        manualTarget = nil
        if manualCard.isVisible { manualCard.hide() }
    }

    /// Shows the button after the last selected character, while text is selected and the mouse is up.
    fileprivate func updateSelectionButton() {
        switch selectionButtonAnchor() {
        case .success(let last): selectionButton.show(after: last)
        case .failure: selectionButton.hide()
        }
    }

    struct NoButton: Error { let reason: String }

    /// Where the button goes (the last selected character, AX coordinates), or why there's none (for the debug socket).
    func selectionButtonAnchor() -> Result<CGRect, NoButton> {
        guard let element, !element.isSecure else { return .failure(NoButton(reason: "no field")) }
        guard isWatchingFront else { return .failure(NoButton(reason: "field not in the front app")) }
        guard !manualCard.isVisible else { return .failure(NoButton(reason: "card open")) }
        guard NSEvent.pressedMouseButtons == 0 else { return .failure(NoButton(reason: "mouse down")) }
        guard let selection = element.selectedRange, selection.length > 1, let text = element.value
        else { return .failure(NoButton(reason: "no selection")) }
        guard let fieldFrame = element.frame else { return .failure(NoButton(reason: "no field frame")) }
        let ns = text as NSString
        let range = Self.trimmed(selection, in: ns)
        guard range.length > 1, NSMaxRange(range) <= ns.length,
              ns.substring(with: range).rangeOfCharacter(from: .letters) != nil
        else { return .failure(NoButton(reason: "no letters selected")) }
        guard let last = element.bounds(for: NSRange(location: NSMaxRange(range) - 1, length: 1)),
              last.width > 0, last.height > 0
        else { return .failure(NoButton(reason: "no character rect")) }
        guard Self.visibleArea(of: element, frame: fieldFrame).contains(CGPoint(x: last.midX, y: last.midY))
        else { return .failure(NoButton(reason: "last character not visible \(last) in \(Self.visibleArea(of: element, frame: fieldFrame))")) }
        return .success(last)
    }

    var selectionButtonFrame: CGRect? { selectionButton.axFrame }
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
