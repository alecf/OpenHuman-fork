import Foundation
import OpenHumanAI

public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum SyntheticThreads {
    static let vocabulary = [
        "project", "budget", "meeting", "draft", "review", "schedule", "quarter", "invoice", "proposal", "update",
        "timeline", "agenda", "contract", "launch", "design", "feedback", "deadline", "team", "client", "report",
        "estimate", "approval", "question", "plan", "summary", "notes", "call", "office", "travel", "hiring",
        "the", "a", "we", "you", "will", "can", "should", "next", "week", "friday", "monday", "please", "thanks",
        "send", "share", "confirm", "move", "keep", "finish", "start", "before", "after", "with", "for", "about",
    ]
    static let names = ["Dana Lee", "Sam Ortiz", "Priya Rao", "Alex Kim", "Jordan Fox", "Mina Park"]

    public static func words(_ count: Int, sentences: Bool = true, using rng: inout SeededGenerator) -> String {
        var out: [String] = []
        var sinceStop = 0
        var stopAt = Int.random(in: 8...16, using: &rng)
        for index in 0..<count {
            var word = vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)]
            if sinceStop == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
            sinceStop += 1
            if sentences, sinceStop >= stopAt || index == count - 1 {
                word += "."
                sinceStop = 0
                stopAt = Int.random(in: 8...16, using: &rng)
            }
            out.append(word)
        }
        return out.joined(separator: " ")
    }

    public static func thread(
        messages: Int = 30, seed: UInt64 = 1, longEvery: Int = 7, threadKey: String = "thread-synthetic",
        accountKey: String? = nil, trigger: AITrigger = .user
    ) -> AIThreadInput {
        var rng = SeededGenerator(seed: seed)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var list: [AIMessageInput] = []
        for index in 0..<messages {
            let body: String
            if index == 10 {
                body = words(3_000, sentences: false, using: &rng)
            } else if longEvery > 0, index % longEvery == longEvery - 1 {
                body = (0..<Int.random(in: 20...30, using: &rng))
                    .map { _ in words(Int.random(in: 80...120, using: &rng), using: &rng) }
                    .joined(separator: "\n\n")
            } else {
                body = (0..<Int.random(in: 2...4, using: &rng))
                    .map { _ in words(Int.random(in: 15...40, using: &rng), using: &rng) }
                    .joined(separator: "\n\n")
            }
            list.append(
                AIMessageInput(
                    messageKey: "m\(index + 1)", from: names[index % names.count] + " <person\(index % names.count)@example.com>",
                    date: start.addingTimeInterval(Double(index) * 3_600), bodyText: body,
                    subject: "Project update", accountKey: accountKey))
        }
        return AIThreadInput(
            threadKey: threadKey, subject: "Project update", messages: list, accountKey: accountKey, trigger: trigger)
    }

    public static func short(threadKey: String = "thread-short", accountKey: String? = nil,
                             trigger: AITrigger = .user) -> AIThreadInput
    {
        thread(messages: 3, seed: 7, longEvery: 0, threadKey: threadKey, accountKey: accountKey, trigger: trigger)
    }
}
