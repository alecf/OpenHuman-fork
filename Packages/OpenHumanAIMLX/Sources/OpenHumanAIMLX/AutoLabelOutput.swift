import Foundation
import OpenHumanAI

public enum AutoLabelOutput {
    public static let allowedWords: Set<String> = Set(AutoLabelCategory.modelCategories.map(\.rawValue) + ["other"])

    public static func parse(_ text: String) throws -> AutoLabelCategory? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("<think>") {
            guard let close = body.range(of: "</think>") else { throw invalid("unclosed think block") }
            let inside = body[body.index(body.startIndex, offsetBy: 7)..<close.lowerBound]
            guard inside.allSatisfy(\.isWhitespace) else { throw invalid("the model reasoned instead of answering") }
            body = String(body[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if body.hasPrefix("```") {
            guard body.hasSuffix("```"), body.count >= 6 else { throw invalid("unclosed code fence") }
            var inner = body.dropFirst(3).dropLast(3)
            if inner.hasPrefix("json") { inner = inner.dropFirst(4) }
            body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{"), body.hasSuffix("}") else { throw invalid("not a JSON object") }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { throw invalid("not valid JSON") }
        guard object.count == 1, let word = object["category"] as? String else {
            throw invalid("expected exactly one key, category")
        }
        guard allowedWords.contains(word) else { throw invalid("unknown category") }
        if word == "other" { return nil }
        guard let category = AutoLabelCategory(rawValue: word) else { throw invalid("unknown category") }
        return category
    }

    private static func invalid(_ why: String) -> AIError {
        .invalidOutput("The classifier answer was not usable (\(why)).")
    }
}
