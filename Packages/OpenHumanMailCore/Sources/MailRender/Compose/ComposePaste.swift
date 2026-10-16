import Foundation
import SwiftSoup

public enum ComposePaste {
    public struct Report: Equatable, Sendable {
        public var removedParameters: Int
        public var droppedImages: Int
        public var droppedHidden: Int

        public init(removedParameters: Int = 0, droppedImages: Int = 0, droppedHidden: Int = 0) {
            self.removedParameters = removedParameters
            self.droppedImages = droppedImages
            self.droppedHidden = droppedHidden
        }

        public var isWorthTelling: Bool { droppedImages > 0 }

        public static func + (lhs: Report, rhs: Report) -> Report {
            Report(removedParameters: lhs.removedParameters + rhs.removedParameters,
                   droppedImages: lhs.droppedImages + rhs.droppedImages,
                   droppedHidden: lhs.droppedHidden + rhs.droppedHidden)
        }
    }

    public static func document(fromHTML html: String) -> (document: RichTextDocument, report: Report) {
        guard let parsed = try? SwiftSoup.parseBodyFragment(html), let body = parsed.body() else {
            return (RichTextDocument(), Report())
        }
        var importer = HTMLImporter(options: .paste)
        importer.blocks(of: body, depth: 0)
        importer.flush()
        let cleaned = clean(RichTextDocument(blocks: importer.output))
        let imported = Report(droppedImages: importer.tally.images, droppedHidden: importer.tally.hidden)
        return (cleaned.document, imported + cleaned.report)
    }

    public static func clean(_ document: RichTextDocument) -> (document: RichTextDocument, report: Report) {
        var report = Report()
        let blocks = clean(document.blocks, report: &report)
        return (RichTextDocument(blocks: blocks).normalized, report)
    }

    static func clean(_ blocks: [RichTextDocument.Block], report: inout Report) -> [RichTextDocument.Block] {
        var out: [RichTextDocument.Block] = []
        for block in blocks {
            switch block {
            case .paragraph(let inlines):
                let cleaned = clean(inlines, report: &report)
                if cleaned.isEmpty, !inlines.isEmpty { continue }
                out.append(.paragraph(cleaned))
            case .list(let ordered, let items, let start):
                var cleanedItems: [[RichTextDocument.Block]] = []
                for item in items { cleanedItems.append(clean(item, report: &report)) }
                out.append(.list(ordered: ordered, items: cleanedItems, start: start))
            case .quote(let inner):
                out.append(.quote(clean(inner, report: &report)))
            case .image:
                out.append(block)
            }
        }
        return out
    }

    static func clean(_ inlines: [RichTextDocument.Inline], report: inout Report) -> [RichTextDocument.Inline] {
        var out: [RichTextDocument.Inline] = []
        for inline in inlines {
            switch inline {
            case .text(let text, let marks):
                let visible = removingInvisible(text)
                if !visible.isEmpty { out.append(.text(visible, marks)) }
            case .link(let url, let inner):
                let content = clean(inner, report: &report)
                let cleaned = cleanedLink(url)
                report.removedParameters += cleaned.removedParameters
                if !content.isEmpty { out.append(.link(cleaned.url, content)) }
            case .lineBreak, .mention:
                out.append(inline)
            }
        }
        return RichTextDocument.normalize(out)
    }

    public static func plainText(_ text: String) -> String {
        removingInvisible(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    public static func linkURL(fromPastedText text: String) -> URL? {
        let trimmed = plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let url = URL(string: trimmed) else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return nil }
            return cleanedLink(url).url
        case "mailto":
            return components.path.contains("@") ? url : nil
        default:
            return nil
        }
    }

    public static func cleanedLink(_ url: URL) -> (url: URL, removedParameters: Int) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return (url, 0) }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return !isTrackingParameter(name.removingPercentEncoding ?? name)
        }
        guard kept.count < pairs.count else { return (url, 0) }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return (components.url ?? url, pairs.count - kept.count)
    }

    public static let trackingParameterPrefixes: [String] = ["utm_"]

    public static let trackingParameters: Set<String> = [
        "gclid", "gbraid", "wbraid", "gad_source", "dclid", "fbclid", "ttclid", "_kx", "mkt_tok",
    ]

    public static let unconfirmedTrackingParameters: Set<String> = [
        "msclkid", "_hsenc", "_hsmi", "mc_cid", "mc_eid", "gad_campaignid",
    ]
    public static let unconfirmedTrackingParameterPrefixes: [String] = ["hsa_"]

    public static func isTrackingParameter(_ name: String) -> Bool {
        trackingParameters.contains(name) || trackingParameterPrefixes.contains { name.hasPrefix($0) }
    }

    static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{034F}", "\u{00AD}"]

    static func removingInvisible(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { invisible.contains($0) }) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !invisible.contains(scalar) { out.append(scalar) }
        return String(out)
    }
}
