import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME

public actor FakeGmail: GmailAPI {
    public nonisolated let accountEmail: String
    let clock: any OHClock
    let metrics: (any GmailMetricsSink)?

    struct StoredMessage {
        var id: String
        var threadID: String
        var labels: Set<String>
        var internalDate: Int64
        var historyID: UInt64
        var snippet: String
        var payload: GmailMessagePart
        var sizeEstimate: Int
        var attachments: [String: Data] = [:]
    }

    var messages: [String: StoredMessage] = [:]
    var labels: [String: GmailLabel] = [:]
    var drafts: [String: String] = [:]
    var history: [GmailHistoryRecord] = []
    var historyID: UInt64
    var oldestAvailableHistoryID: UInt64
    var idCounter: UInt64 = 0x18f0_0000_0000_0000
    var dateCounter: Int64
    var sendAs: [GmailSendAs]
    var deliveryLog: [FakeDelivery] = []

    var failures: [GmailMethod: [GmailError]] = [:]
    var latencies: [GmailMethod: Duration] = [:]
    var ambiguousAfterCommit: Set<GmailMethod> = []
    var hooks: [GmailMethod: [@Sendable (isolated FakeGmail) -> Void]] = [:]
    var calls: [GmailMethod] = []
    var units: [GmailMethod: Int] = [:]
    var inFlight = 0
    var peakInFlight = 0
    var batchModifyRejectsMissingIDs = false

    public static let systemLabelIDs = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "STARRED", "IMPORTANT", "UNREAD",
                                        "CHAT", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS",
                                        "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    public init(accountEmail: String = "me@example.com", clock: any OHClock = SystemClock(),
                metrics: (any GmailMetricsSink)? = nil, startHistoryID: UInt64 = 1000,
                startDate: Date = Date(timeIntervalSince1970: 1_780_000_000)) {
        self.accountEmail = accountEmail.lowercased()
        self.clock = clock
        self.metrics = metrics
        historyID = startHistoryID
        oldestAvailableHistoryID = 0
        dateCounter = Int64(startDate.timeIntervalSince1970 * 1000)
        sendAs = [GmailSendAs(sendAsEmail: accountEmail.lowercased(), displayName: "Test Account", isPrimary: true,
                              isDefault: true, verificationStatus: "accepted")]
        for id in Self.systemLabelIDs {
            labels[id] = GmailLabel(id: id, name: id, type: "system", messageListVisibility: "show",
                                    labelListVisibility: "labelShow")
        }
    }

    public func failNext(_ method: GmailMethod, with error: GmailError, count: Int = 1) {
        failures[method, default: []] += Array(repeating: error, count: count)
    }

    public func latency(_ method: GmailMethod, _ duration: Duration) { latencies[method] = duration }

    public func ambiguousFailureAfterCommit(_ method: GmailMethod) { ambiguousAfterCommit.insert(method) }

    public func afterNext(_ method: GmailMethod, _ action: @escaping @Sendable (isolated FakeGmail) -> Void) {
        hooks[method, default: []].append(action)
    }

    public func expireHistory(before id: HistoryID) {
        oldestAvailableHistoryID = max(oldestAvailableHistoryID, id.rawValue)
        history.removeAll { (UInt64($0.id) ?? 0) < id.rawValue }
    }

    public func expireAllHistory() {
        historyID += 1
        expireHistory(before: HistoryID(historyID))
    }

    public func setSendAs(_ identities: [GmailSendAs]) { sendAs = identities }

    public func setBatchModifyRejectsMissingIDs(_ on: Bool) { batchModifyRejectsMissingIDs = on }

    public var callLog: [GmailMethod] { calls }
    public func callCount(_ method: GmailMethod) -> Int { calls.filter { $0 == method }.count }
    public var unitsUsed: Int { units.values.reduce(0, +) }
    public func units(for method: GmailMethod) -> Int { units[method] ?? 0 }
    public var maxConcurrentCalls: Int { peakInFlight }
    public func resetAccounting() {
        calls = []
        units = [:]
        peakInFlight = 0
    }

    public var currentHistoryID: HistoryID { HistoryID(historyID) }

    func call<T>(_ method: GmailMethod, _ body: () throws -> T) async throws -> T {
        calls.append(method)
        units[method, default: 0] += QuotaCost.units(method)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        let started = clock.now
        if let delay = latencies[method] {
            do { try await clock.sleep(for: delay) } catch { throw GmailError.cancelled }
        }
        func record(_ status: Int?) {
            let ms = Int((clock.now.timeIntervalSince(started) * 1000).rounded())
            metrics?.record(GmailCallMetric(method: method.rawValue, units: QuotaCost.units(method), status: status,
                                            attempts: 1, durationMs: max(0, ms)))
        }
        if var queue = failures[method], !queue.isEmpty {
            let error = queue.removeFirst()
            failures[method] = queue
            record(Self.status(for: error))
            throw error
        }
        do {
            let result = try body()
            if var queue = hooks[method], !queue.isEmpty {
                let hook = queue.removeFirst()
                hooks[method] = queue
                hook(self)
            }
            if ambiguousAfterCommit.remove(method) != nil {
                record(nil)
                throw GmailError.transport(.timedOut)
            }
            record(200)
            return result
        } catch let error as GmailError {
            record(Self.status(for: error))
            throw error
        }
    }

    static func status(for error: GmailError) -> Int? {
        switch error {
        case .unauthorized, .reauthRequired: return 401
        case .forbidden, .dailyLimitExceeded: return 403
        case .notFound, .historyExpired: return 404
        case .rateLimited: return 429
        case .badRequest(let reason, _): return reason == "conflict" ? 409 : 400
        case .preconditionFailed: return 412
        case .payloadTooLarge: return 413
        case .server(let status, _): return status
        case .transport, .cancelled, .decoding, .quotaBudgetExhausted: return nil
        }
    }

    public func getProfile(priority: RequestPriority) async throws -> GmailProfile {
        try await call(.getProfile) {
            let threads = Set(messages.values.map(\.threadID)).count
            return GmailProfile(emailAddress: accountEmail, messagesTotal: messages.count, threadsTotal: threads,
                                historyId: String(historyID))
        }
    }

    public func listSendAs() async throws -> [GmailSendAs] {
        try await call(.listSendAs) { sendAs }
    }

    public func listLabels() async throws -> [GmailLabel] {
        try await call(.listLabels) {
            labels.values.sorted { ($0.type ?? "", $0.id) < ($1.type ?? "", $1.id) }.map { label in
                var l = label
                l.messagesTotal = nil; l.threadsTotal = nil
                return l
            }
        }
    }

    public func getLabel(id: String) async throws -> GmailLabel {
        try await call(.getLabel) {
            guard var label = labels[id] else { throw GmailError.notFound("labels/\(id)") }
            let withLabel = messages.values.filter { $0.labels.contains(id) }
            label.messagesTotal = withLabel.count
            label.messagesUnread = withLabel.filter { $0.labels.contains("UNREAD") }.count
            label.threadsTotal = Set(withLabel.map(\.threadID)).count
            label.threadsUnread = Set(withLabel.filter { $0.labels.contains("UNREAD") }.map(\.threadID)).count
            return label
        }
    }

    public func createLabel(name: String, labelListVisibility: String?, messageListVisibility: String?) async throws -> GmailLabel {
        try await call(.createLabel) {
            if labels.values.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw GmailError.badRequest(reason: "conflict", message: "Label name exists or conflicts")
            }
            return insertUserLabel(name: name, labelListVisibility: labelListVisibility,
                                   messageListVisibility: messageListVisibility)
        }
    }

    public func listThreads(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListThreadsResponse {
        try await call(.listThreads) {
            let matching = try matchingMessages(query)
            var latest: [String: StoredMessage] = [:]
            for m in matching where (latest[m.threadID]?.internalDate ?? .min) < m.internalDate { latest[m.threadID] = m }
            let ordered = latest.values.sorted { ($0.internalDate, $0.threadID) > ($1.internalDate, $1.threadID) }
            let (page, next) = try paginate(ordered, query.pageToken, query.maxResults)
            let stubs = page.map { m in
                GmailThread(id: m.threadID, snippet: m.snippet, historyId: String(threadHistoryID(m.threadID)))
            }
            return GmailListThreadsResponse(threads: stubs.isEmpty ? nil : stubs, nextPageToken: next,
                                            resultSizeEstimate: ordered.count)
        }
    }

    public func getThread(id: String, format: MessageFormat, metadataHeaders: [String],
                          priority: RequestPriority) async throws -> GmailThread {
        try await call(.getThread) { try thread(id, format: format, headers: metadataHeaders) }
    }

    public func getThreads(ids: [String], format: MessageFormat, metadataHeaders: [String],
                           priority: RequestPriority) async throws -> [BatchItemResult<GmailThread>] {
        try await withThrowingTaskGroup(of: (Int, Result<GmailThread, GmailError>).self) { group in
            var results = [Result<GmailThread, GmailError>?](repeating: nil, count: ids.count)
            var next = 0, inFlight = 0
            while next < ids.count || inFlight > 0 {
                while next < ids.count, inFlight < 8 {
                    let index = next, id = ids[index]
                    group.addTask {
                        do { return (index, .success(try await self.getThread(id: id, format: format,
                                                                              metadataHeaders: metadataHeaders,
                                                                              priority: priority))) }
                        catch let e as GmailError { return (index, .failure(e)) }
                    }
                    next += 1; inFlight += 1
                }
                guard let (index, result) = try await group.next() else { break }
                inFlight -= 1
                if case .failure(let e) = result, e.abortsFanOut { group.cancelAll(); throw e }
                results[index] = result
            }
            return zip(ids, results).map { BatchItemResult(id: $0, result: $1 ?? .failure(.cancelled)) }
        }
    }

    public func trashThread(id: String) async throws -> GmailThread {
        try await call(.trashThread) {
            let ids = messages.values.filter { $0.threadID == id }.map(\.id)
            guard !ids.isEmpty else { throw GmailError.notFound("threads/\(id)") }
            for mid in ids { change(mid, add: ["TRASH"], remove: ["INBOX", "SPAM"]) }
            return try thread(id, format: .minimal, headers: [])
        }
    }

    public func untrashThread(id: String) async throws -> GmailThread {
        try await call(.untrashThread) {
            let ids = messages.values.filter { $0.threadID == id }.map(\.id)
            guard !ids.isEmpty else { throw GmailError.notFound("threads/\(id)") }
            for mid in ids { change(mid, add: [], remove: ["TRASH"]) }
            return try thread(id, format: .minimal, headers: [])
        }
    }

    public func listMessages(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListMessagesResponse {
        try await call(.listMessages) {
            let ordered = try matchingMessages(query).sorted { ($0.internalDate, $0.id) > ($1.internalDate, $1.id) }
            let (page, next) = try paginate(ordered, query.pageToken, query.maxResults)
            let stubs = page.map { GmailMessage(id: $0.id, threadId: $0.threadID) }
            return GmailListMessagesResponse(messages: stubs.isEmpty ? nil : stubs, nextPageToken: next,
                                             resultSizeEstimate: ordered.count)
        }
    }

    public func getMessage(id: String, format: MessageFormat, metadataHeaders: [String],
                           priority: RequestPriority) async throws -> GmailMessage {
        try await call(.getMessage) {
            guard let m = messages[id] else { throw GmailError.notFound("messages/\(id)") }
            return render(m, format: format, headers: metadataHeaders)
        }
    }

    public func getMessages(ids: [String], format: MessageFormat, metadataHeaders: [String],
                            priority: RequestPriority) async throws -> [BatchItemResult<GmailMessage>] {
        var results: [BatchItemResult<GmailMessage>] = []
        for id in ids {
            do {
                let m = try await getMessage(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
                results.append(BatchItemResult(id: id, result: .success(m)))
            } catch let e as GmailError {
                if e.abortsFanOut { throw e }
                results.append(BatchItemResult(id: id, result: .failure(e)))
            }
        }
        return results
    }

    public func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        try await call(.getAttachment) {
            guard let data = messages[messageID]?.attachments[attachmentID] else {
                throw GmailError.notFound("messages/\(messageID)/attachments/\(attachmentID)")
            }
            return data
        }
    }

    public func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        try await call(.batchModify) {
            guard ids.count <= 1000 else { throw GmailError.badRequest(reason: "invalidArgument", message: "too many ids") }
            for label in add + remove where labels[label] == nil {
                throw GmailError.badRequest(reason: "invalidArgument", message: "Invalid label")
            }
            if batchModifyRejectsMissingIDs, ids.contains(where: { messages[$0] == nil }) {
                throw GmailError.notFound("messages/batchModify")
            }
            for id in ids where messages[id] != nil { change(id, add: Set(add), remove: Set(remove)) }
        }
    }

    public func modifyMessage(id: String, add: [String], remove: [String]) async throws -> GmailMessage {
        try await call(.modifyMessage) {
            guard messages[id] != nil else { throw GmailError.notFound("messages/\(id)") }
            change(id, add: Set(add), remove: Set(remove))
            return render(messages[id]!, format: .minimal, headers: [])
        }
    }

    public func trashMessage(id: String) async throws -> GmailMessage {
        try await call(.trashMessage) {
            guard messages[id] != nil else { throw GmailError.notFound("messages/\(id)") }
            change(id, add: ["TRASH"], remove: ["INBOX", "SPAM"])
            return render(messages[id]!, format: .minimal, headers: [])
        }
    }

    public func untrashMessage(id: String) async throws -> GmailMessage {
        try await call(.untrashMessage) {
            guard messages[id] != nil else { throw GmailError.notFound("messages/\(id)") }
            change(id, add: [], remove: ["TRASH"])
            return render(messages[id]!, format: .minimal, headers: [])
        }
    }

    public func sendMessage(rawRFC822: Data, threadID: String?) async throws -> GmailMessage {
        try await call(.sendMessage) {
            let id = addRaw(rawRFC822, labels: ["SENT"], threadID: threadID)
            recordDeliveries(messageID: id, raw: rawRFC822)
            return render(messages[id]!, format: .minimal, headers: [])
        }
    }

    public func listDrafts(pageToken: String?, q: String?, maxResults: Int) async throws -> GmailListDraftsResponse {
        try await call(.listDrafts) {
            let all = drafts.sorted { $0.key < $1.key }.compactMap { (draftID, messageID) -> GmailDraft? in
                guard let m = messages[messageID] else { return nil }
                return GmailDraft(id: draftID, message: GmailMessage(id: m.id, threadId: m.threadID))
            }
            let (page, next) = try paginate(all, pageToken, maxResults)
            return GmailListDraftsResponse(drafts: page.isEmpty ? nil : page, nextPageToken: next,
                                           resultSizeEstimate: all.count)
        }
    }

    public func getDraft(id: String, format: MessageFormat) async throws -> GmailDraft {
        try await call(.getDraft) {
            guard let mid = drafts[id], let m = messages[mid] else { throw GmailError.notFound("drafts/\(id)") }
            return GmailDraft(id: id, message: render(m, format: format, headers: []))
        }
    }

    public func createDraft(rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        try await call(.createDraft) {
            let mid = addRaw(rawRFC822, labels: ["DRAFT"], threadID: threadID)
            let draftID = "r" + nextID()
            drafts[draftID] = mid
            return GmailDraft(id: draftID, message: render(messages[mid]!, format: .minimal, headers: []))
        }
    }

    public func updateDraft(id: String, rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        try await call(.updateDraft) {
            guard let old = drafts[id], let oldMessage = messages[old] else { throw GmailError.notFound("drafts/\(id)") }
            removeMessage(old)
            let mid = addRaw(rawRFC822, labels: oldMessage.labels.union(["DRAFT"]), threadID: threadID ?? oldMessage.threadID)
            drafts[id] = mid
            return GmailDraft(id: id, message: render(messages[mid]!, format: .minimal, headers: []))
        }
    }

    public func deleteDraft(id: String) async throws {
        try await call(.deleteDraft) {
            guard let mid = drafts.removeValue(forKey: id) else { throw GmailError.notFound("drafts/\(id)") }
            removeMessage(mid)
        }
    }

    public func sendDraft(id: String) async throws -> GmailMessage {
        try await call(.sendDraft) {
            guard let mid = drafts.removeValue(forKey: id), var m = messages[mid] else {
                throw GmailError.notFound("drafts/\(id)")
            }
            removeMessage(mid)
            m.id = nextID()
            m.labels = m.labels.subtracting(["DRAFT"]).union(["SENT"])
            m.internalDate = nextDate(nil)
            insert(m)
            recordDeliveries(messageID: m.id, raw: Self.rawRFC822(m.payload))
            return render(messages[m.id]!, format: .minimal, headers: [])
        }
    }

    public func listHistory(startHistoryID: HistoryID, pageToken: String?, types: [HistoryType], labelID: String?,
                            maxResults: Int, priority: RequestPriority) async throws -> GmailListHistoryResponse {
        try await call(.listHistory) {
            guard startHistoryID.rawValue >= oldestAvailableHistoryID else { throw GmailError.historyExpired }
            let wanted = Set(types.isEmpty ? [.messageAdded, .messageDeleted, .labelAdded, .labelRemoved] : types)
            let records: [GmailHistoryRecord] = history.compactMap { record in
                guard let rid = UInt64(record.id), rid > startHistoryID.rawValue else { return nil }
                var r = record
                if !wanted.contains(.messageAdded) { r.messagesAdded = nil }
                if !wanted.contains(.messageDeleted) { r.messagesDeleted = nil }
                if !wanted.contains(.labelAdded) { r.labelsAdded = nil }
                if !wanted.contains(.labelRemoved) { r.labelsRemoved = nil }
                if r.messagesAdded == nil, r.messagesDeleted == nil, r.labelsAdded == nil, r.labelsRemoved == nil { return nil }
                if let labelID {
                    let ids = (r.messagesAdded ?? []).map(\.message) + (r.messagesDeleted ?? []).map(\.message)
                        + (r.labelsAdded ?? []).map(\.message) + (r.labelsRemoved ?? []).map(\.message)
                    guard ids.contains(where: { ($0.labelIds ?? []).contains(labelID) }) else { return nil }
                }
                return r
            }
            let (page, next) = try paginate(records, pageToken, maxResults)
            return GmailListHistoryResponse(history: page.isEmpty ? nil : page, nextPageToken: next,
                                            historyId: String(historyID))
        }
    }

    public func insertMessage(rawRFC822: Data, labelIDs: [String]) async throws -> GmailMessage {
        try await call(.insertMessage) {
            for label in labelIDs where labels[label] == nil {
                throw GmailError.badRequest(reason: "invalidArgument", message: "Invalid label")
            }
            let id = addRaw(rawRFC822, labels: Set(labelIDs), threadID: nil)
            return render(messages[id]!, format: .minimal, headers: [])
        }
    }
}
