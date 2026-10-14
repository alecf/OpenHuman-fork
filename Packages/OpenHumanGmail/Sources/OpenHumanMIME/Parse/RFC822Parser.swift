import Foundation
import OpenHumanCore

enum RFC822 {
    static let maxInputBytes = 64 * 1024 * 1024
    static let maxDepth = 24
    static let maxParts = 2000
    static let maxHeaders = 1000
    static let maxHeaderValueBytes = 64 * 1024

    struct State {
        var parts = 0
        var warnings: [String] = []
        mutating func warn(_ w: String) { if !warnings.contains(w), warnings.count < 50 { warnings.append(w) } }
    }

    static func parseHeaders(_ b: [UInt8], _ start: Int, _ end: Int, _ state: inout State)
        -> (fields: [MIMEHeaderField], bodyStart: Int)
    {
        var fields: [MIMEHeaderField] = []
        var pos = start
        var currentName: String?
        var currentValue = [UInt8]()
        func flush() {
            if let name = currentName {
                fields.append(MIMEHeaderField(name: name, value: string(currentValue).trimmingCharacters(in: .whitespaces)))
            }
            currentName = nil
            currentValue = []
        }
        while pos < end {
            var eol = pos
            while eol < end, b[eol] != 0x0A { eol += 1 }
            var lineEnd = eol
            if lineEnd > pos, b[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let next = min(end, eol + 1)
            if lineEnd == pos {
                flush()
                return (fields, next)
            }
            if b[pos] == 0x20 || b[pos] == 0x09 {
                if currentName != nil, currentValue.count < maxHeaderValueBytes {
                    currentValue.append(contentsOf: b[pos..<lineEnd])
                }
            } else {
                flush()
                if fields.count >= maxHeaders {
                    state.warn("too many headers; rest ignored")
                    pos = next
                    while pos < end {
                        var e = pos
                        while e < end, b[e] != 0x0A { e += 1 }
                        let blank = e == pos || (e == pos + 1 && b[pos] == 0x0D)
                        pos = min(end, e + 1)
                        if blank { return (fields, pos) }
                    }
                    return (fields, end)
                }
                if let colon = b[pos..<lineEnd].firstIndex(of: UInt8(ascii: ":")), colon > pos,
                   !b[pos..<colon].contains(where: { $0 <= 0x20 || $0 == 0x7F }) {
                    currentName = String(decoding: b[pos..<colon], as: UTF8.self)
                    currentValue = Array(b[(colon + 1)..<lineEnd].prefix(maxHeaderValueBytes))
                } else {
                    state.warn("malformed header line skipped")
                }
            }
            pos = next
        }
        flush()
        return (fields, end)
    }

    static func string(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    static func value(_ fields: [MIMEHeaderField], _ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func buildPart(_ b: [UInt8], _ start: Int, _ end: Int, depth: Int, partID: String,
                          state: inout State) -> GmailPayloadPart {
        state.parts += 1
        let (fields, bodyStart) = parseHeaders(b, start, end, &state)
        let ctValue = value(fields, "Content-Type") ?? "text/plain; charset=us-ascii"
        let ct = ContentType.parse(ctValue)
        let type = ct.type.contains("/") ? ct.type : "text/plain"
        let cte = value(fields, "Content-Transfer-Encoding")

        var filename: String?
        if let disposition = value(fields, "Content-Disposition") {
            filename = ContentType.parse(disposition).params["filename"]
        }
        if filename == nil { filename = ct.params["name"] }
        filename = filename.map { HeaderDecoder.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if filename?.isEmpty == true { filename = nil }

        func leaf(_ mime: String, decodeTransfer: Bool) -> GmailPayloadPart {
            let decoded = decodeTransfer ? TransferEncoding.decode(b[bodyStart..<max(bodyStart, end)], encoding: cte)
                                         : Data(b[bodyStart..<max(bodyStart, end)])
            return GmailPayloadPart(partID: partID, mimeType: mime, filename: filename, headers: fields, size: decoded.count,
                                    data: Base64URL.encode(decoded), parts: [])
        }

        if type.hasPrefix("multipart/") {
            if depth >= maxDepth {
                state.warn("multipart nesting too deep; treated as opaque")
                return leaf("application/octet-stream", decodeTransfer: false)
            }
            guard let boundary = ct.params["boundary"], !boundary.isEmpty, boundary.utf8.count <= 200 else {
                state.warn("multipart without boundary")
                return leaf("text/plain", decodeTransfer: true)
            }
            let ranges = splitMultipart(b, bodyStart, end, boundary: Array(boundary.utf8), state: &state)
            if ranges.isEmpty {
                state.warn("multipart without parts")
                return leaf("text/plain", decodeTransfer: true)
            }
            var children: [GmailPayloadPart] = []
            for (i, r) in ranges.enumerated() {
                if state.parts >= maxParts { state.warn("too many parts; rest ignored"); break }
                let id = partID.isEmpty ? "\(i)" : "\(partID).\(i)"
                children.append(buildPart(b, r.lowerBound, r.upperBound, depth: depth + 1, partID: id, state: &state))
            }
            return GmailPayloadPart(partID: partID, mimeType: type, filename: nil, headers: fields, size: 0, data: nil,
                                    parts: children)
        }
        return leaf(type, decodeTransfer: true)
    }

    static func splitMultipart(_ b: [UInt8], _ start: Int, _ end: Int, boundary: [UInt8],
                               state: inout State) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var pos = start
        var partStart: Int?
        var closed = false
        let delimiter = [UInt8(ascii: "-"), UInt8(ascii: "-")] + boundary
        while pos < end {
            var eol = pos
            while eol < end, b[eol] != 0x0A { eol += 1 }
            var lineEnd = eol
            if lineEnd > pos, b[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd - pos >= delimiter.count, b[pos..<(pos + delimiter.count)].elementsEqual(delimiter) {
                var rest = pos + delimiter.count
                var isClose = false
                if rest + 1 < lineEnd, b[rest] == UInt8(ascii: "-"), b[rest + 1] == UInt8(ascii: "-") {
                    isClose = true
                    rest += 2
                }
                let tail = b[rest..<lineEnd]
                if tail.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let ps = partStart {
                        var pe = pos
                        if pe > ps, b[pe - 1] == 0x0A { pe -= 1 }
                        if pe > ps, b[pe - 1] == 0x0D { pe -= 1 }
                        ranges.append(ps..<max(ps, pe))
                    }
                    if isClose { closed = true; partStart = nil; break }
                    partStart = min(end, eol + 1)
                }
            }
            pos = min(end, eol + 1)
        }
        if !closed, let ps = partStart {
            state.warn("multipart not terminated")
            ranges.append(ps..<end)
        }
        return ranges
    }
}
