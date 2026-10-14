import Foundation
import OpenHumanCore

extension ThreadCursor {
    public var encoded: String {
        var text = "\(sortAt):\(tid)"
        for account in (perAccount ?? [:]).keys.sorted() {
            if let position = perAccount?[account] { text += ":\(account.rawValue)=\(position.sortAt).\(position.tid)" }
        }
        return Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(encoded: String) {
        guard !encoded.isEmpty, encoded.utf8.allSatisfy({ Self.base64URLAlphabet.contains($0) }) else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let sortAt = Int64(parts[0]), let tid = Int64(parts[1]) else { return nil }
        var perAccount: [AccountID: ThreadCursorPosition]?
        if parts.count > 2 {
            var positions: [AccountID: ThreadCursorPosition] = [:]
            for part in parts.dropFirst(2) {
                let halves = part.split(separator: "=", omittingEmptySubsequences: false)
                guard halves.count == 2, let account = Int64(halves[0]) else { return nil }
                let numbers = halves[1].split(separator: ".", omittingEmptySubsequences: false)
                guard numbers.count == 2, let s = Int64(numbers[0]), let t = Int64(numbers[1]) else { return nil }
                guard positions.updateValue(ThreadCursorPosition(sortAt: s, tid: t), forKey: AccountID(account)) == nil else { return nil }
            }
            perAccount = positions
        }
        let candidate = ThreadCursor(sortAt: sortAt, tid: tid, perAccount: perAccount)
        guard candidate.encoded == encoded else { return nil }
        self = candidate
    }

    private static let base64URLAlphabet: Set<UInt8> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
}
