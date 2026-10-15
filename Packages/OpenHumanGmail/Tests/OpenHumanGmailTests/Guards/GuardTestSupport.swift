import Foundation
import OpenHumanGmailTesting
import Synchronization
@testable import OpenHumanGmail

enum GmailRequests {
    static let api = "https://gmail.googleapis.com/gmail/v1/users/me/"
    static let upload = "https://gmail.googleapis.com/upload/gmail/v1/users/me/"
    static let headers = ["Authorization": "Bearer test-access-token", "Accept": "application/json"]

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

    static func message(_ headerLines: [String], body: String = "Synthetic body.") -> Data {
        Data((headerLines + ["", body]).joined(separator: "\r\n").utf8)
    }

    static var genericResponse: HTTPResponse {
        jsonResponse(200, ["id": "x1", "name": "OpenHuman/Generic", "threadId": "t1",
                           "message": ["id": "mx1", "threadId": "t1"]])
    }
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
