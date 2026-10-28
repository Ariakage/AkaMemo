import Foundation

public enum SearchTextMode: Sendable, Equatable {
    /// 1–2 character queries use the unigram/bigram side index.
    case short
    /// 3+ character queries use the trigram index.
    case trigram
}

/// Query routing, short-token generation, and snippet extraction.
///
/// SQLite's `unicode61` tokenizer treats a run of Chinese characters as one
/// token, and the `trigram` tokenizer cannot match fewer than three
/// characters. The short index stores every CJK unigram and bigram so that
/// one- and two-character queries still hit.
public enum SearchText {
    public static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func mode(for query: String) -> SearchTextMode? {
        let terms = terms(query)
        guard !terms.isEmpty else {
            return nil
        }
        if terms.contains(where: { $0.count >= 3 }) {
            return .trigram
        }
        return .short
    }

    /// Trigram phrase expression. Terms shorter than three characters cannot
    /// be matched by the trigram index, so a mixed query matches its long
    /// terms only.
    public static func trigramMatchExpression(for query: String) -> String? {
        let longTerms = terms(query).filter { $0.count >= 3 }
        guard !longTerms.isEmpty else {
            return nil
        }
        return
            longTerms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }

    /// Short-token expression. Each 1–2 character term is already a token in
    /// the side index (unigram for one character, bigram for two).
    public static func shortMatchExpression(for query: String) -> String? {
        let tokens = terms(query)
            .map { $0.lowercased() }
            .filter { token in
                token.allSatisfy { $0.isLetter || $0.isNumber }
            }
        guard !tokens.isEmpty else {
            return nil
        }
        return
            tokens
            .map { "\"\($0)\"" }
            .joined(separator: " AND ")
    }

    /// Deduplicated unigrams and bigrams for the short-token FTS table.
    public static func shortTokens(for text: String) -> String {
        let characters = Array(text.lowercased())
        var tokens = Set<String>()
        for (index, character) in characters.enumerated() {
            let isCJK = character.unicodeScalars.contains(where: { Self.isCJK($0) })
            if isCJK {
                tokens.insert(String(character))
                if index > 0,
                    characters[index - 1].unicodeScalars.contains(where: { Self.isCJK($0) })
                {
                    tokens.insert(String(characters[index - 1]) + String(character))
                }
            } else if character.isLetter || character.isNumber {
                tokens.insert(String(character))
                if index > 0 {
                    let previous = characters[index - 1]
                    if previous.isLetter || previous.isNumber {
                        tokens.insert(String(previous) + String(character))
                    }
                }
            }
        }
        return tokens.sorted().joined(separator: " ")
    }

    /// Returns a short window around the first query term.
    public static func snippet(
        text: String,
        query: String,
        maxLength: Int = 64
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else {
            return trimmed
        }
        let match = terms(query)
            .lazy
            .compactMap {
                trimmed.range(
                    of: $0,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            }
            .first
        guard let match else {
            return String(trimmed.prefix(maxLength)) + "…"
        }
        let matchOffset = trimmed.distance(
            from: trimmed.startIndex,
            to: match.lowerBound
        )
        let startOffset = max(0, matchOffset - maxLength / 2)
        let start = trimmed.index(trimmed.startIndex, offsetBy: startOffset)
        let end =
            trimmed.index(start, offsetBy: maxLength, limitedBy: trimmed.endIndex)
            ?? trimmed.endIndex
        var result = String(trimmed[start..<end])
        if startOffset > 0 {
            result = "…" + result
        }
        if end < trimmed.endIndex {
            result += "…"
        }
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,  // Hiragana and Katakana
            0x3400...0x4DBF,  // CJK Extension A
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xAC00...0xD7AF,  // Hangul syllables
            0xF900...0xFAFF,  // CJK Compatibility Ideographs
            0x20000...0x2FA1F:  // CJK Extensions B–F
            return true
        default:
            return false
        }
    }
}
