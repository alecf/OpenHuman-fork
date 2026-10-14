import Foundation
import MailModel
import OpenHumanCore

public enum EMLBuilder {
    public static let exportNote = "rebuilt from the local copy; attachments and routing headers are not included"

    public static func eml(subject: String, message: MessageSummary, content: MessageContent?) -> Data {
        var lines: [String] = []
        if let from = message.from { lines.append("From: " + address(from)) }
        if !message.to.isEmpty { lines.append("To: " + message.to.map(address).joined(separator: ", ")) }
        if !message.cc.isEmpty { lines.append("Cc: " + message.cc.map(address).joined(separator: ", ")) }
        lines.append("Date: " + dateHeader(message.date))
        lines.append("Subject: " + encodedWord(subject))
        lines.append("MIME-Version: 1.0")
        lines.append("X-OpenHuman-Export: " + exportNote + (message.attachments.isEmpty ? "" : " (\(message.attachments.count) attachment(s) omitted)"))

        let text = content?.text ?? (content?.html == nil ? message.snippet : nil)
        let html = content?.html
        switch (text, html) {
        case let (text?, html?):
            let boundary = "openhuman-" + String(message.id.rowID, radix: 16)
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--" + boundary)
            lines.append(contentsOf: part(type: "text/plain", body: text))
            lines.append("--" + boundary)
            lines.append(contentsOf: part(type: "text/html", body: html))
            lines.append("--" + boundary + "--")
        case let (text?, nil):
            lines.append(contentsOf: part(type: "text/plain", body: text))
        case let (nil, html?):
            lines.append(contentsOf: part(type: "text/html", body: html))
        case (nil, nil):
            lines.append(contentsOf: part(type: "text/plain", body: ""))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func part(type: String, body: String) -> [String] {
        ["Content-Type: \(type); charset=UTF-8", "Content-Transfer-Encoding: base64", ""] + base64Lines(Data(body.utf8))
    }

    static func base64Lines(_ data: Data) -> [String] {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines
    }

    static func address(_ value: EmailAddress) -> String {
        let email = clean(value.email)
        guard let name = value.name.map(clean), !name.isEmpty else { return email }
        let plain = name.unicodeScalars.allSatisfy { $0.isASCII && !"\"\\(),:;<>@[]".unicodeScalars.contains($0) }
        if plain { return "\(name) <\(email)>" }
        if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" <\(email)>"
        }
        return "\(encodedWord(name)) <\(email)>"
    }

    static func encodedWord(_ raw: String) -> String {
        let text = clean(raw)
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if (chunk + String(character)).utf8.count > 42 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    // Strip control characters so a header value can never start a new header
    static func clean(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })).trimmingCharacters(in: .whitespaces)
    }

    static func dateHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'ZZZZ'"
        return formatter.string(from: date).replacingOccurrences(of: "ZZZZ", with: "+0000")
    }
}
