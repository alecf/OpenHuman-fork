import AppKit
import MailModel

@MainActor
public final class MacServicesProvider: NSObject, ServicesRegistering {
    public static let shared = MacServicesProvider(installer: { provider in
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    })

    public static let messages = ["newMessageWithSelection", "newMessageWithFiles", "searchWithSelection"]
    public static let unreadableText = "Mail couldn't read the selection."
    public static let notReadyText = "Mail isn't ready yet. Open Mail and try again."

    private var handler: (@MainActor (ServiceRequest) -> Void)?
    private let installer: @MainActor (MacServicesProvider?) -> Void

    public init(installer: @escaping @MainActor (MacServicesProvider?) -> Void) {
        self.installer = installer
        super.init()
    }

    public func register(handler: @escaping @MainActor (ServiceRequest) -> Void) {
        self.handler = handler
        installer(self)
    }

    public func unregister() {
        handler = nil
        installer(nil)
    }

    @objc(newMessageWithSelection:userData:error:)
    public func newMessageWithSelection(_ pasteboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = Self.text(from: pasteboard) else { return fail(error, Self.unreadableText) }
        deliver(.newMessage(text), error: error)
    }

    @objc(newMessageWithFiles:userData:error:)
    public func newMessageWithFiles(_ pasteboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let files = Self.fileURLs(from: pasteboard) else { return fail(error, Self.unreadableText) }
        deliver(.attachFiles(files), error: error)
    }

    @objc(searchWithSelection:userData:error:)
    public func searchWithSelection(_ pasteboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = Self.text(from: pasteboard) else { return fail(error, Self.unreadableText) }
        deliver(.search(text), error: error)
    }

    // Plain text only, never HTML or RTF, whatever else the other app put on the pasteboard
    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return nil
        }
        return urls
    }

    private func deliver(_ request: ServiceRequest, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let handler else { return fail(error, Self.notReadyText) }
        handler(request)
    }

    private func fail(_ error: AutoreleasingUnsafeMutablePointer<NSString?>?, _ message: String) {
        error?.pointee = message as NSString
    }
}
