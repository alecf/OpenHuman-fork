import Foundation
import OpenHumanCore

public actor WriteGuard: HTTPTransport {
    public nonisolated let allowlist: WriteAllowlistStore
    private let wrapped: any HTTPTransport

    public init(wrapping transport: any HTTPTransport, allowlist: WriteAllowlistStore) {
        wrapped = transport
        self.allowlist = allowlist
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let snapshot = await allowlist.snapshot
        let summary = ReadOnlyTransport.summary(of: request)
        switch WriteRules.evaluate(request, allowlist: snapshot) {
        case .refuse(let reason):
            Log(.gmail).notice("safe mode write-allowlist refused \(ReadOnlyTransport.redactingAddresses(summary)): \(reason)")
            throw TransportError.blockedBySafeMode(summary)
        case .allow(let forwarded, let route):
            if route.isWrite {
                Log(.gmail).notice("safe mode write-allowlist allowed \(ReadOnlyTransport.redactingAddresses(summary))")
            }
            let response = try await wrapped.send(forwarded)
            if (200..<300).contains(response.status) {
                await allowlist.apply(WriteRules.learning(route: route, responseBody: response.body, allowlist: snapshot))
            }
            return response
        }
    }
}

enum WriteRules {
    enum Decision: Equatable {
        case refuse(String)
        case allow(HTTPRequest, Route)
    }

    enum Route: Equatable {
        case read(ReadKind)
        case createLabel
        case insertMessage
        case batchModify
        case modifyMessage(String), trashMessage(String), untrashMessage(String)
        case trashThread(String), untrashThread(String)
        case createDraft(threadID: String?)
        case updateDraft(String)
        case deleteDraft(String)

        var isWrite: Bool { if case .read = self { return false } else { return true } }
    }

    enum ReadKind: Equatable {
        case labels, label(String), thread(String), message(String), draft(String), other
    }

    static let host = "gmail.googleapis.com"
    static let apiPrefix = ["gmail", "v1", "users", "me"]
    static let uploadPrefix = ["upload", "gmail", "v1", "users", "me"]
    static let labelPrefix = OHGmailLabels.root + "/"

    // SENT, DRAFT and CHAT are excluded because Gmail does not let a client set them
    static let systemLabels: Set<String> = ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "TRASH", "SPAM",
                                            "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS",
                                            "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
    static let labelListVisibilities: Set<String> = ["labelShow", "labelShowIfUnread", "labelHide"]
    static let messageListVisibilities: Set<String> = ["show", "hide"]
    static let maxBatchModifyIDs = 1000

