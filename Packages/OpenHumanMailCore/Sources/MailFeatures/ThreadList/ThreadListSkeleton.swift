import Foundation

public enum ThreadListSkeleton {
    public static func shows(pagingFailed: Bool, visibleFor: Duration?, delay: Duration) -> Bool {
        !pagingFailed && (visibleFor ?? .zero) >= delay
    }
}
