import Foundation
import MailModel
import OpenHumanCore
import Synchronization

public final class FakeAIOnboarding: AIOnboardingPort, Sendable {
    private struct State {
        var status: OnDeviceAIStatus
        var choice: DraftRepliesChoice
        var summary: String?
        var summaryFails = false
        var agentCLIAuto = false
        var log: [String] = []
    }
    private let state: Mutex<State>

    public init(status: OnDeviceAIStatus = .available, choice: DraftRepliesChoice = .onDemand,
                summary: String? = "A short summary written on this Mac.") {
        state = Mutex(State(status: status, choice: choice, summary: summary))
    }

    public var log: [String] { state.withLock { $0.log } }
    public func setStatus(_ status: OnDeviceAIStatus) { state.withLock { $0.status = status } }
    public func failSummaries() { state.withLock { $0.summaryFails = true } }
    public func forceAgentCLIAuto(_ on: Bool) { state.withLock { $0.agentCLIAuto = on } }

    public func onDeviceStatus() async -> OnDeviceAIStatus {
        state.withLock { s in
            s.log.append("status")
            return s.status
        }
    }

    public func draftReplies() async -> DraftRepliesChoice { state.withLock { $0.choice } }

    public func setDraftReplies(_ choice: DraftRepliesChoice) async throws {
        state.withLock { s in
            s.log.append("setDraftReplies:\(choice.rawValue)")
            s.choice = choice
        }
    }

    public func agentCLIAutoQuickReplies() async -> Bool { state.withLock { $0.agentCLIAuto } }

    public func summarizeOnDevice(_ thread: ThreadKey) async throws -> String? {
        try state.withLock { s in
            s.log.append("summarize")
            if s.summaryFails { throw MailPortError.unsupported("summary") }
            return s.summary
        }
    }
}

public final class FakeAIConnections: AIConnectionsPort, Sendable {
    private struct State {
        var items: [String: AIConnection] = [:]
        var order: [String] = []
        var next = 1
        var providerContacts: [String] = []
        var log: [String] = []
    }
    private let state = Mutex(State())

    public init(_ initial: [AIConnection] = []) {
        state.withLock { s in
            for item in initial {
                s.items[item.id] = item
                s.order.append(item.id)
            }
        }
    }

    public var providerContacts: [String] { state.withLock { $0.providerContacts } }
    public var log: [String] { state.withLock { $0.log } }

    public func connections() async -> [AIConnection] { state.withLock { s in s.order.compactMap { s.items[$0] } } }

    public func save(_ draft: AIConnectionDraft, hasKey: Bool) async throws -> AIConnection {
        state.withLock { s in
            s.log.append("save")
            let id = draft.id ?? "conn.\(s.next)"
            if draft.id == nil { s.next += 1; s.order.append(id) }
            let previous = s.items[id]
            let item = AIConnection(id: id, title: draft.title, kind: draft.kind, binaryPath: draft.binaryPath,
                                    hasKey: hasKey, isInUse: previous?.isInUse ?? false,
                                    consentGrantedAt: previous?.consentGrantedAt)
            s.items[id] = item
            return item
        }
    }

    public func remove(_ id: String) async throws {
        state.withLock { s in
            s.log.append("remove")
            s.items[id] = nil
            s.order.removeAll { $0 == id }
        }
    }

    public func setInUse(_ id: String, inUse: Bool, consentGrantedAt: Date?) async throws {
        try state.withLock { s in
            s.log.append(inUse ? "use" : "stop")
            guard var item = s.items[id] else { throw MailPortError.notFound("connection") }
            if inUse {
                guard let consentGrantedAt else { throw MailPortError.conflict("consent is required") }
                item.consentGrantedAt = consentGrantedAt
            }
            item.isInUse = inUse
            s.items[id] = item
        }
    }
}

public final class InMemorySecretStore: SecretStoring, Sendable {
    private let values = Mutex<[String: String]>([:])
    public init() {}

    public func setSecret(_ value: String, for name: String) throws { values.withLock { $0[name] = value } }
    public func hasSecret(for name: String) -> Bool { values.withLock { $0[name] != nil } }
    public func removeSecret(for name: String) throws { values.withLock { $0[name] = nil } }
    public func value(for name: String) -> String? { values.withLock { $0[name] } }
    public var names: [String] { values.withLock { Array($0.keys).sorted() } }
}
