import Foundation
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

enum WG {
    static let api = "https://gmail.googleapis.com/gmail/v1/users/me/"
    static let upload = "https://gmail.googleapis.com/upload/gmail/v1/users/me/"
    static let insertURL = upload + "messages?uploadType=multipart&internalDateSource=receivedTime"
    static let headers = ["Authorization": "Bearer test-access-token", "Accept": "application/json"]

    static var allowlist: WriteAllowlist {
        WriteAllowlist(accountHash: WriteAllowlist.accountHash("me@example.com"), threadIDs: ["t1"],
                       messageIDs: ["m1", "m2"], draftIDs: ["d1"],
                       labels: ["Label_T": "OpenHuman/Test", "Label_S": "OpenHuman/Snoozed"])
    }

    static func request(_ method: String, _ url: String, body: Data? = nil,
                        extraHeaders: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, url: URL(string: url)!, headers: headers.merging(extraHeaders) { _, new in new },
                    body: body)
    }

    static func json(_ method: String, _ url: String, _ object: Any, contentType: String = "application/json",
                     extraHeaders: [String: String] = [:]) -> HTTPRequest {
        request(method, url, body: try! JSONSerialization.data(withJSONObject: object),
                extraHeaders: ["Content-Type": contentType].merging(extraHeaders) { _, new in new })
    }

    static func jsonText(_ method: String, _ url: String, _ text: String) -> HTTPRequest {
        request(method, url, body: Data(text.utf8), extraHeaders: ["Content-Type": "application/json"])
    }

    static func upload(_ method: String, _ url: String, metadata: String, message: Data,
                       boundary: String = "oh_upload_0123456789abcdef", contentType: String? = nil,
                       metaHeaders: String = "Content-Type: application/json; charset=UTF-8",
                       messageHeaders: String = "Content-Type: message/rfc822", preamble: String = "",
                       epilogue: String = "\r\n", extraPart: String? = nil, newline: String = "\r\n") -> HTTPRequest {
        var body = Data((preamble + "--\(boundary)\(newline)\(metaHeaders)\(newline)\(newline)\(metadata)"
                         + "\(newline)--\(boundary)\(newline)\(messageHeaders)\(newline)\(newline)").utf8)
        body.append(message)
        if let extraPart {
            body.append(Data("\(newline)--\(boundary)\(newline)\(extraPart)".utf8))
        }
        body.append(Data("\(newline)--\(boundary)--\(epilogue)".utf8))
        return request(method, url, body: body,
                       extraHeaders: ["Content-Type": contentType ?? "multipart/related; boundary=\(boundary)"])
    }

    static let syntheticHeaders = [
        "From: OpenHuman Test <test@openhuman.invalid>",
        "To: me@example.com",
        "Subject: [OpenHuman test] run1 1",
        "Date: Sat, 10 Oct 2026 12:00:00 +0000",
        "Message-ID: <oh-test.run1.1@openhuman.invalid>",
    ]

    static func message(_ headerLines: [String], body: String = "Synthetic body.") -> Data {
        Data((headerLines + ["", body]).joined(separator: "\r\n").utf8)
    }

    static func message(replacing name: String, with line: String?) -> Data {
        var lines = syntheticHeaders.filter { !$0.lowercased().hasPrefix(name.lowercased() + ":") }
        if let line { lines.append(line) }
        return message(lines)
    }

    static var synthetic: Data {
        SyntheticThreads.message(runID: "run1", index: 1, to: "me@example.com",
                                 date: Date(timeIntervalSince1970: 1_790_000_000))
    }

    static func insert(labelIDs: [String] = ["Label_T", "INBOX", "UNREAD"], message: Data = synthetic,
                       url: String = insertURL) -> HTTPRequest {
        let meta = String(decoding: try! JSONSerialization.data(withJSONObject: ["labelIds": labelIDs]), as: UTF8.self)
        return upload("POST", url, metadata: meta, message: message)
    }

    static func guarded(_ allowlist: WriteAllowlist = allowlist,
                        handler: @escaping ScriptedTransport.Handler = { _ in genericResponse })
        -> (WriteGuard, ScriptedTransport, WriteAllowlistStore) {
        let inner = ScriptedTransport(handler)
        let store = WriteAllowlistStore(seed: allowlist)
        return (WriteGuard(wrapping: inner, allowlist: store), inner, store)
    }

    static var genericResponse: HTTPResponse {
        jsonResponse(200, ["id": "x1", "name": "OpenHuman/Generic", "threadId": "t1",
                           "message": ["id": "mx1", "threadId": "t1"]])
    }
}

