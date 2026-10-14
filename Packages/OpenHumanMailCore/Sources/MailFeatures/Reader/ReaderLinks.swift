import Foundation
import MailRender
import OpenHumanLinks

public enum ReaderLinkAction: Equatable, Sendable {
    case openInBrowser(URL)
    case compose(ComposePrefill)
    case inApp(MailLink)
    case unsupported

    public static let unsupportedText = "Link type not supported"

    public static func resolve(_ url: URL) -> ReaderLinkAction {
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard url.host?.isEmpty == false else { return .unsupported }
            return .openInBrowser(url)
        case "mailto":
            if case .success(let prefill) = MailtoLink.parse(url) { return .compose(prefill) }
            return .unsupported
        case "openhuman":
            if case .success(let link) = MailLinkParser.parse(url) { return .inApp(link) }
            return .unsupported
        default:
            return .unsupported
        }
    }

    @MainActor
    public func follow(with router: AppRouter) -> String? {
        switch self {
        case .openInBrowser:
            return nil
        case .compose(let prefill):
            let outcome = router.route(.compose(prefill))
            return outcome.handled ? nil : outcome.message
        case .inApp(let link):
            let outcome = router.route(link)
            return outcome.handled ? nil : outcome.message
        case .unsupported:
            return Self.unsupportedText
        }
    }
}
