import Foundation
import OpenHumanCore

public final class GmailClient: GmailAPI {
    public let accountEmail: String
    let executor: RequestExecutor
    let config: GmailClientConfig

    static let host = "gmail.googleapis.com"
    static let apiPath = "/gmail/v1/users/me/"
    static let uploadPath = "/upload/gmail/v1/users/me/"
    static let maxRawBytes = 35 * 1024 * 1024
    static let maxBatchSize = 50
    static let maxBatchModifyIDs = 1000

    public convenience init(accountEmail: String, tokens: AccessTokenProvider, transport: HTTPTransport,
                            config: GmailClientConfig, clock: any OHClock, metrics: GmailMetricsSink?) {
        self.init(accountEmail: accountEmail, tokens: tokens, transport: transport, config: config, clock: clock,
                  metrics: metrics,
                  limiter: QuotaLimiter(unitsPerMinute: config.unitsPerMinute,
                                        maxConcurrent: config.maxConcurrentRequests, clock: clock),
                  jitter: { Double.random(in: 0...1) })
    }

    init(accountEmail: String, tokens: AccessTokenProvider, transport: HTTPTransport, config: GmailClientConfig,
         clock: any OHClock, metrics: GmailMetricsSink?, limiter: QuotaLimiter, jitter: @escaping @Sendable () -> Double) {
        self.accountEmail = accountEmail
        self.config = config
        executor = RequestExecutor(transport: transport, tokens: tokens, limiter: limiter, clock: clock, config: config,
                                   metrics: metrics, jitter: jitter)
    }

    public var quotaLimiter: QuotaLimiter { executor.limiter }

    public func getProfile(priority: RequestPriority) async throws -> GmailProfile {
        try await get(.getProfile, "profile", priority: priority)
    }

    public func listSendAs() async throws -> [GmailSendAs] {
        struct Response: Decodable { var sendAs: [GmailSendAs]? }
        let response: Response = try await get(.listSendAs, "settings/sendAs", priority: .sync)
        return response.sendAs ?? []
    }

    public func listLabels() async throws -> [GmailLabel] {
        let response: GmailListLabelsResponse = try await get(.listLabels, "labels", priority: .sync)
        return response.labels ?? []
    }

    public func getLabel(id: String) async throws -> GmailLabel {
        try await get(.getLabel, "labels/\(id)", priority: .sync)
    }

    public func createLabel(name: String, labelListVisibility: String?, messageListVisibility: String?) async throws -> GmailLabel {
        struct Body: Encodable { var name: String; var labelListVisibility: String?; var messageListVisibility: String? }
        return try await send(.createLabel, "POST", "labels",
                              json: Body(name: name, labelListVisibility: labelListVisibility,
                                         messageListVisibility: messageListVisibility))
    }

