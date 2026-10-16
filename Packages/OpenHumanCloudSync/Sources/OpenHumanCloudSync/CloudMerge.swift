import Foundation

public enum CloudMergePolicy: Sendable {
    case lastWriterWins
    case perField
    // Must be commutative and idempotent, or devices stop converging
    case custom(@Sendable (_ local: CloudDocument, _ remote: CloudDocument) -> CloudDocument)
}

public struct CloudRecordType: Sendable {
    public let name: String
    public let policy: CloudMergePolicy

    public init(_ name: String, policy: CloudMergePolicy) {
        self.name = name
        self.policy = policy
    }

    public func merge(_ local: CloudDocument, _ remote: CloudDocument) -> CloudDocument {
        switch policy {
        case .lastWriterWins: return CloudMerge.lastWriterWins(local, remote)
        case .perField: return CloudMerge.perField(local, remote)
        case .custom(let merge): return merge(local, remote)
        }
    }

    var isValidName: Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= 255, Self.isLetter(first) else { return false }
        return bytes.allSatisfy { Self.isLetter($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

public enum CloudMerge {
    public static func lastWriterWins(_ a: CloudDocument, _ b: CloudDocument) -> CloudDocument {
        if a == b { return a }
        switch (a.version, b.version) {
        case (nil, _): return b
        case (_, nil): return a
        case let (left?, right?):
            if left != right { return left > right ? a : b }
            return precedes(encoded(a), encoded(b)) ? b : a
        }
    }

    public static func perField(_ a: CloudDocument, _ b: CloudDocument) -> CloudDocument {
        var fields = a.fields
        for (key, theirs) in b.fields {
            guard let ours = fields[key] else {
                fields[key] = theirs
                continue
            }
            if theirs.hlc > ours.hlc || (theirs.hlc == ours.hlc && precedes(encoded(ours.value), encoded(theirs.value))) {
                fields[key] = theirs
            }
        }
        let deletedAt = [a.deletedAt, b.deletedAt].compactMap { $0 }.max()
        return CloudDocument(fields: fields, deletedAt: deletedAt)
    }

    // Why: equal clocks with different content only happen after a bug or a replay; any fixed order keeps devices in step
    private static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? CloudCanonical.encode(value)) ?? Data()
    }

    private static func precedes(_ a: Data, _ b: Data) -> Bool {
        a.lexicographicallyPrecedes(b)
    }
}
