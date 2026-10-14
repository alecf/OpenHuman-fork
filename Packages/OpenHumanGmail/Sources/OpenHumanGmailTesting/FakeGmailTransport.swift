import Foundation
import OpenHumanCore
import OpenHumanGmail
import Synchronization

public final class FakeGmailTransport: HTTPTransport {
    public let gmail: FakeGmail
    private let log = Mutex<[HTTPRequest]>([])

    public init(_ gmail: FakeGmail) {
        self.gmail = gmail
    }

    public var requests: [HTTPRequest] { log.withLock { $0 } }
    public var nonGETRequests: [HTTPRequest] {
        requests.filter { $0.method != "GET" && !($0.method == "POST" && $0.url.path().hasPrefix("/batch/")) }
    }
    public var batchRequests: [HTTPRequest] { requests.filter { $0.url.path().hasPrefix("/batch/") } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        guard request.headers["Authorization"]?.hasPrefix("Bearer ") == true else {
            return Self.error(401, reason: "authError", message: "Missing credentials")
        }
        if request.method == "POST", request.url.path(percentEncoded: false).hasPrefix("/batch/") {
            return try await batch(request)
        }
        return try await respond(request)
    }

    private func respond(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await route(request)
        } catch let error as GmailError {
            switch error {
            case .transport(let t): throw t
            case .cancelled: throw TransportError.cancelled
            default: return Self.response(for: error)
            }
        }
    }

    private func batch(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let contentType = request.headers["Content-Type"],
              let boundary = contentType.components(separatedBy: "boundary=").last,
              let body = request.body, let text = String(data: body, encoding: .isoLatin1) else {
            return Self.error(400, reason: "badRequest", message: "Invalid batch request")
        }
        let reply = "batch_response_fake"
        var out = ""
        for part in text.components(separatedBy: "--\(boundary)").dropFirst().filter({ !$0.hasPrefix("--") }) {
            let lines = part.components(separatedBy: "\r\n")
            guard let line = lines.first(where: { $0.hasPrefix("GET ") }),
                  let id = lines.first(where: { $0.lowercased().hasPrefix("content-id:") }) else {
                return Self.error(400, reason: "badRequest", message: "Invalid batch part")
            }
            let target = line.split(separator: " ")[1]
            let url = URL(string: "https://gmail.googleapis.com" + target)!
            let inner = try await respond(HTTPRequest(method: "GET", url: url, headers: request.headers))
            let contentID = id.dropFirst("content-id:".count).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "<", with: "<response-")
            out += "--\(reply)\r\nContent-Type: application/http\r\nContent-ID: \(contentID)\r\n\r\n"
            out += "HTTP/1.1 \(inner.status) X\r\n"
            for (name, value) in inner.headers.sorted(by: { $0.key < $1.key }) { out += "\(name): \(value)\r\n" }
            out += "\r\n\(String(decoding: inner.body, as: UTF8.self))\r\n"
        }
        out += "--\(reply)--\r\n"
        return HTTPResponse(status: 200, headers: ["content-type": "multipart/mixed; boundary=\(reply)"],
                            body: Data(out.utf8))
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path(percentEncoded: false)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func values(_ name: String) -> [String] { query.filter { $0.name == name }.compactMap(\.value) }
        func value(_ name: String) -> String? { values(name).first }
        let api = "/gmail/v1/users/me/", upload = "/upload/gmail/v1/users/me/"
        let isUpload = path.hasPrefix(upload)
        guard path.hasPrefix(api) || isUpload else { return Self.error(404, reason: "notFound", message: "Not Found") }
        let segments = path.dropFirst(isUpload ? upload.count : api.count).split(separator: "/").map(String.init)
        let format = value("format").flatMap(MessageFormat.init(rawValue:)) ?? .full
        let headers = values("metadataHeaders")
        let priority = RequestPriority.sync

        switch (request.method, isUpload, segments.count, segments.first ?? "") {
        case ("GET", false, 1, "profile"):
            return try Self.ok(await gmail.getProfile(priority: priority))
        case ("GET", false, 2, "settings") where segments[1] == "sendAs":
            struct R: Encodable { var sendAs: [GmailSendAs] }
            return try Self.ok(R(sendAs: await gmail.listSendAs()))
        case ("GET", false, 1, "labels"):
            return try Self.ok(GmailListLabelsResponse(labels: await gmail.listLabels()))
        case ("GET", false, 2, "labels"):
            return try Self.ok(await gmail.getLabel(id: segments[1]))
        case ("POST", false, 1, "labels"):
            struct B: Decodable { var name: String; var labelListVisibility: String?; var messageListVisibility: String? }
            let b = try Self.body(B.self, request)
            return try Self.ok(await gmail.createLabel(name: b.name, labelListVisibility: b.labelListVisibility,
                                                       messageListVisibility: b.messageListVisibility))
        case ("GET", false, 1, "threads"):
            return try Self.ok(await gmail.listThreads(Self.listQuery(values, value), priority: priority))
        case ("GET", false, 2, "threads"):
            return try Self.ok(await gmail.getThread(id: segments[1], format: format, metadataHeaders: headers,
                                                     priority: priority))
        case ("POST", false, 3, "threads") where segments[2] == "trash":
            return try Self.ok(await gmail.trashThread(id: segments[1]))
        case ("POST", false, 3, "threads") where segments[2] == "untrash":
            return try Self.ok(await gmail.untrashThread(id: segments[1]))
        case ("GET", false, 1, "messages"):
            return try Self.ok(await gmail.listMessages(Self.listQuery(values, value), priority: priority))
        case ("POST", false, 2, "messages") where segments[1] == "batchModify":
            struct B: Decodable { var ids: [String]; var addLabelIds: [String]?; var removeLabelIds: [String]? }
            let b = try Self.body(B.self, request)
            try await gmail.batchModifyMessages(ids: b.ids, add: b.addLabelIds ?? [], remove: b.removeLabelIds ?? [])
            return HTTPResponse(status: 204, headers: [:], body: Data())
        case ("GET", false, 2, "messages"):
            return try Self.ok(await gmail.getMessage(id: segments[1], format: format, metadataHeaders: headers,
                                                      priority: priority))
        case ("POST", false, 3, "messages") where segments[2] == "modify":
            struct B: Decodable { var addLabelIds: [String]?; var removeLabelIds: [String]? }
            let b = try Self.body(B.self, request)
            return try Self.ok(await gmail.modifyMessage(id: segments[1], add: b.addLabelIds ?? [],
                                                         remove: b.removeLabelIds ?? []))
        case ("POST", false, 3, "messages") where segments[2] == "trash":
            return try Self.ok(await gmail.trashMessage(id: segments[1]))
        case ("POST", false, 3, "messages") where segments[2] == "untrash":
            return try Self.ok(await gmail.untrashMessage(id: segments[1]))
        case ("GET", false, 4, "messages") where segments[2] == "attachments":
            let data = try await gmail.getAttachment(messageID: segments[1], attachmentID: segments[3])
            return try Self.ok(GmailMessagePartBody(size: data.count, data: Base64URL.encode(data)))
        case ("GET", false, 1, "drafts"):
            return try Self.ok(await gmail.listDrafts(pageToken: value("pageToken"), q: value("q"),
                                                      maxResults: value("maxResults").flatMap(Int.init) ?? 100))
        case ("GET", false, 2, "drafts"):
            return try Self.ok(await gmail.getDraft(id: segments[1], format: format))
        case ("DELETE", false, 2, "drafts"):
            try await gmail.deleteDraft(id: segments[1])
            return HTTPResponse(status: 204, headers: [:], body: Data())
        case ("POST", false, 2, "drafts") where segments[1] == "send":
            struct B: Decodable { var id: String }
            return try Self.ok(await gmail.sendDraft(id: try Self.body(B.self, request).id))
        case ("GET", false, 1, "history"):
            guard let start = value("startHistoryId").flatMap(UInt64.init) else {
                return Self.error(400, reason: "invalidArgument", message: "startHistoryId required")
            }
            let types = values("historyTypes").compactMap(HistoryType.init(rawValue:))
            return try Self.ok(await gmail.listHistory(startHistoryID: HistoryID(start), pageToken: value("pageToken"),
                                                       types: types, labelID: value("labelId"),
                                                       maxResults: value("maxResults").flatMap(Int.init) ?? 100,
                                                       priority: priority))
        case ("POST", true, 1, "messages"):
            struct M: Decodable { var labelIds: [String]? }
            let (meta, raw) = try Self.multipart(request, M.self)
            return try Self.ok(await gmail.insertMessage(rawRFC822: raw, labelIDs: meta.labelIds ?? []))
        case ("POST", true, 2, "messages") where segments[1] == "send":
            struct M: Decodable { var threadId: String? }
            let (meta, raw) = try Self.multipart(request, M.self)
            return try Self.ok(await gmail.sendMessage(rawRFC822: raw, threadID: meta.threadId))
        case ("POST", true, 1, "drafts"):
            struct Msg: Decodable { var threadId: String? }
            struct M: Decodable { var message: Msg? }
            let (meta, raw) = try Self.multipart(request, M.self)
            return try Self.ok(await gmail.createDraft(rawRFC822: raw, threadID: meta.message?.threadId))
        case ("PUT", true, 2, "drafts"):
            struct Msg: Decodable { var threadId: String? }
            struct M: Decodable { var message: Msg? }
            let (meta, raw) = try Self.multipart(request, M.self)
            return try Self.ok(await gmail.updateDraft(id: segments[1], rawRFC822: raw, threadID: meta.message?.threadId))
        default:
            return Self.error(404, reason: "notFound", message: "FakeGmailTransport: no route")
        }
    }

    static func listQuery(_ values: (String) -> [String], _ value: (String) -> String?) -> ListQuery {
        ListQuery(labelIDs: values("labelIds"), q: value("q"), pageToken: value("pageToken"),
                  maxResults: value("maxResults").flatMap(Int.init) ?? 100,
                  includeSpamTrash: value("includeSpamTrash") == "true")
    }

    static func ok<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json; charset=UTF-8"],
                     body: try JSONEncoder().encode(value))
    }

    static func body<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: request.body ?? Data()) }
        catch { throw GmailError.badRequest(reason: "parseError", message: "Invalid JSON payload") }
    }

    static func multipart<M: Decodable>(_ request: HTTPRequest, _ type: M.Type) throws -> (M, Data) {
        guard let contentType = request.headers["Content-Type"],
              let boundary = contentType.components(separatedBy: "boundary=").last, contentType.hasPrefix("multipart/related"),
              let body = request.body, let text = String(data: body, encoding: .isoLatin1) else {
            throw GmailError.badRequest(reason: "badContent", message: "expected multipart/related")
        }
        let parts = text.components(separatedBy: "--\(boundary)").dropFirst().filter { !$0.hasPrefix("--") }
        guard parts.count == 2 else { throw GmailError.badRequest(reason: "badContent", message: "expected two parts") }
        func content(_ part: String) -> String {
            guard let r = part.range(of: "\r\n\r\n") else { return "" }
            var c = String(part[r.upperBound...])
            if c.hasSuffix("\r\n") { c.removeLast() }
            return c
        }
        let meta = try JSONDecoder().decode(M.self, from: Data(content(parts[0]).utf8))
        return (meta, content(parts[1]).data(using: .isoLatin1) ?? Data())
    }

    static func response(for error: GmailError) -> HTTPResponse {
        switch error {
        case .unauthorized, .reauthRequired: return Self.error(401, reason: "authError", message: "Invalid Credentials")
        case .forbidden(let reason, let message): return Self.error(403, reason: reason, message: message)
        case .dailyLimitExceeded: return Self.error(403, reason: "dailyLimitExceeded", message: "Daily Limit Exceeded")
        case .notFound, .historyExpired: return Self.error(404, reason: "notFound", message: "Requested entity was not found.")
        case .rateLimited(let after):
            var headers: [String: String] = [:]
            if let after { headers["retry-after"] = String(Int(after.timeInterval.rounded(.up))) }
            return Self.error(429, reason: "rateLimitExceeded", message: "Rate Limit Exceeded", headers: headers)
        case .badRequest(let reason, let message):
            return Self.error(reason == "conflict" ? 409 : 400, reason: reason ?? "badRequest", message: message)
        case .preconditionFailed(let message): return Self.error(412, reason: "failedPrecondition", message: message)
        case .payloadTooLarge: return Self.error(413, reason: "uploadTooLarge", message: "Payload too large")
        case .server(let status, let message): return Self.error(status, reason: "backendError", message: message ?? "Backend Error")
        case .decoding, .quotaBudgetExhausted, .transport, .cancelled:
            return Self.error(500, reason: "backendError", message: "Backend Error")
        }
    }

    static func error(_ status: Int, reason: String, message: String, headers: [String: String] = [:]) -> HTTPResponse {
        let object: [String: Any] = ["error": ["code": status, "message": message,
                                               "errors": [["reason": reason, "domain": "global", "message": message]]]]
        return FakeHTTPTransport.json(status, object, headers: headers)
    }
}
