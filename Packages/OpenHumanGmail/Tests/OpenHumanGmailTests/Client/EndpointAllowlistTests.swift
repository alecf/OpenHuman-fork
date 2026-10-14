import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct EndpointAllowlistTests {
    private func client(_ http: any HTTPTransport) -> GmailClient {
        let clock = InstantClock()
        return GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: http,
                           config: GmailClientConfig(userAgent: "t"), clock: clock, metrics: nil,
                           limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                           jitter: { 0 })
    }

    private static let expected: [String: GmailMethod] = [
        "getProfile": .getProfile, "listSendAs": .listSendAs, "listLabels": .listLabels, "getLabel": .getLabel,
        "createLabel": .createLabel, "listThreads": .listThreads, "getThread": .getThread,
        "trashThread": .trashThread, "untrashThread": .untrashThread, "listMessages": .listMessages,
        "getMessage": .getMessage, "getAttachment": .getAttachment, "batchModifyMessages": .batchModify,
        "modifyMessage": .modifyMessage, "trashMessage": .trashMessage, "untrashMessage": .untrashMessage,
        "sendMessage": .sendMessage, "listDrafts": .listDrafts, "getDraft": .getDraft, "createDraft": .createDraft,
        "updateDraft": .updateDraft, "deleteDraft": .deleteDraft, "sendDraft": .sendDraft,
        "listHistory": .listHistory, "insertMessage": .insertMessage,
        "getThreads": .getThread, "getMessages": .getMessage,
    ]

    private func protocolMethodNames() throws -> Set<String> {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/OpenHumanGmail/Contracts/GmailAPI.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let body = text.components(separatedBy: "public protocol GmailAPI").dropFirst().first?
            .components(separatedBy: "\n}\n").first ?? ""
        return Set(body.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("func "), let paren = trimmed.firstIndex(of: "(") else { return nil }
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<paren])
        })
    }

    @Test func everyGmailAPIMethodIsCoveredAndStaysOnTheAllowlist() async throws {
        let names = try protocolMethodNames()
        #expect(names.count == Self.expected.count, "GmailAPI methods: \(names.sorted())")
        #expect(names == Set(Self.expected.keys))

        let gmail = FakeGmail()
        let (message, thread) = await gmail.deliver(subject: "Synthetic", body: "hello")
        let wire = FakeGmailTransport(gmail)
        let c = client(wire)
        let raw = Data("To: you@example.com\r\nSubject: s\r\n\r\nbody".utf8)
        let draft = try await c.createDraft(rawRFC822: raw, threadID: nil)
        let sendable = try await c.createDraft(rawRFC822: raw, threadID: nil)
        let label = try await c.createLabel(name: "OpenHuman/Test", labelListVisibility: nil, messageListVisibility: nil)

        var calls: [String: () async throws -> Void] = [
            "getProfile": { _ = try await c.getProfile(priority: .sync) },
            "listSendAs": { _ = try await c.listSendAs() },
            "listLabels": { _ = try await c.listLabels() },
            "getLabel": { _ = try await c.getLabel(id: label.id) },
            "createLabel": { _ = try await c.createLabel(name: "OpenHuman/Other", labelListVisibility: nil, messageListVisibility: nil) },
            "listThreads": { _ = try await c.listThreads(ListQuery(), priority: .sync) },
            "getThread": { _ = try await c.getThread(id: thread, format: .full, metadataHeaders: [], priority: .sync) },
            "getThreads": { _ = try await c.getThreads(ids: [thread], format: .minimal, metadataHeaders: [], priority: .sync) },
            "trashThread": { _ = try await c.trashThread(id: thread) },
            "untrashThread": { _ = try await c.untrashThread(id: thread) },
            "listMessages": { _ = try await c.listMessages(ListQuery(), priority: .sync) },
            "getMessage": { _ = try await c.getMessage(id: message, format: .raw, metadataHeaders: [], priority: .sync) },
            "getMessages": { _ = try await c.getMessages(ids: [message], format: .minimal, metadataHeaders: [], priority: .sync) },
            "batchModifyMessages": { try await c.batchModifyMessages(ids: [message], add: ["STARRED"], remove: []) },
            "modifyMessage": { _ = try await c.modifyMessage(id: message, add: [], remove: ["UNREAD"]) },
            "trashMessage": { _ = try await c.trashMessage(id: message) },
            "untrashMessage": { _ = try await c.untrashMessage(id: message) },
            "sendMessage": { _ = try await c.sendMessage(rawRFC822: raw, threadID: nil) },
            "listDrafts": { _ = try await c.listDrafts(pageToken: nil, q: nil, maxResults: 10) },
            "getDraft": { _ = try await c.getDraft(id: draft.id, format: .full) },
            "createDraft": { _ = try await c.createDraft(rawRFC822: raw, threadID: nil) },
            "updateDraft": { _ = try await c.updateDraft(id: draft.id, rawRFC822: raw, threadID: nil) },
            "sendDraft": { _ = try await c.sendDraft(id: sendable.id) },
            "listHistory": { _ = try await c.listHistory(startHistoryID: HistoryID(1), pageToken: nil, types: [], labelID: nil,
                                                         maxResults: 10, priority: .sync) },
            "insertMessage": { _ = try await c.insertMessage(rawRFC822: raw, labelIDs: [label.id]) },
        ]
        calls["getAttachment"] = { _ = try? await c.getAttachment(messageID: message, attachmentID: "att1") }
        let throwaway = try await c.createDraft(rawRFC822: raw, threadID: nil)
        calls["deleteDraft"] = { try await c.deleteDraft(id: throwaway.id) }
        #expect(Set(calls.keys) == names)

        for name in calls.keys.sorted() {
            let before = wire.requests.count
            try await calls[name]!()
            let issued = Array(wire.requests.dropFirst(before))
            #expect(!issued.isEmpty, "\(name) sent nothing")
            let method = try #require(Self.expected[name])
            let endpoint = GmailEndpoints.endpoint(for: method)
            for request in issued {
                let path = request.url.path(percentEncoded: false)
                #expect(endpoint.matches(method: request.method, path: path), "\(name): \(request.method) \(path)")
                #expect(!GmailEndpoints.isForbidden(method: request.method, path: path), "\(name): \(request.method) \(path)")
            }
        }
    }

    @Test func everyMethodHasOneEndpointAndNoneIsForbidden() {
        var seen = Set<String>()
        for method in GmailMethod.allCases {
            let endpoint = GmailEndpoints.endpoint(for: method)
            let path = endpoint.template.replacingOccurrences(of: "{id}", with: "x")
            #expect(!GmailEndpoints.isForbidden(method: endpoint.httpMethod, path: path), "\(method)")
            #expect(seen.insert("\(endpoint.httpMethod) \(endpoint.template)").inserted, "duplicate endpoint for \(method)")
        }
        #expect(GmailMethod.allCases.filter { GmailEndpoints.endpoint(for: $0).httpMethod == "DELETE" } == [.deleteDraft])
    }

    @Test func forbiddenEndpointsAreRecognized() {
        let api = "/gmail/v1/users/me/"
        let forbidden: [(String, String)] = [
            ("DELETE", api + "messages/m1"), ("DELETE", api + "threads/t1"), ("DELETE", api + "labels/L1"),
            ("POST", api + "messages/batchDelete"), ("POST", api + "messages/m1/delete"),
            ("POST", api + "threads/t1/delete"), ("POST", api + "trash/empty"), ("POST", api + "spam/emptySpam"),
            ("POST", api + "settings/filters"), ("GET", api + "settings/filters"), ("DELETE", api + "settings/filters/f"),
            ("PUT", api + "settings/forwardingAddresses"), ("PUT", api + "settings/autoForwarding"),
            ("PUT", api + "settings/sendAs/a@example.com"), ("PATCH", api + "settings/sendAs/a@example.com"),
            ("POST", api + "settings/sendAs"), ("PUT", api + "settings/vacation"), ("PUT", api + "settings/imap"),
            ("PUT", api + "settings/delegates"), ("PUT", api + "labels/L1"), ("PATCH", api + "labels/L1"),
            ("POST", api + "watch"), ("POST", api + "stop"),
            ("POST", "/upload/gmail/v1/users/me/messages/import"), ("POST", api + "messages/import"),
        ]
        for (method, path) in forbidden { #expect(GmailEndpoints.isForbidden(method: method, path: path), "\(method) \(path)") }
        #expect(!GmailEndpoints.isForbidden(method: "GET", path: api + "settings/sendAs"))
        #expect(!GmailEndpoints.isForbidden(method: "DELETE", path: api + "drafts/d1"))
    }
}
