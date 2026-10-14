import Foundation
import MailModel
import Observation

@MainActor @Observable
public final class LaunchAtLoginModel {
    public private(set) var status: LoginItemStatus
    public private(set) var errorMessage: String?
    @ObservationIgnored private let control: any LoginItemControlling

    public init(control: any LoginItemControlling) {
        self.control = control
        self.status = control.status()
    }

    public var isOn: Bool { status == .enabled || status == .requiresApproval }

    public var detail: String? {
        switch status {
        case .requiresApproval: "Needs approval in System Settings › General › Login Items."
        case .notFound: "Mail can't register itself from here. Move it to Applications and try again."
        case .enabled, .notRegistered: nil
        }
    }

    public var showsSettingsButton: Bool { status == .requiresApproval }

    public func refresh() {
        status = control.status()
    }

    public func setEnabled(_ on: Bool) {
        errorMessage = nil
        do {
            if on { try control.register() } else { try control.unregister() }
        } catch {
            errorMessage = on ? "Couldn't turn on Open at login." : "Couldn't turn off Open at login."
        }
        status = control.status()
    }

    public func openSystemSettings() { control.openSystemSettings() }
}
