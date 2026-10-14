import Foundation
import OpenHumanGmail
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum SystemBrowserError: Error, Equatable, Sendable {
    case unsupportedURL
    case couldNotOpen
}

public struct SystemBrowser: ExternalBrowser {
    public init() {}

    public func open(_ url: URL) async throws {
        try Self.validate(url)
        #if os(macOS)
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        #else
        let opened = await Self.openOnMain(url)
        #endif
        guard opened else { throw SystemBrowserError.couldNotOpen }
    }

    #if !os(macOS)
    @MainActor private static func openOnMain(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }
    #endif

    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw SystemBrowserError.unsupportedURL
        }
    }
}
