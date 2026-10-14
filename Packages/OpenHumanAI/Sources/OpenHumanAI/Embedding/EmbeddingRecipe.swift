import Foundation

// Why: any change here needs a new recipe id, so embeddings move to a new space and are rebuilt
public enum EmbeddingRecipe {
    public static let mailV1 = "mail.v1"
    public static let subjectCharacters = 300
    public static let senderCharacters = 100
    public static let bodyBytes = 32 * 1024
    public static let attachmentNames = 10

    public struct MessageText: Sendable, Hashable {
        public var subject: String
        public var senderName: String?
        public var body: String
        public var attachmentNames: [String]

        public init(subject: String, senderName: String?, body: String, attachmentNames: [String] = []) {
            self.subject = subject
            self.senderName = senderName
            self.body = body
            self.attachmentNames = attachmentNames
        }
    }

    public static func document(_ message: MessageText) -> String {
        var lines = ["Subject: " + String(oneLine(message.subject).prefix(subjectCharacters))]
        if let name = message.senderName.map(oneLine), !name.isEmpty {
            lines.append("From: " + String(name.prefix(senderCharacters)))
        }
        let body = utf8Prefix(message.body.trimmingCharacters(in: .whitespacesAndNewlines), maxBytes: bodyBytes)
        if !body.isEmpty { lines.append(body) }
        let names = message.attachmentNames.map(oneLine).filter { !$0.isEmpty }.prefix(attachmentNames)
        if !names.isEmpty { lines.append("Attachments: " + names.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    public static func query(_ freeTextTerms: [String]) -> String {
        freeTextTerms.map(oneLine).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func fit(_ text: String, prefix: String, maxTokens: Int?,
                           count: (String) async -> Int) async -> String {
        guard let maxTokens else { return text }
        if await count(prefix + text) <= maxTokens { return text }
        var ends: [String.Index] = []
        var index = text.startIndex
        var inWord = false
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            if inWord, isSpace { ends.append(index) }
            inWord = !isSpace
            index = text.index(after: index)
        }
        if inWord { ends.append(text.endIndex) }
        var low = 0
        var high = ends.count
        while low < high {
            let mid = (low + high + 1) / 2
            if await count(prefix + String(text[..<ends[mid - 1]])) <= maxTokens { low = mid } else { high = mid - 1 }
        }
        return low == 0 ? "" : String(text[..<ends[low - 1]])
    }

    static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > maxBytes { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

public enum EmbeddingProbe {
    public static let sentences: [String] = [
        "Can we move the team offsite to the second week of May?",
        "Your order of two desk lamps has shipped and arrives Thursday.",
        "Invoice 1042 for the March design work is attached.",
        "The quarterly numbers look better than we planned.",
        "Reminder: your dentist appointment is tomorrow at nine.",
        "Please review the indemnity clause before we sign.",
        "Flight itinerary: departing Monday morning, returning Friday.",
        "We had a short outage last night; the write-up follows.",
        "Thanks for interviewing with us, here are the next steps.",
        "The school trip permission form is due on Friday.",
        "Your password was changed from a new device.",
        "Lunch on Wednesday? The new place near the station.",
        "The lease renewal offers a two-year term at the same rent.",
        "Draft agenda for the product launch review.",
        "Your expense report was approved and will be paid next week.",
        "The conference accepted your talk about search.",
    ]

    public static let sameSpaceCosine: Float = 0.999

    public static func matches(_ stored: [[Float]], _ fresh: [[Float]]) -> Bool {
        guard stored.count == fresh.count, !stored.isEmpty else { return false }
        for (a, b) in zip(stored, fresh) {
            guard a.count == b.count, EmbeddingMath.dot(a, b) >= sameSpaceCosine else { return false }
        }
        return true
    }

    public static func digest(_ vectors: [[Float]]) -> String {
        let text = vectors.map { vector in vector.map { String(Int(($0 * 1000).rounded())) }.joined(separator: ",") }
        return String(Digest.sha256Hex(text).prefix(12))
    }
}
