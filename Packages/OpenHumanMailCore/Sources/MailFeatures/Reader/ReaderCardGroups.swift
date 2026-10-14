import Foundation
import MailModel

public enum CardSegment: Sendable, Equatable {
    case single
    case first, middle, last

    public var roundsTop: Bool { self == .single || self == .first }
    public var roundsBottom: Bool { self == .single || self == .last }
    public var joinsAbove: Bool { self == .middle || self == .last }
    public var joinsBelow: Bool { self == .first || self == .middle }
}

@MainActor
public enum ReaderCardGroups {
    public static func segments(_ items: [ReaderModel.Item], isGroupable: (MessageKey) -> Bool) -> [CardSegment] {
        var segments = Array(repeating: CardSegment.single, count: items.count)
        var start: Int?
        func close(_ end: Int) {
            defer { start = nil }
            guard let first = start, end - first >= 2 else { return }
            segments[first] = .first
            for index in (first + 1)..<(end - 1) { segments[index] = .middle }
            segments[end - 1] = .last
        }
        for (index, item) in items.enumerated() {
            let groupable = switch item {
            case .message(let key): isGroupable(key)
            case .olderMessages: true
            }
            if groupable {
                if start == nil { start = index }
            } else {
                close(index)
            }
        }
        close(items.count)
        return segments
    }
}
