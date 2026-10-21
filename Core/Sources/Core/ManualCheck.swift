import Foundation

/// The answer to an on-demand check (decision 0019).
public struct ManualResult: Equatable, Sendable {
    /// The text with its mistakes fixed; equal to the text when nothing was wrong.
    public let corrected: String
    /// Other ways to say it: at most 3, none equal to `corrected` or to each other.
    public let alternatives: [String]
    public let reason: String
    public let looksGood: Bool

    public init(corrected: String, alternatives: [String], reason: String, looksGood: Bool) {
        self.corrected = corrected
        self.alternatives = alternatives
        self.reason = reason
        self.looksGood = looksGood
    }
}

public struct ManualResponse: Equatable, Sendable {
    public let result: ManualResult
    /// USD, from `usage.cost`.
    public let cost: Double
}

/// "Check this" on a selection: its own prompt and schema, so tier 2's stay as evaluated (decision 0019).
public enum ManualCheck {
    public static let maxAlternatives = 3

    public static let systemPrompt = #"""
You are a careful English copy editor for a non-native writer. You get TEXT (one or more sentences the writer selected and asked you to check), plus the text BEFORE and AFTER it for context only.

corrected: TEXT with every grammar, spelling, punctuation and word-choice mistake fixed. Change nothing else. If TEXT has no mistakes, copy it exactly.
alternatives: 2 or 3 other ways a native speaker would say the corrected TEXT, also when TEXT has no mistakes. Same meaning, same tone, same names and facts; casual stays casual. Each one clearly different from corrected and from the others.
reason: plain English, at most 12 words: what was wrong, or "No mistakes".

If TEXT is not English, copy it to corrected and return no alternatives. Answer with JSON only.
"""#

    public static let schemaJSON = #"""
{"type": "object", "additionalProperties": false, "required": ["corrected", "alternatives", "reason"], "properties": {
  "corrected": {"type": "string"},
  "alternatives": {"type": "array", "items": {"type": "string"}},
  "reason": {"type": "string"}}}
"""#

    public static func userMessage(text: String, before: String?, after: String?) -> String {
        "BEFORE: \(before ?? "")\nTEXT: \(text)\nAFTER: \(after ?? "")"
    }

    public static func body(text: String, before: String?, after: String?, models: [String]) -> Data {
        let schema = (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) ?? [:]
        let object: [String: Any] = [
            "models": models,
            "provider": ["sort": "latency"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(text: text, before: before, after: after)],
            ],
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": "manual_check", "strict": true, "schema": schema]],
            // Four versions of a selection that can be a few sentences long.
            "max_tokens": 1200,
            "temperature": 0,
            "reasoning": ["enabled": false],
            "usage": ["include": true],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Reads the answer for `text`. Anything unreadable throws `.malformed`.
    public static func parse(_ data: Data, text: String) throws -> ManualResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let answer = (try? JSONSerialization.jsonObject(with: Data(TierTwoRequest.stripFence(content).utf8))) as? [String: Any],
              let rawCorrected = answer["corrected"] as? String
        else { throw TierTwoError.malformed }
        let original = trimmed(text)
        let corrected = trimmed(rawCorrected).isEmpty ? original : trimmed(rawCorrected)
        var seen: Set<String> = [corrected]
        let alternatives = (answer["alternatives"] as? [Any] ?? []).compactMap { $0 as? String }.map(trimmed).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        let usage = root["usage"] as? [String: Any]
        return ManualResponse(
            result: ManualResult(corrected: corrected, alternatives: Array(alternatives.prefix(maxAlternatives)),
                                 reason: answer["reason"] as? String ?? "", looksGood: corrected == original),
            cost: (usage?["cost"] as? NSNumber)?.doubleValue ?? 0)
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
