import Foundation
import OpenHumanAI
import OpenHumanSemanticIndex
import Synchronization

public final class FakeSemanticSource: SemanticCorpusSource {
    public struct Message: Sendable {
        public var meta: CorpusMessage
        public var subject: String
        public var fromName: String?
        public var snippet: String
        public var body: String?
        public var attachmentNames: [String]
    }

    private struct State {
        var epoch = "epoch-1"
        var messages: [Int64: Message] = [:]
        var nextMID: Int64 = 1
        var downloads: [Int64: CorpusBodyDownload] = [:]
        var documentReads = 0
    }
    private let state = Mutex(State())

    public init() {}

    @discardableResult
    public func add(account: Int64 = 1, thread: Int64? = nil, gmailID: String? = nil, subject: String, fromName: String? = nil,
                    snippet: String = "", body: String? = nil, date: Date, isDraft: Bool = false, inSpam: Bool = false,
                    attachmentNames: [String] = []) -> Int64 {
        state.withLock { s in
            let mid = s.nextMID
            s.nextMID += 1
            let meta = CorpusMessage(mid: mid, account: account, gmailID: gmailID ?? "g\(mid)", thread: thread ?? mid,
                                     internalDate: date, bodyState: body == nil ? 1 : 2, isDraft: isDraft, inSpam: inSpam)
            s.messages[mid] = Message(meta: meta, subject: subject, fromName: fromName, snippet: snippet, body: body,
                                      attachmentNames: attachmentNames)
            return mid
        }
    }

    public func storeBody(_ mid: Int64, _ body: String) {
        state.withLock { s in
            s.messages[mid]?.body = body
            s.messages[mid]?.meta.bodyState = 2
        }
    }

    public func failBody(_ mid: Int64) { state.withLock { $0.messages[mid]?.meta.bodyState = 3 } }
    public func delete(_ mid: Int64) { _ = state.withLock { $0.messages.removeValue(forKey: mid) } }
    public func reuseRowid(_ mid: Int64, gmailID: String) { state.withLock { $0.messages[mid]?.meta.gmailID = gmailID } }
    public func removeAccount(_ account: Int64) { state.withLock { $0.messages = $0.messages.filter { $0.value.meta.account != account } } }
    public func bumpEpoch(_ epoch: String) { state.withLock { $0.epoch = epoch } }
    public func setBodyDownload(_ status: CorpusBodyDownload, account: Int64 = 1) { state.withLock { $0.downloads[account] = status } }
    public var documentReads: Int { state.withLock { $0.documentReads } }

    public func storeEpoch() async throws -> String { state.withLock { $0.epoch } }

    public func accounts() async throws -> [Int64] {
        state.withLock { Array(Set($0.messages.values.map(\.meta.account))).sorted() }
    }

    public func messages(after mid: Int64, limit: Int) async throws -> [CorpusMessage] {
        state.withLock { s in Array(s.messages.values.map(\.meta).filter { $0.mid > mid }.sorted { $0.mid < $1.mid }.prefix(limit)) }
    }

    public func messages(_ mids: [Int64]) async throws -> [CorpusMessage] {
        state.withLock { s in mids.compactMap { s.messages[$0]?.meta } }
    }

    public func awaitingBodies(account: Int64) async throws -> Set<Int64> {
        state.withLock { s in Set(s.messages.values.filter { $0.meta.account == account && $0.meta.bodyState < 2 }.map(\.meta.mid)) }
    }

    public func documents(_ mids: [Int64]) async throws -> [CorpusDocument] {
        state.withLock { s in
            s.documentReads += 1
            return mids.compactMap { mid in
                guard let message = s.messages[mid] else { return nil }
                let stored = message.meta.bodyState == 2
                let text = EmbeddingRecipe.MessageText(subject: message.subject, senderName: message.fromName,
                                                       body: stored ? (message.body ?? "") : message.snippet,
                                                       attachmentNames: message.attachmentNames)
                return CorpusDocument(mid: mid, text: text, hasStoredBody: stored)
            }
        }
    }

    public func identities(_ mids: [Int64]) async throws -> [Int64: String] {
        state.withLock { s in
            var result: [Int64: String] = [:]
            for mid in mids { if let message = s.messages[mid] { result[mid] = message.meta.gmailID } }
            return result
        }
    }

    public func bodyDownload(account: Int64) async throws -> CorpusBodyDownload {
        state.withLock { $0.downloads[account] ?? .downloading }
    }

    public func eligibleCount(account: Int64) async throws -> Int {
        state.withLock { s in s.messages.values.filter { $0.meta.account == account && $0.meta.isEligible }.count }
    }
}
