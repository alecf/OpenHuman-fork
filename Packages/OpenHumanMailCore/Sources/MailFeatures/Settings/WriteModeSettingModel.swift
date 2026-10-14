import Foundation
import Observation

@MainActor @Observable
public final class WriteModeSettingModel {
    public static let sectionTitle = "Changes to your mailbox"
    public static let title = "Allow changes to my mailbox (write mode)"
    public static let detail = "Changes were turned off on this Mac earlier. Turn this on so archive, star, labels, "
        + "snooze, read and unread, trash and send change your real mailbox every time Mail opens."

    public static let sheetTitle = "Allow changes to your mailbox?"
    public static let sheetPoints = [
        "Archive, star, labels, snooze, read and unread, trash, spam and send will change your real Gmail, everywhere "
            + "you read it.",
        "Permanent delete, emptying trash or spam, and Gmail settings such as filters and forwarding stay impossible.",
        "⌘Z undoes most changes. A sent message can be taken back only during its undo window.",
        "This applies every time Mail opens on this Mac.",
    ]
    public static let confirmTitle = "Allow Changes"
    public static let cancelTitle = "Cancel"

    public private(set) var isOn: Bool
    public var isShown: Bool { !isOn }
    public private(set) var isConfirming = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let port: any WriteModeSwitching

    public init(port: any WriteModeSwitching) {
        self.port = port
        isOn = port.allowsChanges
    }

    public func request(_ on: Bool) {
        guard on != isOn else { return }
        guard !on else {
            isConfirming = true
            return
        }
        guard save(false) else { return }
        if port.writesNow { port.reopen() }
    }

    public func confirm() {
        guard isConfirming else { return }
        isConfirming = false
        guard save(true) else { return }
        if port.launchSource == .setting, !port.writesNow { port.reopen() }
    }

    public func cancel() {
        isConfirming = false
    }

    public var status: String? {
        switch port.launchSource {
        case .environmentReadOnly:
            return "OPENHUMAN_SAFE_MODE is set and keeps this launch read-only. The switch applies when Mail opens "
                + "without it."
        case .environmentNormal:
            return "OPENHUMAN_SAFE_MODE=normal is set, so this launch can change your mailbox until you quit. The switch "
                + "applies when Mail opens without it."
        case .setting:
            return isOn && !port.writesNow ? "This window is read-only for now. Quit and open Mail again to allow changes."
                : nil
        }
    }

    private func save(_ value: Bool) -> Bool {
        do {
            try port.save(value)
            isOn = value
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't save the write mode choice. Nothing changed."
            return false
        }
    }
}
