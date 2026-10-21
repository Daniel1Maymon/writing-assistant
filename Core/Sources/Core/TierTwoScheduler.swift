import Foundation

/// Today's model use: number of requests and cost. A new day starts from zero.
public struct UsageLedger: Codable, Equatable, Sendable {
    public var day: String
    public var requests: Int
    public var cost: Double

    public init(day: String = "", requests: Int = 0, cost: Double = 0) {
        self.day = day
        self.requests = requests
        self.cost = cost
    }

    public static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public mutating func rollOver(to day: String) {
        if self.day != day { self = UsageLedger(day: day) }
    }
}

/// Starts, caches and cancels tier-2 requests (decision 0010). The network call is passed in.
@MainActor
public final class TierTwoScheduler {
    public typealias Send = @Sendable (Data) async throws -> Data

    public struct Counters: Codable, Equatable, Sendable {
        public var requests = 0
        public var answers = 0
        public var cacheHits = 0
        public var failures = 0
        public var cancelled = 0
        /// On-demand checks (decision 0019), also counted in `requests`.
        public var manual = 0
        public var lastError: String?
    }

    public private(set) var ledger: UsageLedger
    public private(set) var counters = Counters()
    public let cap: Int
    /// Only the caret's sentence and this many on each side are sent; with no caret, nothing (decision 0013).
    public var nearCaret = 2
    /// Delivers suggestions for a sentence; the receiver must still check the sentence is current.
    public var onResult: ((Sentence, [Suggestion]) -> Void)?
    public var onLedgerChange: ((UsageLedger) -> Void)?

    private let models: [String]
    private let send: Send
    private let log: @Sendable (String) -> Void
    private let now: () -> Date
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]
    private var cache = LRUCache<String, LLMResult>(capacity: 500)
    private var preferFallback = false
    private static let maxAttempts = 3

    public init(models: [String], cap: Int, ledger: UsageLedger = UsageLedger(), send: @escaping Send,
                log: @escaping @Sendable (String) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.models = models.filter { !$0.isEmpty }
        self.cap = cap
        self.ledger = ledger
        self.send = send
        self.log = log
        self.now = now
    }

    public var capReached: Bool {
        var today = ledger
        today.rollOver(to: UsageLedger.dayKey(now()))
        return today.requests >= cap
    }

    public var inFlightCount: Int { inFlight.count }

    /// Call whenever the text or the caret may have changed. `done` says whether a sentence already has a model answer.
    public func update(sentences: [Sentence], caret: Int?, done: (String) -> Bool) {
        let present = Set(sentences.map(\.hash))
        for (hash, task) in inFlight where !present.contains(hash) {
            task.cancel()
            inFlight[hash] = nil
            counters.cancelled += 1
            log("tier2: cancelled a request whose sentence changed")
        }
        let window = Self.window(sentences, caret: caret, radius: nearCaret)
        for (index, sentence) in sentences.enumerated() where window.contains(index) {
            guard !done(sentence.hash), inFlight[sentence.hash] == nil,
                  failures[sentence.hash, default: 0] < Self.maxAttempts,
                  isReadyForTierTwo(sentence, caret: caret) else { continue }
            if let cached = cache.get(sentence.hash) {
                counters.cacheHits += 1
                onResult?(sentence, suggestions(from: cached, in: sentence))
                continue
            }
            ledger.rollOver(to: UsageLedger.dayKey(now()))
            guard ledger.requests < cap else {
                log("tier2: daily cap reached")
                break
            }
            ledger.requests += 1
            onLedgerChange?(ledger)
            let before = index > 0 ? sentences[index - 1].text : nil
            let after = index + 1 < sentences.count ? sentences[index + 1].text : nil
            start(sentence, before: before, after: after)
        }
    }

    /// An on-demand check (decision 0019): none of the rules above and no cap, since the user asked for it.
    /// It still counts as a request today and its cost is added.
    public func checkNow(_ text: String, before: String?, after: String?) async throws -> ManualResponse {
        ledger.rollOver(to: UsageLedger.dayKey(now()))
        ledger.requests += 1
        counters.requests += 1
        counters.manual += 1
        onLedgerChange?(ledger)
        let order = preferFallback && models.count > 1 ? Array(models.reversed()) : models
        log("tier2: on-demand check started")
        do {
            let response = try ManualCheck.parse(try await send(ManualCheck.body(text: text, before: before, after: after,
                                                                                   models: order)), text: text)
            counters.answers += 1
            ledger.rollOver(to: UsageLedger.dayKey(now()))
            ledger.cost += response.cost
            onLedgerChange?(ledger)
            return response
        } catch {
            if !(error is CancellationError) {
                counters.failures += 1
                counters.lastError = Self.describe(error)
                log("tier2: on-demand check failed (\(Self.describe(error)))")
            }
            throw error
        }
    }

    /// The sentence indexes near the caret: the caret's sentence (or the last one starting before it) ± `radius`.
    static func window(_ sentences: [Sentence], caret: Int?, radius: Int) -> Range<Int> {
        guard let caret, !sentences.isEmpty else { return 0..<0 }
        let at = sentences.lastIndex { $0.range.location <= caret } ?? 0
        return max(at - radius, 0)..<min(at + radius + 1, sentences.count)
    }

    private func start(_ sentence: Sentence, before: String?, after: String?) {
        let order = preferFallback && models.count > 1 ? Array(models.reversed()) : models
        let body = TierTwoRequest.body(sentence: sentence.text, before: before, after: after, models: order)
        let send = self.send
        counters.requests += 1
        log("tier2: request started, \(inFlight.count + 1) in flight")
        inFlight[sentence.hash] = Task { [weak self] in
            let outcome: Result<LLMResponse, Error>
            do {
                outcome = .success(try TierTwoRequest.parse(try await send(body)))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finish(sentence, outcome)
        }
    }

    private func finish(_ sentence: Sentence, _ outcome: Result<LLMResponse, Error>) {
        inFlight[sentence.hash] = nil
        switch outcome {
        case .success(let response):
            counters.answers += 1
            preferFallback = false
            ledger.cost += response.cost
            onLedgerChange?(ledger)
            cache.set(sentence.hash, response.result)
            log("tier2: answer with \(response.result.edits.count) edits, rewrite \(response.result.rewrite?.kind.rawValue ?? "none")")
            onResult?(sentence, suggestions(from: response.result, in: sentence))
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            counters.failures += 1
            failures[sentence.hash, default: 0] += 1
            preferFallback = true
            let summary = Self.describe(error)
            counters.lastError = summary
            log("tier2: request failed (\(summary))")
        }
    }

    /// Error summaries never include text: only a fixed name or a status code.
    static func describe(_ error: Error) -> String {
        switch error {
        case TierTwoError.http(let code): "HTTP \(code)"
        case TierTwoError.malformed: "malformed answer"
        case TierTwoError.noKey: "no key"
        case let error as URLError: "network \(error.code.rawValue)"
        default: "other"
        }
    }
}
