import Foundation
import MailFeatures
import MailModel
import Observation

#if DEBUG || OH_DEV_TOOLS
enum PhoneLaunchScreen: String, CaseIterable {
    case inbox, reader, swipe, done, compose, search, mailboxes, settings, remind

    static let argument = "-OHScreen"

    static func current(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> PhoneLaunchScreen? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return PhoneLaunchScreen(rawValue: arguments[index + 1])
    }
}

extension PhoneMail {
    func show(_ screen: PhoneLaunchScreen) async {
        isRendering = true
        await PhoneObservation.wait { [weak self] in
            guard let list = self?.list else { return false }
            return list.state != .loading && !list.rows.isEmpty
        }
        guard let rows = list?.rows, let first = rows.first?.id else { return }
        let conversation = rows.first { $0.messageCount > 1 }?.id ?? first
        switch screen {
        case .inbox:
            break
        case .reader:
            open(conversation)
        case .swipe:
            heldSwipe = HeldSwipe(thread: first, offset: -150)
        case .done:
            done(first)
        case .compose:
            open(conversation)
            reply(all: true)
        case .search:
            openSearch()
            search.text = "invoice"
        case .mailboxes:
            showsMailboxes = true
        case .settings:
            showsSettings = true
        case .remind:
            askReminder(first)
        }
    }
}
#endif

@MainActor
enum PhoneObservation {
    static func wait(for condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = Once(continuation)
                withObservationTracking { _ = condition() } onChange: { once.resume() }
                if condition() { once.resume() }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func resume() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }
}
