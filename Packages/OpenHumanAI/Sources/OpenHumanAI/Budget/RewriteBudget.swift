import Foundation

extension AIPolicy {
    public static let rewriteFixedHeadroomTokens = 600
    public static let generationMinimumOutputTokens = 32
    public static let generationUnknownContextOutputTokens = 1_024

    public static func generationOutputBudget(contextTokens: Int?, inputTokens: Int) -> Int {
        guard let contextTokens, contextTokens > 0 else { return generationUnknownContextOutputTokens }
        let room = contextTokens - ContextBudgeter.safetyMargin(contextTokens: contextTokens)
            - rewriteFixedHeadroomTokens - max(0, inputTokens)
        return max(generationMinimumOutputTokens, room)
    }
}

public enum AnswerTrim {
    public static func toLastCompleteSentence(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix("\u{2026}") || body.hasSuffix("...") {
            body = String(body.dropLast(body.hasSuffix("...") ? 3 : 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let closers: Set<Character> = ["\"", "'", ")", "\u{201D}", "\u{2019}"]
        let terminators: Set<Character> = [".", "!", "?"]
        let chars = Array(body)
        var lastEnd: Int?
        for index in chars.indices where terminators.contains(chars[index]) {
            var end = index
            while end + 1 < chars.count, closers.contains(chars[end + 1]) { end += 1 }
            if end + 1 == chars.count || chars[end + 1].isWhitespace { lastEnd = end }
        }
        guard let lastEnd else { return text }
        return String(chars[0...lastEnd])
    }
}