    static func evaluate(_ request: HTTPRequest, allowlist: WriteAllowlist) -> Decision {
        let names = request.headers.keys.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if Set(names).count != names.count { return .refuse("duplicate header names") }

        if request.method == "GET" || (request.method == "POST" && ReadOnlyTransport.isBatchEndpoint(request.url)) {
            if let reason = ReadOnlyTransport.refusalReason(for: request) { return .refuse(reason) }
            return .allow(request, .read(readKind(request.url)))
        }

        if let header = ReadOnlyTransport.methodOverrideHeader(in: request.headers) {
            return .refuse("method override header \(header)")
        }
        if let name = ReadOnlyTransport.methodOverrideQueryName(in: request.url) {
            return .refuse("method override query parameter \(name)")
        }
        guard let (base, segments) = target(request.url) else {
            return .refuse("not a Gmail API path this guard knows (host, scheme, user or path shape)")
        }
        if segments.contains("send") { return .refuse("sending is never allowed in safe mode") }
        if base == .api, request.url.query(percentEncoded: true) != nil {
            return .refuse("a query string on this write is not allowed")
        }

        switch (request.method, base, segments.count, segments.first ?? "") {
        case ("POST", .api, 1, "labels"):
            return createLabel(request)
        case ("POST", .upload, 1, "messages"):
            return insertMessage(request, allowlist: allowlist)
        case ("POST", .api, 2, "messages") where segments[1] == "batchModify":
            return batchModify(request, allowlist: allowlist)
        case ("POST", .api, 3, "messages") where segments[2] == "modify":
            return modifyMessage(request, id: segments[1], allowlist: allowlist)
        case ("POST", .api, 3, "messages") where segments[2] == "trash" || segments[2] == "untrash":
            let id = segments[1]
            guard allowlist.containsMessage(id) else { return .refuse("message \(id) is not on the allowlist") }
            guard isEmpty(request.body) else { return .refuse("\(segments[2]) with a body") }
            return .allow(withoutBody(request), segments[2] == "trash" ? .trashMessage(id) : .untrashMessage(id))
        case ("POST", .api, 3, "threads") where segments[2] == "trash" || segments[2] == "untrash":
            let id = segments[1]
            guard allowlist.containsThread(id) else { return .refuse("thread \(id) is not on the allowlist") }
            guard isEmpty(request.body) else { return .refuse("\(segments[2]) with a body") }
            return .allow(withoutBody(request), segments[2] == "trash" ? .trashThread(id) : .untrashThread(id))
        case ("POST", .upload, 1, "drafts"):
            return createDraft(request, allowlist: allowlist)
        case ("PUT", .upload, 2, "drafts"):
            return updateDraft(request, id: segments[1], allowlist: allowlist)
        case ("DELETE", .api, 2, "drafts"):
            let id = segments[1]
            guard allowlist.containsDraft(id) else { return .refuse("draft \(id) is not on the allowlist") }
            guard isEmpty(request.body) else { return .refuse("drafts.delete with a body") }
            return .allow(withoutBody(request), .deleteDraft(id))
        default:
            return .refuse(notOnAllowlist(method: request.method, base: base, segments: segments))
        }
    }

    static func notOnAllowlist(method: String, base: Base, segments: [String]) -> String {
        let first = segments.first ?? ""
        switch (method, base, first) {
        case (_, _, "settings"): return "settings, filters, forwarding and send-as are never written"
        case (_, _, "watch"), (_, _, "stop"): return "push notifications are not on the allowlist"
        case ("DELETE", _, "messages"), ("DELETE", _, "threads"): return "permanent delete is never allowed"
        case (_, _, "messages") where segments.contains("batchDelete"): return "permanent delete is never allowed"
        case (_, _, "messages") where segments.contains("import"): return "messages.import is not on the allowlist"
        case ("POST", .api, "messages") where segments.count == 1:
            return "messages.insert outside the media upload endpoint is not on the allowlist"
        case (_, _, "labels") where segments.count >= 2: return "labels.update and labels.delete are not on the allowlist"
        case (_, _, "threads") where segments.last == "modify": return "threads.modify is not on the allowlist"
        default: return "\(method.isEmpty ? "<empty>" : method) on this path is not on the write allowlist"
        }
    }

