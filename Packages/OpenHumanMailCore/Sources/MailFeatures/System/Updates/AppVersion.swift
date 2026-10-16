import Foundation

public struct AppVersion: Sendable, Hashable, CustomStringConvertible {
    public let numbers: [Int]
    public let preRelease: [String]
    public let build: Int?

    public init?(_ text: String, build buildText: String? = nil) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        var metadata: Substring?
        if let plus = rest.firstIndex(of: "+") {
            metadata = rest[rest.index(after: plus)...]
            rest = rest[..<plus]
        }
        var pre: Substring?
        if let dash = rest.firstIndex(of: "-") {
            pre = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Self.number(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        var identifiers: [String] = []
        if let pre {
            guard let parsed = Self.identifiers(pre) else { return nil }
            identifiers = parsed
        }
        var build: Int?
        if let metadata {
            guard Self.identifiers(metadata) != nil else { return nil }
            build = Self.number(metadata)
        }
        if let buildText, let number = Self.number(Substring(buildText.trimmingCharacters(in: .whitespacesAndNewlines))) {
            build = number
        }
        self.numbers = numbers
        self.preRelease = identifiers
        self.build = build
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: "."))
    }

    public var displayName: String { description + (build.map { " (\($0))" } ?? "") }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public func isNewer(than other: AppVersion) -> Bool { Self.order(self, other) == .orderedDescending }

    // Why: semantic-version order, then the build number when both sides carry one, so a rebuilt release still counts
    public static func order(_ a: AppVersion, _ b: AppVersion) -> ComparisonResult {
        for (x, y) in zip(a.numbers, b.numbers) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        switch (a.preRelease.isEmpty, b.preRelease.isEmpty) {
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false):
            let result = order(a.preRelease, b.preRelease)
            if result != .orderedSame { return result }
        case (true, true): break
        }
        if let x = a.build, let y = b.build, x != y { return x < y ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    static func order(_ a: [String], _ b: [String]) -> ComparisonResult {
        for (x, y) in zip(a, b) where x != y {
            switch (number(Substring(x)), number(Substring(y))) {
            case let (m?, n?): if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return x < y ? .orderedAscending : .orderedDescending
            }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }

    static func number(_ text: Substring) -> Int? {
        guard (1...9).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    static func identifiers(_ text: Substring) -> [String]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
        else { return nil }
        return parts.map(String.init)
    }
}
