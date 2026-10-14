import Foundation
import OpenHumanAI

public enum RequestInspector {
    public struct Block: Sendable, Hashable {
        public let id: String
        public let kind: String
        public let date: String?
        public let text: String
    }

    public static func blocks(in rendered: String, nonce: String) -> [Block]? {
        let openPrefix = "<\(Untrusted.tagName) nonce=\"\(nonce)\" "
        let close = "\n" + Untrusted.closingTag(nonce: nonce)
        var blocks: [Block] = []
        var rest = rendered[...]
        while let open = rest.range(of: openPrefix) {
            guard let tagEnd = rest[open.upperBound...].range(of: ">\n") else { return nil }
            let attributes = String(rest[open.upperBound..<tagEnd.lowerBound])
            guard let end = rest[tagEnd.upperBound...].range(of: close) else { return nil }
            blocks.append(
                Block(
                    id: attribute("id", in: attributes) ?? "", kind: attribute("kind", in: attributes) ?? "",
                    date: attribute("date", in: attributes), text: String(rest[tagEnd.upperBound..<end.lowerBound])))
            rest = rest[end.upperBound...]
        }
        return blocks
    }

    public static func outsideBlocks(of rendered: String, nonce: String) -> String {
        let openPrefix = "<\(Untrusted.tagName) nonce=\"\(nonce)\" "
        let close = Untrusted.closingTag(nonce: nonce)
        var out = ""
        var rest = rendered[...]
        while let open = rest.range(of: openPrefix), let end = rest[open.upperBound...].range(of: close) {
            out += rest[..<open.lowerBound]
            rest = rest[end.upperBound...]
        }
        return out + rest
    }

    public static func leaks(in request: AIRequest, minimumLength: Int = 12) -> [String] {
        let outside = request.system + "\n" + outsideBlocks(of: request.renderedInput(), nonce: request.nonce)
        return request.untrusted.map(\.text).filter { text in
            let probe = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return probe.count >= minimumLength && outside.contains(probe)
        }
    }

    public static func problems(in request: AIRequest) -> [String] {
        var problems: [String] = []
        let rendered = request.renderedInput()
        guard let blocks = blocks(in: rendered, nonce: request.nonce) else { return ["unparsable blocks"] }
        if blocks.count != request.untrusted.count {
            problems.append("\(blocks.count) blocks for \(request.untrusted.count) parts")
        }
        for (block, part) in zip(blocks, request.untrusted) {
            if block.text != Untrusted.neutralize(part.text, nonce: request.nonce) { problems.append("text of \(part.id)") }
            if block.kind != part.kind.rawValue { problems.append("kind of \(part.id)") }
            if Untrusted.containsDelimiterLookalike(block.text) { problems.append("delimiter look-alike in \(part.id)") }
            if Untrusted.containsNonce(block.text, nonce: request.nonce) { problems.append("nonce in \(part.id)") }
        }
        if Untrusted.containsNonce(request.system, nonce: request.nonce) == false {
            problems.append("system prompt does not name the nonce")
        }
        problems += leaks(in: request).map { "leak: \($0.prefix(40))" }
        return problems
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let start = attributes.range(of: "\(name)=\"") else { return nil }
        guard let end = attributes[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(attributes[start.upperBound..<end])
    }
}
