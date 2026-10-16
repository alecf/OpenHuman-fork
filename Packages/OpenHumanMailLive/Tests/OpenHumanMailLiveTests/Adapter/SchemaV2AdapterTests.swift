import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanMailLive

private func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
    for try await value in stream { return value }
    return nil
}

@Test(.timeLimit(.minutes(1))) func aSnippetsRecipientsAndFilesMapWithTheirStoredCopy() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-v2-adapter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: dir), processKind: .test,
                                                appVersion: "0.0.0-test"))
    defer { try? store.close() }
    let stored = try store.storeSnippetAttachment(data: Data("synthetic guide".utf8), filename: "guide.txt", mimeType: "text/plain")
    let item = SnippetItem(id: "v2-s1", name: "Guide", bodyHTML: "<p>Guide</p>", variables: [], useCount: 0,
                           to: [EmailAddress(name: "Dana", email: "dana@example.com")],
                           cc: [EmailAddress(email: "team@example.com")], attachments: [stored])
    try store.upsertSnippet(item)

    let list = try #require(try await firstValue(MailStoreAdapter(store: store).snippets(nil)))
    let info = try #require(list.first { $0.id == "v2-s1" })
    #expect(info.to == item.to && info.cc == item.cc && info.bcc.isEmpty)
    let file = try #require(info.attachments.first)
    #expect(file.filename == "guide.txt" && file.size == stored.size && file.contentHash == stored.contentHash)
    let url = try #require(file.fileURL)
    #expect(url == store.location.snippetFileURL(stored))
    #expect(try Data(contentsOf: url) == Data("synthetic guide".utf8))
    #expect(MailStoreAdapter.snippetItem(info) == item)
}

@Test func aStoredBodysTextFormatReachesTheReader() {
    func content(_ format: BodyTextFormat) -> MessageContent {
        MailStoreAdapter.content(MessageBody(messageRowID: MessageRowID(rawValue: 1), text: "Soft \nbreak", hasRemoteContent: false,
                                             inlineParts: [:], decodeWarnings: [], textFormat: format))
    }
    #expect(content(.fixed).textFormat == .fixed)
    #expect(content(.flowed).textFormat == .flowed(delSp: false))
    #expect(content(.flowedDelSp).textFormat == .flowed(delSp: true))
}
