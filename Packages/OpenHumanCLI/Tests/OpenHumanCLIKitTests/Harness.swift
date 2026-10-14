import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanCLIKit

let fixedNow = Date(timeIntervalSince1970: 1_791_651_483)

struct Run {
    var code: Int32
    var out: String
    var err: String

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] ?? [:]
    }
    var data: [String: Any] { json["data"] as? [String: Any] ?? [:] }
    var meta: [String: Any] { json["meta"] as? [String: Any] ?? [:] }
    var error: [String: Any] { json["error"] as? [String: Any] ?? [:] }
    var errorCode: String? { error["code"] as? String }
    func list(_ key: String) -> [[String: Any]] { data[key] as? [[String: Any]] ?? [] }
}

final class Harness: @unchecked Sendable {
    let directory: URL
    let store: MailStore
    let account: AccountID
    let email: String
    let clock = TestClock(now: fixedNow)

    init(email: String = "me@example.com", scopes: [String] = [GmailScope.modify], seed: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-cli-\(UUID().uuidString)", isDirectory: true)
        self.email = email
        store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test, appVersion: "test",
                                                changeNotificationName: "oh.test.cli.\(UUID().uuidString)"))
        account = try store.addAccount(email: email, displayName: "Me", scopes: scopes)
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels + [
            LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Clients", type: "user"),
            LabelUpsert(gmailLabelID: GmailLabelID("Label_2"), name: "OpenHuman/Snoozed", type: "user"),
        ], account: account, removeMissing: false)
        if seed { try seedMail() }
    }

    deinit { try? store.close(); try? FileManager.default.removeItem(at: directory) }

    func seedMail() throws {
        let body = MessageBodyUpsert.fixture(html: "<p>Invoice attached</p>", text: "Invoice attached")
        _ = try store.upsertMessages([
            .fixture("m1", thread: "t1", minutes: 1, labels: ["INBOX", "UNREAD", "Label_1"], from: "alice@example.com", fromName: "Alice Smith",
                     subject: "Invoice for October", snippet: "Please find the invoice", body: body),
            .fixture("m2", thread: "t1", minutes: 5, labels: ["INBOX", "UNREAD", "Label_1"], from: "bob@example.com", fromName: "Bob",
                     subject: "Re: Invoice for October", snippet: "Thanks"),
            .fixture("m3", thread: "t2", minutes: 3, labels: ["INBOX"], from: "carol@example.com", fromName: "Carol",
                     subject: "Lunch", snippet: "Noon?"),
            .fixture("m4", thread: "t3", minutes: 4, labels: ["INBOX", "STARRED", "UNREAD"], from: "dave@example.com", fromName: "Dave",
                     subject: "Roadmap", snippet: "Draft roadmap"),
        ], account: account, generation: 1)
    }

    let notification = "dev.openhuman.test.cli.\(UUID().uuidString)"
    var allowedEnvironment: [String: String] { ["OPENHUMAN_HOME": directory.path, "OPENHUMAN_STORE_NOTIFICATION": notification] }

    @discardableResult
    func run(_ arguments: [String], environment: [String: String] = [:], tty: Bool = false, stdinTTY: Bool = false,
             stdin: String = "", timeZone: String = "UTC", readLine: String? = nil, openURL: (@Sendable (URL) -> Void)? = nil) async -> Run {
        let out = BufferSink(), err = BufferSink()
        var variables = allowedEnvironment
        for (k, v) in environment { variables[k] = v }
        let env = CLIEnvironment(
            variables: variables, stdout: out, stderr: err, stdoutIsTTY: tty, stdinIsTTY: stdinTTY, clock: clock,
            timeZone: TimeZone(identifier: timeZone)!, nonce: { "3f9a1c" }, readStdin: { stdin }, readLine: { readLine },
            openURL: { url in openURL?(url) })
        let code = await OpenHumanCLI.run(arguments, environment: env)
        return Run(code: code, out: out.text, err: err.text)
    }

    static let write = ["OPENHUMAN_SAFE_MODE": "normal"]

    func operations(_ statuses: Set<OperationStatus> = [.pending, .inFlight, .succeeded, .failed, .cancelled]) throws -> [OperationItem] {
        try store.operations(account: account, statuses: statuses, limit: 500)
    }

    func holdLease() throws {
        _ = try store.acquireLease(account: account, ownerID: "test-app", kind: "app", pid: ProcessInfo.processInfo.processIdentifier,
                                   host: ProcessIdentity.localHostName, now: Date(), ttl: .seconds(45))
    }

    func threadRef(_ id: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(id)))
    }
}