    public func listThreads(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListThreadsResponse {
        try await get(.listThreads, "threads", query: Self.listItems(query, max: 500), priority: priority)
    }

    public func getThread(id: String, format: MessageFormat, metadataHeaders: [String],
                          priority: RequestPriority) async throws -> GmailThread {
        try await get(.getThread, "threads/\(id)", query: Self.formatItems(format, metadataHeaders), priority: priority)
    }

    public func getThreads(ids: [String], format: MessageFormat, metadataHeaders: [String],
                           priority: RequestPriority) async throws -> [BatchItemResult<GmailThread>] {
        if ids.count <= 1 || config.batchSize <= 1 {
            return try await fanOut(ids) { id in
                try await self.getThread(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
            }
        }
        return try await batchGet(.getThread, ids: ids, resourcePrefix: "threads",
                                  query: Self.formatItems(format, metadataHeaders), priority: priority)
    }

    public func trashThread(id: String) async throws -> GmailThread {
        try await send(.trashThread, "POST", "threads/\(id)/trash", json: Optional<Empty>.none)
    }

    public func untrashThread(id: String) async throws -> GmailThread {
        try await send(.untrashThread, "POST", "threads/\(id)/untrash", json: Optional<Empty>.none)
    }

    public func listMessages(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListMessagesResponse {
        try await get(.listMessages, "messages", query: Self.listItems(query, max: 500), priority: priority)
    }

    public func getMessage(id: String, format: MessageFormat, metadataHeaders: [String],
                           priority: RequestPriority) async throws -> GmailMessage {
        try await get(.getMessage, "messages/\(id)", query: Self.formatItems(format, metadataHeaders), priority: priority)
    }

    public func getMessages(ids: [String], format: MessageFormat, metadataHeaders: [String],
                            priority: RequestPriority) async throws -> [BatchItemResult<GmailMessage>] {
        if ids.count <= 1 || config.batchSize <= 1 {
            return try await fanOut(ids) { id in
                try await self.getMessage(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
            }
        }
        return try await batchGet(.getMessage, ids: ids, resourcePrefix: "messages",
                                  query: Self.formatItems(format, metadataHeaders), priority: priority)
    }

    public func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        let body: GmailMessagePartBody = try await get(.getAttachment, "messages/\(messageID)/attachments/\(attachmentID)",
                                                       priority: .interactive)
        guard let encoded = body.data else {
            if body.size == 0 { return Data() }
            throw GmailError.decoding("attachment has no data")
        }
        guard let data = Base64URL.decode(encoded) else { throw GmailError.decoding("attachment data is not base64url") }
        if let size = body.size, size != data.count { throw GmailError.decoding("attachment size mismatch") }
        return data
    }

    public func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        struct Body: Encodable { var ids: [String]; var addLabelIds: [String]; var removeLabelIds: [String] }
        for start in stride(from: 0, to: ids.count, by: Self.maxBatchModifyIDs) {
            let chunk = Array(ids[start..<min(start + Self.maxBatchModifyIDs, ids.count)])
            _ = try await raw(.batchModify, "POST", Self.url(Self.apiPath + "messages/batchModify"),
                              body: try Self.encode(Body(ids: chunk, addLabelIds: add, removeLabelIds: remove)),
                              contentType: "application/json", priority: .queue, resource: "messages/batchModify")
        }
    }

    public func modifyMessage(id: String, add: [String], remove: [String]) async throws -> GmailMessage {
        struct Body: Encodable { var addLabelIds: [String]; var removeLabelIds: [String] }
        return try await send(.modifyMessage, "POST", "messages/\(id)/modify", json: Body(addLabelIds: add, removeLabelIds: remove))
    }

    public func trashMessage(id: String) async throws -> GmailMessage {
        try await send(.trashMessage, "POST", "messages/\(id)/trash", json: Optional<Empty>.none)
    }

    public func untrashMessage(id: String) async throws -> GmailMessage {
        try await send(.untrashMessage, "POST", "messages/\(id)/untrash", json: Optional<Empty>.none)
    }

    public func sendMessage(rawRFC822: Data, threadID: String?) async throws -> GmailMessage {
        struct Meta: Encodable { var threadId: String? }
        return try await upload(.sendMessage, "POST", "messages/send", query: [],
                                metadata: Meta(threadId: threadID), raw: rawRFC822)
    }

    public func listDrafts(pageToken: String?, q: String?, maxResults: Int) async throws -> GmailListDraftsResponse {
        var items: [(String, String)] = [("maxResults", String(min(max(maxResults, 1), 500)))]
        if let pageToken { items.append(("pageToken", pageToken)) }
        if let q { items.append(("q", q)) }
        return try await get(.listDrafts, "drafts", query: items, priority: .sync)
    }

    public func getDraft(id: String, format: MessageFormat) async throws -> GmailDraft {
        try await get(.getDraft, "drafts/\(id)", query: [("format", format.rawValue)], priority: .sync)
    }

    public func createDraft(rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        struct Message: Encodable { var threadId: String? }
        struct Meta: Encodable { var message: Message }
        return try await upload(.createDraft, "POST", "drafts", query: [],
                                metadata: Meta(message: Message(threadId: threadID)), raw: rawRFC822)
    }

    public func updateDraft(id: String, rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        struct Message: Encodable { var threadId: String? }
        struct Meta: Encodable { var id: String; var message: Message }
        return try await upload(.updateDraft, "PUT", "drafts/\(id)", query: [],
                                metadata: Meta(id: id, message: Message(threadId: threadID)), raw: rawRFC822)
    }

    public func deleteDraft(id: String) async throws {
        _ = try await raw(.deleteDraft, "DELETE", Self.url(Self.apiPath + "drafts/\(id)"), body: nil, contentType: nil,
                          priority: .queue, resource: "drafts/\(id)")
    }

    public func sendDraft(id: String) async throws -> GmailMessage {
        struct Body: Encodable { var id: String }
        return try await send(.sendDraft, "POST", "drafts/send", json: Body(id: id))
    }

    public func listHistory(startHistoryID: HistoryID, pageToken: String?, types: [HistoryType], labelID: String?,
                            maxResults: Int, priority: RequestPriority) async throws -> GmailListHistoryResponse {
        var items: [(String, String)] = [("startHistoryId", String(startHistoryID.rawValue)),
                                         ("maxResults", String(min(max(maxResults, 1), 500)))]
        let kinds = types.isEmpty ? [.messageAdded, .messageDeleted, .labelAdded, .labelRemoved] : types
        items += kinds.map { ("historyTypes", $0.rawValue) }
        if let labelID { items.append(("labelId", labelID)) }
        if let pageToken { items.append(("pageToken", pageToken)) }
        do {
            return try await get(.listHistory, "history", query: items, priority: priority)
        } catch GmailError.notFound {
            throw GmailError.historyExpired
        }
    }

    public func insertMessage(rawRFC822: Data, labelIDs: [String]) async throws -> GmailMessage {
        struct Meta: Encodable { var labelIds: [String] }
        return try await upload(.insertMessage, "POST", "messages", query: [("internalDateSource", "receivedTime")],
                                metadata: Meta(labelIds: labelIDs), raw: rawRFC822)
    }

    private struct Empty: Encodable {}

    private func get<T: Decodable>(_ method: GmailMethod, _ path: String, query: [(String, String)] = [],
                                   priority: RequestPriority) async throws -> T {
        let response = try await raw(method, "GET", Self.url(Self.apiPath + path, query: Self.withFields(method, query)),
                                     body: nil, contentType: nil, priority: priority, resource: path,
                                     timeout: method == .getAttachment ? .seconds(180) : .seconds(30))
        return try Self.decode(T.self, response.body, method: method)
    }

    private func send<T: Decodable, B: Encodable>(_ method: GmailMethod, _ httpMethod: String, _ path: String,
                                                  json: B?) async throws -> T {
        let body = try json.map { try Self.encode($0) }
        let response = try await raw(method, httpMethod, Self.url(Self.apiPath + path), body: body,
                                     contentType: body == nil ? nil : "application/json", priority: .queue,
                                     resource: path)
        return try Self.decode(T.self, response.body, method: method)
    }

    private func upload<T: Decodable, M: Encodable>(_ method: GmailMethod, _ httpMethod: String, _ path: String,
                                                    query: [(String, String)], metadata: M, raw message: Data) async throws -> T {
        guard message.count <= Self.maxRawBytes else { throw GmailError.payloadTooLarge }
        let boundary = "oh_upload_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try Self.encode(metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(message)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let url = Self.url(Self.uploadPath + path, query: [("uploadType", "multipart")] + query)
        let response = try await raw(method, httpMethod, url, body: body,
                                     contentType: "multipart/related; boundary=\(boundary)", priority: .queue,
                                     resource: path, timeout: .seconds(120))
        return try Self.decode(T.self, response.body, method: method)
    }

    private func raw(_ method: GmailMethod, _ httpMethod: String, _ url: URL, body: Data?, contentType: String?,
                     priority: RequestPriority, resource: String, timeout: Duration = .seconds(30)) async throws -> HTTPResponse {
        try await executor.execute(GmailCall(method: method, httpMethod: httpMethod, url: url, body: body,
                                             contentType: contentType, priority: priority, timeout: timeout,
                                             resource: resource))
    }

    private func batchGet<T: Decodable & Sendable>(_ method: GmailMethod, ids: [String], resourcePrefix: String,
                                                   query: [(String, String)],
                                                   priority: RequestPriority) async throws -> [BatchItemResult<T>] {
        let size = min(max(config.batchSize, 1), Self.maxBatchSize)
        let chunks = stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
        var results = [Result<T, GmailError>?](repeating: nil, count: ids.count)
        let limit = max(1, config.maxConcurrentRequests)
        let executor = executor
        try await withThrowingTaskGroup(of: (Int, [Result<T, GmailError>]).self) { group in
            var next = 0
            var inFlight = 0
            while next < chunks.count || inFlight > 0 {
                while next < chunks.count, inFlight < limit {
                    let chunkIndex = next
                    let chunk = chunks[chunkIndex]
                    group.addTask {
                        let items = chunk.map {
                            BatchCallItem(url: Self.url(Self.apiPath + "\(resourcePrefix)/\($0)", query: query),
                                          resource: "\(resourcePrefix)/\($0)")
                        }
                        let raw = try await executor.executeBatch(method: method, items: items, priority: priority)
                        return (chunkIndex, raw.map { outcome in
                            outcome.flatMap { response in
                                Result { try Self.decode(T.self, response.body, method: method) }
                                    .mapError { ($0 as? GmailError) ?? .decoding("\(method.rawValue): invalid JSON") }
                            }
                        })
                    }
                    next += 1
                    inFlight += 1
                }
                guard let (chunkIndex, chunkResults) = try await group.next() else { break }
                inFlight -= 1
                for (offset, result) in chunkResults.enumerated() { results[chunkIndex * size + offset] = result }
            }
        }
        return zip(ids, results).map { BatchItemResult(id: $0, result: $1 ?? .failure(.cancelled)) }
    }

    private func fanOut<T: Sendable>(_ ids: [String],
                                     _ operation: @escaping @Sendable (String) async throws -> T) async throws -> [BatchItemResult<T>] {
        guard !ids.isEmpty else { return [] }
        var results = [Result<T, GmailError>?](repeating: nil, count: ids.count)
        let limit = max(1, config.maxConcurrentRequests)
        try await withThrowingTaskGroup(of: (Int, Result<T, GmailError>).self) { group in
            var next = 0
            var inFlight = 0
            while next < ids.count || inFlight > 0 {
                while next < ids.count, inFlight < limit {
                    let index = next
                    let id = ids[index]
                    group.addTask {
                        do { return (index, .success(try await operation(id))) }
                        catch let error as GmailError { return (index, .failure(error)) }
                        catch { return (index, .failure(.cancelled)) }
                    }
                    next += 1
                    inFlight += 1
                }
                guard let (index, result) = try await group.next() else { break }
                inFlight -= 1
                if case .failure(let error) = result, error.abortsFanOut {
                    group.cancelAll()
                    throw error
                }
                results[index] = result
            }
        }
        return zip(ids, results).map { BatchItemResult(id: $0, result: $1 ?? .failure(.cancelled)) }
    }


    static func url(_ path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? String($0) }
            .joined(separator: "/")
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
        }
        return components.url!
    }

