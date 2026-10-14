import Foundation

public enum AutoLabelVisibility {
    private static let flag = LockedFlag(true)

    public static var showInGmail: Bool {
        get { flag.value }
        set { flag.value = newValue }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
}
