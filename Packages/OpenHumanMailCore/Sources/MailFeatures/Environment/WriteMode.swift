import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor
@Observable
public final class WriteModeSession {
    public nonisolated static let confirmEverySend = AppSettingKey(name: "write_mode.confirm_every_send",
                                                                   defaultValue: false)
    public nonisolated static let allowChanges = AppSettingKey(name: "write_mode.allow_changes", defaultValue: true,
                                                               isSafetyKey: true)

    public init() {}
}

public enum WriteModeLaunchSource: Sendable, Equatable {
    case setting
    case environmentReadOnly
    case environmentNormal
}

@MainActor
public protocol WriteModeSwitching: AnyObject, Sendable {
    var allowsChanges: Bool { get }
    var launchSource: WriteModeLaunchSource { get }
    var writesNow: Bool { get }
    func save(_ allowsChanges: Bool) throws
    func reopen()
}
