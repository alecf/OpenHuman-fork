import Foundation

struct FoldedText {
    let scalars: [Unicode.Scalar]
    let origin: [Int]

    init(_ source: [Unicode.Scalar]) {
        var scalars: [Unicode.Scalar] = []
        var origin: [Int] = []
        scalars.reserveCapacity(source.count)
        origin.reserveCapacity(source.count)
        for (index, scalar) in source.enumerated() {
            if scalar.isASCII {
                let value = scalar.value
                let lowered = (65...90).contains(value) ? Unicode.Scalar(UInt8(value + 32)) : scalar
                scalars.append(lowered)
                origin.append(index)
                continue
            }
            if FoldedText.isDropped(scalar) { continue }
            let folded = String(scalar).decomposedStringWithCompatibilityMapping.lowercased()
            for piece in folded.unicodeScalars where !FoldedText.isDropped(piece) {
                scalars.append(piece)
                origin.append(index)
            }
        }
        self.scalars = scalars
        self.origin = origin
    }

    init(_ text: String) { self.init(Array(text.unicodeScalars)) }

    static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isDefaultIgnorableCodePoint { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return true
        default: return false
        }
    }

    static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: FoldedText(text).scalars)
        return String(out)
    }

    func occurrences(of needle: [Unicode.Scalar]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= scalars.count else { return [] }
        var result: [Range<Int>] = []
        var index = 0
        let last = scalars.count - needle.count
        while index <= last {
            if scalars[index] == needle[0], scalars[index..<(index + needle.count)].elementsEqual(needle) {
                result.append(index..<(index + needle.count))
                index += needle.count
            } else {
                index += 1
            }
        }
        return result
    }
}
