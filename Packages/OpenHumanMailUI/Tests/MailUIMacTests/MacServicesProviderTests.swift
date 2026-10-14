import AppKit
import MailModel
import Testing
@testable import MailUIMac

@MainActor
struct MacServicesProviderTests {
    @MainActor final class Received {
        var requests: [ServiceRequest] = []
    }

    func provider(_ received: Received) -> MacServicesProvider {
        let provider = MacServicesProvider(installer: { _ in })
        provider.register { received.requests.append($0) }
        return provider
    }

    func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        fill(board)
        return board
    }

    @Test func eachEntryHandsOneRequestOverAndTextStaysPlain() {
        let received = Received()
        let provider = provider(received)
        let text = pasteboard { $0.setString("<b>Hello</b>\nfrom Safari", forType: .string) }
        defer { text.releaseGlobally() }
        var error: NSString?
        provider.newMessageWithSelection(text, userData: nil, error: &error)
        provider.searchWithSelection(text, userData: nil, error: &error)
        #expect(received.requests == [.newMessage("<b>Hello</b>\nfrom Safari"), .search("<b>Hello</b>\nfrom Safari")])
        #expect(error == nil)
    }

    @Test func filesComeAsFileURLsOnly() throws {
        let received = Received()
        let provider = provider(received)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("services-\(UUID().uuidString).txt")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let files = pasteboard { $0.writeObjects([file as NSURL, URL(string: "https://example.com/x.pdf")! as NSURL]) }
        defer { files.releaseGlobally() }
        var error: NSString?
        provider.newMessageWithFiles(files, userData: nil, error: &error)
        guard case .attachFiles(let urls)? = received.requests.first else {
            Issue.record("no file request: \(received.requests)")
            return
        }
        #expect(received.requests.count == 1)
        #expect(urls.map(\.lastPathComponent) == [file.lastPathComponent], "the web URL is not a file")
        #expect(error == nil)
    }

    @Test func anEmptyOrWrongTypePasteboardSetsTheErrorString() {
        let received = Received()
        let provider = provider(received)
        let empty = pasteboard { _ in }
        defer { empty.releaseGlobally() }
        var error: NSString?
        provider.newMessageWithSelection(empty, userData: nil, error: &error)
        #expect(error as String? == MacServicesProvider.unreadableText)
        error = nil
        let text = pasteboard { $0.setString("not a file", forType: .string) }
        defer { text.releaseGlobally() }
        provider.newMessageWithFiles(text, userData: nil, error: &error)
        #expect(error as String? == MacServicesProvider.unreadableText)
        #expect(received.requests.isEmpty)
    }

    @Test func withoutAHandlerNothingIsDeliveredAndTheErrorSaysSo() {
        let provider = MacServicesProvider(installer: { _ in })
        let text = pasteboard { $0.setString("Hello", forType: .string) }
        defer { text.releaseGlobally() }
        var error: NSString?
        provider.newMessageWithSelection(text, userData: nil, error: &error)
        #expect(error as String? == MacServicesProvider.notReadyText)
    }

    @Test func registerAndUnregisterGoThroughTheInstaller() {
        let installed = Received()
        let provider = MacServicesProvider(installer: { installed.requests.append(.search($0 == nil ? "nil" : "set")) })
        provider.register { _ in }
        provider.unregister()
        #expect(installed.requests == [.search("set"), .search("nil")])
    }

    @Test func everyInfoPlistMessageIsAMethodOfTheProvider() {
        let provider = MacServicesProvider(installer: { _ in })
        for message in MacServicesProvider.messages {
            #expect(provider.responds(to: NSSelectorFromString("\(message):userData:error:")), "\(message)")
        }
    }
}
