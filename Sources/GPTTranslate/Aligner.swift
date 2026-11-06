import Foundation

/// Word/phrase alignment between the source and its two translations, computed by a
/// second, cheap model call after the translation has finished streaming.
enum Aligner {
    static let systemPrompt = """
    You align a source text with its two translations, A and B, for a highlighter that shows which words correspond.
    Return {"pairs": [[s, a, b], ...]} where each triple holds fragments of SOURCE, A and B that mean the same thing.

    Rules
    - s, a and b must be exact substrings copied character for character from SOURCE, A and B. Never paraphrase or add ellipses.
    - Use the smallest units that still correspond: usually single words or short phrases. Keep idioms, set phrases and names together.
    - Cover every content word of SOURCE, in SOURCE order. Function words that have a clear counterpart may be their own triple or be attached to a neighbouring word.
    - Leave out surrounding spaces and punctuation.
    - Use "" for a side that has no counterpart.
    - If the same fragment occurs several times, give one triple per occurrence, in order.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "pairs": [
                "type": "array",
                "items": ["type": "array", "items": ["type": "string"]],
            ],
        ],
        "required": ["pairs"],
        "additionalProperties": false,
    ]

    static func align(key: String, source: String, a: String, b: String) async throws -> (pairs: [[String]], result: StreamResult) {
        let user = "<source>\n\(source)\n</source>\n<a>\n\(a)\n</a>\n<b>\n\(b)\n</b>"
        var (body, betas) = Models.requestBody(model: Models.aligner, system: systemPrompt, user: user, maxTokens: 12000)
        body["text"] = ["format": ["type": "json_schema", "name": "alignment", "schema": schema, "strict": true]]
        let result = try await APIClient.stream(key: key, body: body, betas: betas) { _ in }
        return (decode(result.text), result)
    }

    static func decode(_ text: String) -> [[String]] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let pairs = object["pairs"] as? [[String]] else { return [] }
        return pairs
    }

    /// Maps each triple to character ranges, taking the first unused occurrence of every fragment.
    static func resolve(_ pairs: [[String]], in texts: [String]) -> [[NSRange?]] {
        let strings = texts.map { $0 as NSString }
        var used = Array(repeating: [NSRange](), count: texts.count)
        return pairs.map { pair in
            (0..<texts.count).map { i -> NSRange? in
                guard i < pair.count else { return nil }
                let fragment = pair[i].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fragment.isEmpty else { return nil }
                let text = strings[i]
                for options: NSString.CompareOptions in [[], [.caseInsensitive]] {
                    var start = 0
                    while start < text.length {
                        let found = text.range(of: fragment, options: options,
                                               range: NSRange(location: start, length: text.length - start))
                        if found.location == NSNotFound { break }
                        if isWholeWord(found, in: text),
                           !used[i].contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                            used[i].append(found)
                            return found
                        }
                        start = found.location + 1
                    }
                }
                return nil
            }
        }
    }

    /// Rejects matches like "a" inside "hungry"; CJK text has no word boundaries to check.
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isWordChar(_ c: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(c) else { return false }
            if (0x2E80...0x9FFF).contains(c) || (0xAC00...0xD7AF).contains(c) || (0xF900...0xFAFF).contains(c) { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        let first = text.character(at: range.location)
        let last = text.character(at: NSMaxRange(range) - 1)
        if isWordChar(first), range.location > 0, isWordChar(text.character(at: range.location - 1)) { return false }
        if isWordChar(last), NSMaxRange(range) < text.length, isWordChar(text.character(at: NSMaxRange(range))) { return false }
        return true
    }
}
