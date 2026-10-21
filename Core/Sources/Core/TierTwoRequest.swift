import Foundation

/// What the model returns for one sentence (DESIGN.md → LLM output contract).
public struct LLMRewrite: Equatable, Sendable {
    public let text: String
    public let kind: RewriteKind
    public let reason: String

    public init(text: String, kind: RewriteKind, reason: String) {
        self.text = text
        self.kind = kind
        self.reason = reason
    }
}

public struct LLMResult: Equatable, Sendable {
    public let edits: [LLMEdit]
    public let rewrite: LLMRewrite?

    public init(edits: [LLMEdit], rewrite: LLMRewrite?) {
        self.edits = edits
        self.rewrite = rewrite
    }
}

public struct LLMResponse: Equatable, Sendable {
    public let result: LLMResult
    /// USD, from `usage.cost`.
    public let cost: Double
    public let model: String?
}

public enum TierTwoError: Error, Equatable {
    case http(Int)
    case malformed
    case noKey
}

public enum TierTwoRequest {
    // The prompt and schema are read by eval/score.py between the PROMPT/SCHEMA markers: keep them raw literals.
    // PROMPT-START
    public static let systemPrompt = #"""
You are a careful English copy editor for a non-native writer. You get one SENTENCE to check, plus the sentences BEFORE and AFTER it for context only. Report problems in SENTENCE only.

edits: small, local fixes. Grammar (agreement, tense, articles, word forms), spelling a spell checker would miss, punctuation, and clearly wordy phrases. For each edit:
- original: copied exactly from SENTENCE, the shortest span that contains the problem (usually 1-3 words).
- replacement: the corrected text for that span.
- category: grammar, spelling, punctuation, clarity or concise.
- reason: plain English, at most 10 words.
Example: in "She dont know." the edit is original "dont", replacement "doesn't" (category grammar): fix the agreement, not only the spelling.

rewrite: null in most cases. Use it only when:
- kind "fix": the sentence is wrong as a whole and word edits can't fix it well (word order, wrong question form, a missing verb). text is the full corrected sentence. Example: "Is it work?" -> "Does it work?".
- kind "natural": the sentence is correct, but a native speaker would clearly say it differently. Do not use it for small style preferences.
If a change would replace most of the sentence, put it in rewrite, not in edits.
If the sentence is fine, return {"edits": [], "rewrite": null}.

Rules: never change the meaning, tone, names or facts. Casual chat style is fine; don't make it formal. If SENTENCE is not English, return no edits and a null rewrite. Answer with JSON only.
"""#
    // PROMPT-END

    // SCHEMA-START
    public static let schemaJSON = #"""
{"type": "object", "additionalProperties": false, "required": ["edits", "rewrite"], "properties": {
  "edits": {"type": "array", "items": {"type": "object", "additionalProperties": false,
    "required": ["original", "replacement", "category", "reason"], "properties": {
      "original": {"type": "string"}, "replacement": {"type": "string"},
      "category": {"type": "string", "enum": ["spelling", "grammar", "punctuation", "clarity", "concise"]},
      "reason": {"type": "string"}}}},
  "rewrite": {"anyOf": [{"type": "null"}, {"type": "object", "additionalProperties": false,
    "required": ["text", "kind", "reason"], "properties": {
      "text": {"type": "string"}, "kind": {"type": "string", "enum": ["fix", "natural"]},
      "reason": {"type": "string"}}}]}}}
"""#
    // SCHEMA-END

    public static func userMessage(sentence: String, before: String?, after: String?) -> String {
        "BEFORE: \(before ?? "")\nSENTENCE: \(sentence)\nAFTER: \(after ?? "")"
    }

    /// The OpenRouter chat-completions body (DESIGN.md → OpenRouter call).
    public static func body(sentence: String, before: String?, after: String?, models: [String]) -> Data {
        let schema = (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) ?? [:]
        let object: [String: Any] = [
            "models": models,
            "provider": ["sort": "latency"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(sentence: sentence, before: before, after: after)],
            ],
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": "sentence_check", "strict": true, "schema": schema]],
            "max_tokens": 300,
            "temperature": 0,
            "reasoning": ["enabled": false],  // thinking tokens would eat max_tokens
            "usage": ["include": true],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Reads an OpenRouter response. A bad edit or a bad rewrite is skipped; anything unreadable throws `.malformed`.
    public static func parse(_ data: Data) throws -> LLMResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let answer = (try? JSONSerialization.jsonObject(with: Data(stripFence(content).utf8))) as? [String: Any]
        else { throw TierTwoError.malformed }
        let edits = (answer["edits"] as? [[String: Any]] ?? []).compactMap { item -> LLMEdit? in
            guard let original = item["original"] as? String, let replacement = item["replacement"] as? String,
                  !original.isEmpty, original != replacement else { return nil }
            let category = (item["category"] as? String).flatMap(SuggestionCategory.init(rawValue:)) ?? .grammar
            return LLMEdit(original: original, replacement: replacement, category: category,
                           reason: item["reason"] as? String ?? "")
        }
        var rewrite: LLMRewrite?
        if let item = answer["rewrite"] as? [String: Any], let text = item["text"] as? String, !text.isEmpty,
           let kind = (item["kind"] as? String).flatMap(RewriteKind.init(rawValue:)) {
            rewrite = LLMRewrite(text: text, kind: kind, reason: item["reason"] as? String ?? "")
        }
        let usage = root["usage"] as? [String: Any]
        return LLMResponse(result: LLMResult(edits: edits, rewrite: rewrite),
                           cost: (usage?["cost"] as? NSNumber)?.doubleValue ?? 0, model: root["model"] as? String)
    }

    static func stripFence(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        text = String(text.drop { $0 != "\n" })
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        return text
    }
}

/// Word edits plus the sentence-wide rewrite, as suggestions for this sentence.
public func suggestions(from result: LLMResult, in sentence: Sentence) -> [Suggestion] {
    var found = suggestions(from: result.edits, in: sentence)
    if let rewrite = result.rewrite,
       rewrite.text.trimmingCharacters(in: .whitespacesAndNewlines) != sentence.text.trimmingCharacters(in: .whitespacesAndNewlines) {
        found.append(Suggestion(sentenceHash: sentence.hash, range: NSRange(location: 0, length: (sentence.text as NSString).length),
                                original: sentence.text, category: rewrite.kind == .fix ? .grammar : .clarity,
                                message: rewrite.reason, replacements: [rewrite.text], source: .llm,
                                ruleId: "llm.rewrite.\(rewrite.kind.rawValue)", rewrite: rewrite.kind))
    }
    return found
}

/// Is the sentence finished enough to send to the model (decision 0010)?
/// `sentence.range` and `caret` are in the same (whole-field) coordinates. `caret` nil means no caret in the field.
public func isReadyForTierTwo(_ sentence: Sentence, caret: Int?) -> Bool {
    guard let caret else { return true }
    let start = sentence.range.location
    let end = NSMaxRange(sentence.range)
    let closers = CharacterSet(charactersIn: "\"'”’)]»")
    let trimmed = sentence.text.unicodeScalars.reversed().drop { closers.contains($0) }
    let finished = trimmed.first.map { ".?!…".unicodeScalars.contains($0) } ?? false
    return finished ? !(caret > start && caret < end) : (caret < start || caret > end)
}