    private static func createLabel(_ request: HTTPRequest) -> Decision {
        let object: [String: Any]
        switch jsonObject(request, allowedKeys: ["name", "labelListVisibility", "messageListVisibility"]) {
        case .failure(let reason): return .refuse("labels.create: \(reason)")
        case .success(let o): object = o
        }
        guard let name = object["name"] as? String else { return .refuse("labels.create without a name") }
        guard name.hasPrefix(labelPrefix), name.count > labelPrefix.count, name.count <= 225,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .refuse("labels.create for a name outside \(labelPrefix)")
        }
        var body = CreateLabelBody(name: name)
        if let value = object["labelListVisibility"] {
            guard let s = value as? String, labelListVisibilities.contains(s) else {
                return .refuse("labels.create with an unknown labelListVisibility")
            }
            body.labelListVisibility = s
        }
        if let value = object["messageListVisibility"] {
            guard let s = value as? String, messageListVisibilities.contains(s) else {
                return .refuse("labels.create with an unknown messageListVisibility")
            }
            body.messageListVisibility = s
        }
        return encoded(request, body).map { .allow($0, .createLabel) } ?? .refuse("labels.create: encoding failed")
    }

    private static func insertMessage(_ request: HTTPRequest, allowlist: WriteAllowlist) -> Decision {
        if let reason = uploadQueryRefusal(request.url, expected: [("uploadType", "multipart"),
                                                                   ("internalDateSource", "receivedTime")]) {
            return .refuse("messages.insert: \(reason)")
        }
        let upload: Upload
        switch Upload.parse(request) {
        case .failure(let reason): return .refuse("messages.insert: \(reason)")
        case .success(let u): upload = u
        }
        let object: [String: Any]
        switch jsonObject(upload.metadata, allowedKeys: ["labelIds"]) {
        case .failure(let reason): return .refuse("messages.insert metadata: \(reason)")
        case .success(let o): object = o
        }
        guard let testLabel = allowlist.testLabelID else {
            return .refuse("messages.insert before the \(OHGmailLabels.test) label id is known (list or create it first)")
        }
        guard let labelIDs = stringArray(object["labelIds"]), !labelIDs.isEmpty else {
            return .refuse("messages.insert without labelIds")
        }
        guard labelIDs.contains(testLabel) else {
            return .refuse("messages.insert without the \(OHGmailLabels.test) label id")
        }
        if let bad = labelIDs.first(where: { !isAllowedLabel($0, allowlist) }) {
            return .refuse("messages.insert with label \(displayID(bad)), which is neither a system nor an OpenHuman label")
        }
        if let reason = SyntheticHeaders.refusal(upload.message) {
            return .refuse("messages.insert of a message that is not synthetic: \(reason)")
        }
        return rebuilt(request, metadata: InsertMetadata(labelIds: unique(labelIDs)), message: upload.message)
            .map { .allow($0, .insertMessage) } ?? .refuse("messages.insert: encoding failed")
    }

    private static func batchModify(_ request: HTTPRequest, allowlist: WriteAllowlist) -> Decision {
        let object: [String: Any]
        switch jsonObject(request, allowedKeys: ["ids", "addLabelIds", "removeLabelIds"]) {
        case .failure(let reason): return .refuse("messages.batchModify: \(reason)")
        case .success(let o): object = o
        }
        guard let ids = stringArray(object["ids"]), !ids.isEmpty else {
            return .refuse("messages.batchModify without ids")
        }
        guard ids.count <= maxBatchModifyIDs else { return .refuse("messages.batchModify with more than 1000 ids") }
        let outside = ids.filter { !allowlist.containsMessage($0) }
        guard outside.isEmpty else {
            return .refuse("messages.batchModify: \(outside.count) of \(ids.count) ids are not on the allowlist "
                           + "(first \(displayID(outside[0])))")
        }
        switch labelChanges(object, allowlist: allowlist) {
        case .failure(let reason): return .refuse("messages.batchModify: \(reason)")
        case .success(let (add, remove)):
            return encoded(request, BatchModifyBody(ids: ids, addLabelIds: add, removeLabelIds: remove))
                .map { .allow($0, .batchModify) } ?? .refuse("messages.batchModify: encoding failed")
        }
    }

    private static func modifyMessage(_ request: HTTPRequest, id: String, allowlist: WriteAllowlist) -> Decision {
        guard allowlist.containsMessage(id) else { return .refuse("message \(id) is not on the allowlist") }
        let object: [String: Any]
        switch jsonObject(request, allowedKeys: ["addLabelIds", "removeLabelIds"]) {
        case .failure(let reason): return .refuse("messages.modify: \(reason)")
        case .success(let o): object = o
        }
        switch labelChanges(object, allowlist: allowlist) {
        case .failure(let reason): return .refuse("messages.modify: \(reason)")
        case .success(let (add, remove)):
            return encoded(request, ModifyBody(addLabelIds: add, removeLabelIds: remove))
                .map { .allow($0, .modifyMessage(id)) } ?? .refuse("messages.modify: encoding failed")
        }
    }

    private static func createDraft(_ request: HTTPRequest, allowlist: WriteAllowlist) -> Decision {
        if let reason = uploadQueryRefusal(request.url, expected: [("uploadType", "multipart")]) {
            return .refuse("drafts.create: \(reason)")
        }
        let upload: Upload
        switch Upload.parse(request) {
        case .failure(let reason): return .refuse("drafts.create: \(reason)")
        case .success(let u): upload = u
        }
        switch draftThreadID(upload.metadata, allowedKeys: ["message"], allowlist: allowlist) {
        case .failure(let reason): return .refuse("drafts.create: \(reason)")
        case .success(let (_, threadID)):
            return rebuilt(request, metadata: DraftMetadata(id: nil, message: DraftMessage(threadId: threadID)),
                           message: upload.message)
                .map { .allow($0, .createDraft(threadID: threadID)) } ?? .refuse("drafts.create: encoding failed")
        }
    }

    private static func updateDraft(_ request: HTTPRequest, id: String, allowlist: WriteAllowlist) -> Decision {
        guard allowlist.containsDraft(id) else { return .refuse("draft \(id) is not on the allowlist") }
        if let reason = uploadQueryRefusal(request.url, expected: [("uploadType", "multipart")]) {
            return .refuse("drafts.update: \(reason)")
        }
        let upload: Upload
        switch Upload.parse(request) {
        case .failure(let reason): return .refuse("drafts.update: \(reason)")
        case .success(let u): upload = u
        }
        switch draftThreadID(upload.metadata, allowedKeys: ["id", "message"], allowlist: allowlist) {
        case .failure(let reason): return .refuse("drafts.update: \(reason)")
        case .success(let (metadataID, threadID)):
            if let metadataID, metadataID != id { return .refuse("drafts.update: metadata id differs from the path id") }
            return rebuilt(request, metadata: DraftMetadata(id: id, message: DraftMessage(threadId: threadID)),
                           message: upload.message)
                .map { .allow($0, .updateDraft(id)) } ?? .refuse("drafts.update: encoding failed")
        }
    }

    private static func draftThreadID(_ metadata: Data, allowedKeys: Set<String>,
                                      allowlist: WriteAllowlist) -> Result<(String?, String?), Refusal> {
        let object: [String: Any]
        switch jsonObject(metadata, allowedKeys: allowedKeys) {
        case .failure(let reason): return .failure(Refusal("metadata: \(reason.text)"))
        case .success(let o): object = o
        }
        var metadataID: String?
        if let value = object["id"] {
            guard let s = value as? String else { return .failure(Refusal("metadata id is not a string")) }
            metadataID = s
        }
        guard let messageValue = object["message"] else { return .success((metadataID, nil)) }
        guard let message = messageValue as? [String: Any] else {
            return .failure(Refusal("metadata message is not an object"))
        }
        if let extra = message.keys.first(where: { $0 != "threadId" }) {
            return .failure(Refusal("metadata message has field \(extra), which is not allowed"))
        }
        guard let threadValue = message["threadId"] else { return .success((metadataID, nil)) }
        guard let threadID = threadValue as? String else { return .failure(Refusal("threadId is not a string")) }
        guard allowlist.containsThread(threadID) else {
            return .failure(Refusal("thread \(displayID(threadID)) is not on the allowlist"))
        }
        return .success((metadataID, threadID))
    }

    static func learning(route: Route, responseBody: Data, allowlist: WriteAllowlist) -> AllowlistLearning {
        var learned = AllowlistLearning()
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type) -> T? { try? decoder.decode(T.self, from: responseBody) }
        func noteLabel(_ label: LabelStub) {
            guard let id = label.id, isPlainID(id), let name = label.name else { return }
            if name.hasPrefix(labelPrefix) { learned.labelsSeen[id] = name } else { learned.labelsNotOurs.insert(id) }
        }
        func noteThread(_ id: String, _ thread: ThreadStub?) {
            guard allowlist.containsThread(id), let thread, thread.id == nil || thread.id == id else { return }
            for m in thread.messages ?? [] where (m.threadId == nil || m.threadId == id) {
                if let mid = m.id, isPlainID(mid) { learned.messageIDs.insert(mid) }
            }
        }
        switch route {
        case .read(.labels):
            for label in decode(LabelList.self)?.labels ?? [] { noteLabel(label) }
        case .read(.label), .createLabel:
            if let label = decode(LabelStub.self) { noteLabel(label) }
        case .read(.thread(let id)), .trashThread(let id), .untrashThread(let id):
            noteThread(id, decode(ThreadStub.self))
        case .read(.message(let id)):
            if let m = decode(MessageStub.self), m.id == id, let tid = m.threadId, allowlist.containsThread(tid) {
                learned.messageIDs.insert(id)
            }
        case .read(.draft(let id)):
            if allowlist.containsDraft(id), let d = decode(DraftStub.self), d.id == id,
               let mid = d.message?.id, isPlainID(mid) {
                learned.messageIDs.insert(mid)
            }
        case .insertMessage:
            if let m = decode(MessageStub.self), let mid = m.id, isPlainID(mid) {
                learned.messageIDs.insert(mid)
                if let tid = m.threadId, isPlainID(tid) {
                    if tid == mid || allowlist.containsThread(tid) {
                        learned.threadIDs.insert(tid)
                    } else {
                        Log(.gmail).notice("safe mode write-allowlist: inserted message \(mid) joined thread \(tid), "
                                           + "which the run did not create; the thread stays off the allowlist")
                    }
                }
            }
        case .createDraft:
            if let d = decode(DraftStub.self), let did = d.id, isPlainID(did) {
                learned.draftIDs.insert(did)
                if let mid = d.message?.id, isPlainID(mid) { learned.messageIDs.insert(mid) }
            }
        case .updateDraft(let id):
            if let d = decode(DraftStub.self), d.id == id, let mid = d.message?.id, isPlainID(mid) {
                learned.messageIDs.insert(mid)
            }
        case .read(.other), .batchModify, .modifyMessage, .trashMessage, .untrashMessage, .deleteDraft:
            break
        }
        return learned
    }

    struct LabelStub: Decodable { var id: String?; var name: String? }
    struct LabelList: Decodable { var labels: [LabelStub]? }
    struct MessageStub: Decodable { var id: String?; var threadId: String? }
    struct ThreadStub: Decodable { var id: String?; var messages: [MessageStub]? }
    struct DraftStub: Decodable { var id: String?; var message: MessageStub? }

    struct CreateLabelBody: Encodable { var name: String; var labelListVisibility: String?; var messageListVisibility: String? }
    struct BatchModifyBody: Encodable { var ids: [String]; var addLabelIds: [String]; var removeLabelIds: [String] }
    struct ModifyBody: Encodable { var addLabelIds: [String]; var removeLabelIds: [String] }
    struct InsertMetadata: Encodable { var labelIds: [String] }
    struct DraftMessage: Encodable { var threadId: String? }
    struct DraftMetadata: Encodable { var id: String?; var message: DraftMessage }

    static func canonicalJSON<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }

    static func encoded<T: Encodable>(_ request: HTTPRequest, _ value: T) -> HTTPRequest? {
        guard let body = canonicalJSON(value) else { return nil }
        var out = request
        out.body = body
        out.headers = replacingContentType(request.headers, with: "application/json; charset=UTF-8")
        return out
    }

    static func rebuilt<T: Encodable>(_ request: HTTPRequest, metadata: T, message: Data) -> HTTPRequest? {
        guard let meta = canonicalJSON(metadata) else { return nil }
        var boundary = ""
        repeat {
            boundary = "oh_guard_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        } while message.range(of: Data(boundary.utf8)) != nil || meta.range(of: Data(boundary.utf8)) != nil
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(message)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var out = request
        out.body = body
        out.headers = replacingContentType(request.headers, with: "multipart/related; boundary=\(boundary)")
        return out
    }

    static func replacingContentType(_ headers: [String: String], with value: String) -> [String: String] {
        var out = headers.filter { $0.key.lowercased() != "content-length" }
        let key = out.keys.first { $0.lowercased() == "content-type" } ?? "Content-Type"
        out[key] = value
        return out
    }

    static func withoutBody(_ request: HTTPRequest) -> HTTPRequest {
        var out = request
        out.body = nil
        out.headers = request.headers.filter { $0.key.lowercased() != "content-length" }
        return out
    }

    struct Refusal: Error, Equatable, CustomStringConvertible {
        var text: String
        init(_ text: String) { self.text = text }
        var description: String { text }
    }

    enum Base: Equatable { case api, upload }

    static func target(_ url: URL) -> (Base, [String])? {
        guard url.scheme?.lowercased() == "https", url.host(percentEncoded: true)?.lowercased() == host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil else {
            return nil
        }
        let path = url.path(percentEncoded: true)
        guard path.hasPrefix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy(isPlainID) else { return nil }
        if segments.starts(with: uploadPrefix), segments.count > uploadPrefix.count {
            return (.upload, Array(segments.dropFirst(uploadPrefix.count)))
        }
        if segments.starts(with: apiPrefix), segments.count > apiPrefix.count {
            return (.api, Array(segments.dropFirst(apiPrefix.count)))
        }
        return nil
    }

    static func readKind(_ url: URL) -> ReadKind {
        guard url.host(percentEncoded: true)?.lowercased() == host else { return .other }
        let segments = url.path(percentEncoded: true).dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.starts(with: apiPrefix) else { return .other }
        let rest = Array(segments.dropFirst(apiPrefix.count))
        switch (rest.count, rest.first ?? "") {
        case (1, "labels"): return .labels
        case (2, "labels") where isPlainID(rest[1]): return .label(rest[1])
        case (2, "threads") where isPlainID(rest[1]): return .thread(rest[1])
        case (2, "messages") where isPlainID(rest[1]): return .message(rest[1])
        case (2, "drafts") where isPlainID(rest[1]): return .draft(rest[1])
        default: return .other
        }
    }

    static func isPlainID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
        }
    }

    static func displayID(_ value: String) -> String { isPlainID(value) ? value : "<non-id>" }

    static func isAllowedLabel(_ id: String, _ allowlist: WriteAllowlist) -> Bool {
        systemLabels.contains(id) || allowlist.isOpenHumanLabel(id)
    }

    private static func labelChanges(_ object: [String: Any],
                                     allowlist: WriteAllowlist) -> Result<([String], [String]), Refusal> {
        var lists: [[String]] = []
        for key in ["addLabelIds", "removeLabelIds"] {
            guard let value = object[key] else { lists.append([]); continue }
            guard let ids = stringArray(value) else { return .failure(Refusal("\(key) is not a list of strings")) }
            if let bad = ids.first(where: { !isAllowedLabel($0, allowlist) }) {
                return .failure(Refusal("\(key) names label \(displayID(bad)), which is neither a system nor an "
                                        + "OpenHuman label"))
            }
            lists.append(unique(ids))
        }
        return .success((lists[0], lists[1]))
    }

    static func stringArray(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        var out: [String] = []
        for item in array {
            guard let s = item as? String else { return nil }
            out.append(s)
        }
        return out
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func isEmpty(_ body: Data?) -> Bool { body?.isEmpty ?? true }

    static func jsonObject(_ request: HTTPRequest, allowedKeys: Set<String>) -> Result<[String: Any], Refusal> {
        guard let contentType = ReadOnlyTransport.header("content-type", in: request.headers),
              MediaType(contentType)?.type == "application/json" else {
            return .failure(Refusal("body is not application/json"))
        }
        guard let body = request.body, !body.isEmpty else { return .failure(Refusal("empty body")) }
        return jsonObject(body, allowedKeys: allowedKeys)
    }

    static func jsonObject(_ data: Data, allowedKeys: Set<String>) -> Result<[String: Any], Refusal> {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = value as? [String: Any] else {
            return .failure(Refusal("body is not a JSON object"))
        }
        if let extra = object.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            return .failure(Refusal("field \(isPlainID(extra) ? extra : "<non-id>") is not allowed"))
        }
        return .success(object)
    }

    static func uploadQueryRefusal(_ url: URL, expected: [(String, String)]) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        if items.contains(where: { $0.name.lowercased() == "deleted" }) {
            return "the deleted parameter is never allowed"
        }
        if items.contains(where: { $0.name.lowercased() == "uploadtype" && $0.value != "multipart" }) {
            return "only uploadType=multipart is allowed"
        }
        if items.contains(where: { $0.name.lowercased() == "internaldatesource" && $0.value != "receivedTime" }) {
            return "only internalDateSource=receivedTime is allowed"
        }
        let names = items.map(\.name)
        guard Set(names).count == names.count else { return "a query parameter is repeated" }
        let got = Set(items.map { "\($0.name)=\($0.value ?? "\u{0}")" })
        let want = Set(expected.map { "\($0.0)=\($0.1)" })
        guard got == want else {
            return "query must be exactly \(expected.map { "\($0.0)=\($0.1)" }.joined(separator: "&"))"
        }
        return nil
    }
}

