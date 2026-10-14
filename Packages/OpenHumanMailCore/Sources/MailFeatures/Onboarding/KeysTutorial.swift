import Foundation
import Observation

@MainActor @Observable
public final class KeysTutorial {
    public struct Prompt: Identifiable, Hashable, Sendable {
        public let id: String
        public let text: String
        public let key: String
    }

    public static let prompts = [
        Prompt(id: "down", text: "Press J to move down", key: "j"),
        Prompt(id: "done", text: "Press E to mark done", key: "e"),
        Prompt(id: "undo", text: "Press Z to undo", key: "z"),
        Prompt(id: "split", text: "Press Tab for the next split", key: "tab"),
        Prompt(id: "palette", text: "Press ⌘K for everything else", key: "cmd-k"),
        Prompt(id: "search", text: "Press / to search", key: "/"),
    ]

    public static let layoutNote = "Try Mail's Superhuman-style keys on this practice list; it isn't your mail."

    public static let sampleRows = ["Welcome to Mail", "Lunch on Thursday?", "Quarterly numbers", "Your receipt"]
    public static let sampleSplits = ["Important", "Other"]

    public private(set) var completed: Set<String> = []
    public private(set) var rows = KeysTutorial.sampleRows
    public private(set) var cursor = 0
    public private(set) var split = 0
    @ObservationIgnored private var lastDone: (row: String, index: Int)?

    public init() {}

    public var current: Prompt? { Self.prompts.first { !completed.contains($0.id) } }
    public var isFinished: Bool { completed.count == Self.prompts.count }

    public func press(_ key: String) {
        switch key {
        case "j":
            cursor = min(cursor + 1, max(rows.count - 1, 0))
        case "e":
            if current?.key == "e", !rows.isEmpty {
                let index = min(cursor, rows.count - 1)
                lastDone = (rows.remove(at: index), index)
                cursor = min(cursor, max(rows.count - 1, 0))
            }
        case "z":
            if let done = lastDone {
                let index = min(done.index, rows.count)
                rows.insert(done.row, at: index)
                cursor = index
                lastDone = nil
            }
        case "tab":
            split = (split + 1) % Self.sampleSplits.count
        default:
            break
        }
        if let current, current.key == key { completed.insert(current.id) }
    }

    public func reset() {
        completed = []
        rows = Self.sampleRows
        cursor = 0
        split = 0
        lastDone = nil
    }
}