    private static let pathAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? s
    }

    static func listItems(_ query: ListQuery, max: Int) -> [(String, String)] {
        var items: [(String, String)] = query.labelIDs.map { ("labelIds", $0) }
        if let q = query.q { items.append(("q", q)) }
        if let token = query.pageToken { items.append(("pageToken", token)) }
        items.append(("maxResults", String(min(Swift.max(query.maxResults, 1), max))))
        if query.includeSpamTrash { items.append(("includeSpamTrash", "true")) }
        return items
    }

    static func withFields(_ method: GmailMethod, _ query: [(String, String)]) -> [(String, String)] {
        guard let fields = GmailFields.fields(for: method) else { return query }
        return query + [("fields", fields)]
    }

    static func formatItems(_ format: MessageFormat, _ headers: [String]) -> [(String, String)] {
        var items = [("format", format.rawValue)]
        if format == .metadata { items += headers.map { ("metadataHeaders", $0) } }
        return items
    }

    static func encode<B: Encodable>(_ value: B) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch { throw GmailError.decoding("request body encoding failed") }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, method: GmailMethod) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch let error as DecodingError {
            throw GmailError.decoding("\(method.rawValue): \(describe(error))")
        } catch {
            throw GmailError.decoding("\(method.rawValue): invalid JSON")
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing key \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context): return "type mismatch at \(path(context))"
        case .valueNotFound(_, let context): return "null at \(path(context))"
        case .dataCorrupted(let context): return "corrupted data at \(path(context))"
        @unknown default: return "decoding error"
        }
    }
}

extension GmailError {
    // Why: these errors would hit every item of the fan-out, so they are thrown once instead of reported per item
    public var abortsFanOut: Bool {
        switch self {
        case .unauthorized, .reauthRequired, .cancelled, .dailyLimitExceeded: return true
        case .transport(let t):
            switch t {
            case .notConnected, .cannotConnect, .refusedByGuard, .cancelled: return true
            default: return false
            }
        default: return false
        }
    }
}