struct MediaType: Equatable {
    var type: String
    var parameters: [String: String]

    init?(_ value: String) {
        let pieces = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = pieces.first, !first.isEmpty, first.contains("/"), !first.contains(" ") else { return nil }
        type = first.lowercased()
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() where !piece.isEmpty {
            guard let eq = piece.firstIndex(of: "=") else { return nil }
            let name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            guard !name.isEmpty, parameters[name] == nil else { return nil }
            parameters[name] = v
        }
        self.parameters = parameters
    }
}

struct Upload {
    var metadata: Data
    var message: Data

    static func parse(_ request: HTTPRequest) -> Result<Upload, WriteRules.Refusal> {
        guard let contentType = ReadOnlyTransport.header("content-type", in: request.headers),
              let media = MediaType(contentType), media.type == "multipart/related",
              let boundary = media.parameters["boundary"], !boundary.isEmpty, boundary.utf8.count <= 70 else {
            return .failure(.init("body is not multipart/related with a boundary"))
        }
        guard let body = request.body, !body.isEmpty else { return .failure(.init("empty body")) }
        let bytes = [UInt8](body)
        let open = Array("--\(boundary)\r\n".utf8)
        guard bytes.starts(with: open) else { return .failure(.init("body does not start with the boundary")) }
        let delimiter = Array("\r\n--\(boundary)".utf8)
        let hits = occurrences(of: delimiter, in: bytes, from: open.count)
        guard hits.count == 2 else { return .failure(.init("expected exactly two parts and the boundary nowhere else")) }
        let separatorEnd = hits[0] + delimiter.count
        guard bytes[separatorEnd...].starts(with: Array("\r\n".utf8)) else {
            return .failure(.init("malformed part delimiter"))
        }
        let closeEnd = hits[1] + delimiter.count
        let tail = Array(bytes[closeEnd...])
        guard tail == Array("--".utf8) || tail == Array("--\r\n".utf8) else {
            return .failure(.init("content after the close delimiter, or no close delimiter"))
        }
        let marker = Array("--\(boundary)".utf8)
        guard occurrences(of: marker, in: bytes, from: 0).count == 3 else {
            return .failure(.init("the boundary occurs inside a part"))
        }
        let first = Array(bytes[open.count..<hits[0]])
        let second = Array(bytes[(separatorEnd + 2)..<hits[1]])
        switch (part(first, expecting: "application/json"), part(second, expecting: "message/rfc822")) {
        case (.success(let meta), .success(let message)):
            return .success(Upload(metadata: Data(meta), message: Data(message)))
        case (.failure(let reason), _): return .failure(.init("metadata part: \(reason.text)"))
        case (_, .failure(let reason)): return .failure(.init("message part: \(reason.text)"))
        }
    }