func expectWriteRefused(_ request: HTTPRequest, _ label: String, allowlist: WriteAllowlist = WG.allowlist,
                        sourceLocation: SourceLocation = #_sourceLocation) async {
    let (guarded, inner, _) = WG.guarded(allowlist)
    let path = request.url.path(percentEncoded: true)
    let payload = "\(request.method) \(path.isEmpty ? "/" : path)"
    await #expect(throws: TransportError.blockedBySafeMode(payload), "\(label)", sourceLocation: sourceLocation) {
        _ = try await guarded.send(request)
    }
    #expect(inner.requests.isEmpty, "\(label): a refused request reached the wrapped transport",
            sourceLocation: sourceLocation)
}

@discardableResult
func expectWriteAllowed(_ request: HTTPRequest, _ label: String, allowlist: WriteAllowlist = WG.allowlist,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws -> HTTPRequest? {
    let (guarded, inner, _) = WG.guarded(allowlist)
    do {
        _ = try await guarded.send(request)
    } catch {
        Issue.record("\(label): refused (\(error))", sourceLocation: sourceLocation)
        return nil
    }
    #expect(inner.requests.count == 1, "\(label)", sourceLocation: sourceLocation)
    return inner.requests.first
}

final class FakeGmailWire: HTTPTransport {
    let rest: FakeGmailTransport
    private let log = Mutex<[HTTPRequest]>([])

    init(_ gmail: FakeGmail) { rest = FakeGmailTransport(gmail) }

    var gmail: FakeGmail { rest.gmail }
    var requests: [HTTPRequest] { log.withLock { $0 } }
    var nonGETRequests: [HTTPRequest] { requests.filter { $0.method != "GET" } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path()
        guard path.hasPrefix("/upload/gmail/v1/users/me/") else {
            log.withLock { $0.append(request) }
            return try await rest.send(request)
        }
        log.withLock { $0.append(request) }
        guard case .success(let upload) = Upload.parse(request),
              let meta = try? JSONSerialization.jsonObject(with: upload.metadata) as? [String: Any] else {
            return jsonResponse(400, ["error": ["code": 400, "message": "bad upload"]])
        }
        let threadID = (meta["message"] as? [String: Any])?["threadId"] as? String
        do {
            switch (request.method, path) {
            case ("POST", "/upload/gmail/v1/users/me/messages"):
                return try ok(await gmail.insertMessage(rawRFC822: upload.message,
                                                        labelIDs: meta["labelIds"] as? [String] ?? []))
            case ("POST", "/upload/gmail/v1/users/me/drafts"):
                return try ok(await gmail.createDraft(rawRFC822: upload.message, threadID: threadID))
            case ("PUT", _) where path.hasPrefix("/upload/gmail/v1/users/me/drafts/"):
                let id = String(path.dropFirst("/upload/gmail/v1/users/me/drafts/".count))
                return try ok(await gmail.updateDraft(id: id, rawRFC822: upload.message, threadID: threadID))
            case ("POST", "/upload/gmail/v1/users/me/messages/send"):
                return try ok(await gmail.sendMessage(rawRFC822: upload.message, threadID: meta["threadId"] as? String))
            default:
                return jsonResponse(404, ["error": ["code": 404, "message": "no route"]])
            }
        } catch let error as GmailError {
            return jsonResponse(400, ["error": ["code": 400, "message": "\(error.code)"]])
        }
    }

    private func ok<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(value))
    }
}
