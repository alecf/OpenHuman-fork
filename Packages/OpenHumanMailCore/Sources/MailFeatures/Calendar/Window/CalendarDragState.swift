import Foundation

public struct CalendarDragState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case move
        case resize
    }

    public struct Proposal: Equatable, Sendable {
        public var dayDelta: Int
        public var quarterDelta: Int
        public init(dayDelta: Int, quarterDelta: Int) {
            self.dayDelta = dayDelta
            self.quarterDelta = quarterDelta
        }
    }

    public private(set) var kind: Kind
    public private(set) var translation: CGSize = .zero
    public private(set) var isActive = true
    public private(set) var updates = 0

    public init(kind: Kind) { self.kind = kind }

    public mutating func update(translation: CGSize) {
        guard isActive else { return }
        self.translation = translation
        updates += 1
    }

    public mutating func end(translation: CGSize, hourHeight: CGFloat, columnWidth: CGFloat) -> Proposal? {
        guard isActive else { return nil }
        isActive = false
        self.translation = translation
        let proposal = Self.proposal(translation: translation, kind: kind, hourHeight: hourHeight, columnWidth: columnWidth)
        return proposal.dayDelta == 0 && proposal.quarterDelta == 0 ? nil : proposal
    }

    public mutating func cancel() { isActive = false }

    public static func snapped(_ dy: CGFloat, hourHeight: CGFloat) -> CGFloat {
        let quarter = hourHeight / 4
        return (dy / quarter).rounded() * quarter
    }

    public static func quarters(_ dy: CGFloat, hourHeight: CGFloat) -> Int {
        Int((dy / (hourHeight / 4)).rounded())
    }

    public static func proposal(translation: CGSize, kind: Kind, hourHeight: CGFloat, columnWidth: CGFloat) -> Proposal {
        let days = columnWidth > 0 ? Int((translation.width / columnWidth).rounded()) : 0
        return Proposal(dayDelta: kind == .move ? days : 0, quarterDelta: quarters(translation.height, hourHeight: hourHeight))
    }
}