    private static func part(_ bytes: [UInt8], expecting type: String) -> Result<[UInt8], WriteRules.Refusal> {
        let separator = Array("\r\n\r\n".utf8)
        guard let end = occurrences(of: separator, in: bytes, from: 0).first else {
            return .failure(.init("no blank line after the part headers"))
        }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        var contentType: MediaType?
        for line in head.components(separatedBy: "\r\n") {
            guard let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else {
                return .failure(.init("malformed part header"))
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-type":
                guard contentType == nil, let media = MediaType(value) else {
                    return .failure(.init("repeated or malformed Content-Type"))
                }
                contentType = media
            case "content-transfer-encoding":
                guard ["7bit", "8bit", "binary"].contains(value.lowercased()) else {
                    return .failure(.init("Content-Transfer-Encoding cannot be inspected"))
                }
            default:
                return .failure(.init("part header \(WriteRules.isPlainID(name) ? name : "<non-id>") is not allowed"))
            }
        }
        guard contentType?.type == type else { return .failure(.init("Content-Type is not \(type)")) }
        return .success(Array(bytes[(end + separator.count)...]))
    }

    static func occurrences(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var out: [Int] = []
        var i = start
        let last = haystack.count - needle.count
        let first = needle[0]
        while i <= last {
            if haystack[i] == first, haystack[i..<(i + needle.count)].elementsEqual(needle) {
                out.append(i)
                i += needle.count
            } else {
                i += 1
            }
        }
        return out
    }
}

