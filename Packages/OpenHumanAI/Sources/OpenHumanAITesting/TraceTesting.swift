import Foundation
import OpenHumanAI
import Synchronization

public final class ManualAIClock: AIClock, Sendable {
    private let now = Mutex<Duration>(.zero)

    public init() {}

    public func elapsed() -> Duration { now.withLock { $0 } }

    public func advance(by duration: Duration) { now.withLock { $0 += duration } }
}

public actor RecordingTraceSink: AITraceSink {
    public private(set) var traces: [AITraceRecord] = []

    public init() {}

    public func record(_ trace: AITraceRecord) async { traces.append(trace) }

    public func amend(_ id: UUID, finalText: String?, steps: [AITraceStep]) async {
        guard let index = traces.lastIndex(where: { $0.id == id }) else { return }
        if let finalText { traces[index].finalText = finalText }
        traces[index].steps += steps
    }
}

public final class SequentialTraceIDs: Sendable {
    private let next = Mutex(0)

    public init() {}

    public func make() -> UUID {
        let value = next.withLock { count in
            count += 1
            return count
        }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

public final class ClockedProvider: AIProvider, Sendable {
    public enum Step: Sendable {
        case advance(Duration)
        case text(String)
        case fail(AIError)
    }

    public let id: AIProviderID
    public let displayName: String
    private let caps: AICapabilities
    private let model: String
    private let clock: ManualAIClock
    private let steps: [Step]
    private let usage: AIUsage?
    private let calls = Mutex(0)

    public init(id: AIProviderID = .fake, displayName: String = "Clocked model", capabilities: AICapabilities = .fake(),
                model: String = "clocked-1", clock: ManualAIClock, steps: [Step], usage: AIUsage? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.caps = capabilities
        self.model = model
        self.clock = clock
        self.steps = steps
        self.usage = usage
    }

    public var runCount: Int { calls.withLock { $0 } }

    public func capabilities() async -> AICapabilities { caps }
    public func availability() async -> AIAvailability { .available }
    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
    public func modelVersion() async -> String? { "clocked-1" }
    public func consentFingerprint() async -> String? { nil }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        calls.withLock { $0 += 1 }
        var events: [Step?] = steps.map { $0 }
        events.append(nil)
        let script = events
        let clock = self.clock
        let id = self.id
        let model = self.model
        let usage = self.usage
        let box = CursorBox()
        return AsyncThrowingStream(unfolding: {
            while true {
                let index = box.next()
                if index == -1 { return .started(providerID: id, model: model) }
                guard index < script.count else { return nil }
                guard let step = script[index] else { return .finished(usage: usage) }
                switch step {
                case .advance(let duration): clock.advance(by: duration)
                case .text(let text): return .textDelta(text)
                case .fail(let error): throw error
                }
            }
        })
    }
}

private final class CursorBox: Sendable {
    private let cursor = Mutex(-1)

    func next() -> Int {
        cursor.withLock { value in
            let current = value
            value += 1
            return current
        }
    }
}
