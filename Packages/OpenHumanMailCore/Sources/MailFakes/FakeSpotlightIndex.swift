import Foundation
import MailModel
import Synchronization

public final class FakeSpotlightIndex: SpotlightIndexing, Sendable {
    private struct State {
        var items: [String: SpotlightItem] = [:]
        var calls: [String] = []
        var batchSizes: [Int] = []
        var failure: Bool = false
    }
    private let state = Mutex(State())

    public init() {}

    public func index(_ items: [SpotlightItem]) async throws {
        try state.withLock { s in
            s.calls.append("index")
            if s.failure { throw FakeSpotlightError.failed }
            s.batchSizes.append(items.count)
            for item in items { s.items[item.identifier] = item }
        }
    }

    public func delete(identifiers: [String]) async throws {
        try state.withLock { s in
            s.calls.append("delete")
            if s.failure { throw FakeSpotlightError.failed }
            for id in identifiers { s.items[id] = nil }
        }
    }

    public func delete(domains: [String]) async throws {
        try state.withLock { s in
            s.calls.append("deleteDomains")
            if s.failure { throw FakeSpotlightError.failed }
            s.items = s.items.filter { !domains.contains($0.value.domain) }
        }
    }

    public func deleteAll() async throws {
        try state.withLock { s in
            s.calls.append("deleteAll")
            if s.failure { throw FakeSpotlightError.failed }
            s.items = [:]
        }
    }

    public var items: [String: SpotlightItem] { state.withLock { $0.items } }
    public var calls: [String] { state.withLock { $0.calls } }
    public var batchSizes: [Int] { state.withLock { $0.batchSizes } }
    public var failing: Bool {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
}

public enum FakeSpotlightError: Error { case failed }