enum SyntheticHeaders {
    static func refusal(_ raw: Data) -> String? {
        let bytes = [UInt8](raw)
        let crlf = Upload.occurrences(of: Array("\r\n\r\n".utf8), in: bytes, from: 0).first
        let lf = Upload.occurrences(of: Array("\n\n".utf8), in: bytes, from: 0).first
        guard let end = [crlf, lf].compactMap({ $0 }).min() else { return "no header block" }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        var fields: [(String, String)] = []
        for raw in head.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let first = line.first, first == " " || first == "\t" {
                guard !fields.isEmpty else { return "header block starts with a continuation line" }
                fields[fields.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return "malformed header line" }
            fields.append((line[..<colon].lowercased().trimmingCharacters(in: .whitespaces),
                           line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        func values(_ name: String) -> [String] { fields.filter { $0.0 == name }.map(\.1) }

        let from = values("from")
        guard from.count == 1, let address = singleAddress(from[0]),
              address.lowercased() == SyntheticThreads.senderAddress else {
            return "From is not the synthetic sender"
        }
        for name in ["sender", "reply-to"] where !values(name).isEmpty {
            return "\(name) header is not allowed"
        }
        let subject = values("subject")
        guard subject.count == 1, subject[0].hasPrefix(SyntheticThreads.subjectPrefix + " ") else {
            return "Subject does not start with \(SyntheticThreads.subjectPrefix)"
        }
        let messageID = values("message-id")
        guard messageID.count == 1, let ids = messageIDs(messageID[0]), ids.count == 1 else {
            return "Message-ID missing, repeated or not synthetic"
        }
        for name in ["in-reply-to", "references"] {
            let found = values(name)
            guard found.count <= 1 else { return "\(name) repeated" }
            if let value = found.first, messageIDs(value) == nil { return "\(name) points outside the synthetic domain" }
        }
        return nil
    }

    private static func singleAddress(_ value: String) -> String? {
        guard !value.contains(","), !value.contains(";") else { return nil }
        if let open = value.lastIndex(of: "<") {
            guard let close = value.lastIndex(of: ">"), close > open,
                  value[value.index(after: close)...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    static func messageIDs(_ value: String) -> [String]? {
        var ids: [String] = []
        var rest = Substring(value)
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.isEmpty { break }
            guard rest.first == "<", let close = rest.firstIndex(of: ">") else { return nil }
            let token = String(rest[...close])
            let inner = token.dropFirst().dropLast()
            guard inner.hasSuffix("@" + SyntheticThreads.messageIDDomain), !inner.contains("<"),
                  !inner.contains(" "), inner.count > SyntheticThreads.messageIDDomain.count + 1 else { return nil }
            ids.append(token)
            rest = rest[rest.index(after: close)...]
        }
        return ids.isEmpty ? nil : ids
    }
}
