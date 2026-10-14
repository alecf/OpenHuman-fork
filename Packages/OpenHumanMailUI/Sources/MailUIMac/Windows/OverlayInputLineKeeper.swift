import AppKit

@MainActor
enum OverlayInputLineKeeper {
    private final class Watch {
        weak var field: NSTextField?
        var tokens: [NSObjectProtocol] = []
        var lastGood: NSRect?

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }

    private static let watches = NSMapTable<NSView, Watch>.weakToStrongObjects()
    private static var keeping = false

    static func watch(_ field: NSTextField) {
        guard let host = field.superview, watches.object(forKey: host) == nil else { return }
        let watch = Watch()
        watch.field = field
        let center = NotificationCenter.default
        host.postsFrameChangedNotifications = true
        field.postsFrameChangedNotifications = true
        let changed = NSView.frameDidChangeNotification
        watch.tokens.append(center.addObserver(forName: changed, object: host, queue: nil) { [weak host] _ in
            MainActor.assumeIsolated {
                if let host { keep(host) }
            }
        })
        watch.tokens.append(center.addObserver(forName: changed, object: field, queue: nil) { [weak host] _ in
            MainActor.assumeIsolated {
                guard !keeping, let host, let field = watches.object(forKey: host)?.field, field.superview === host,
                      host.frame.height == field.intrinsicContentSize.height else { return }
                keeping = true
                defer { keeping = false }
                fill(host, with: field)
            }
        })
        watches.setObject(watch, forKey: host)
        keep(host)
    }

    private static func keep(_ host: NSView) {
        guard !keeping, let watch = watches.object(forKey: host), let field = watch.field, field.superview === host
        else { return }
        let line = field.intrinsicContentSize.height
        let frame = host.frame
        guard line > 0, frame.width > 0 else { return }
        if frame.height == line {
            watch.lastGood = frame
            return
        }
        var target = NSRect(x: frame.minX, y: frame.midY - line / 2, width: frame.width, height: line)
        if let good = watch.lastGood, good.minX == frame.minX, good.width == frame.width, abs(good.midY - frame.midY) <= 1 {
            target = good
        } else if let superview = host.superview {
            target = superview.backingAlignedRect(target, options: .alignAllEdgesNearest)
        }
        keeping = true
        defer { keeping = false }
        host.frame = target
        fill(host, with: field)
        watch.lastGood = host.frame
    }

    private static func fill(_ host: NSView, with field: NSTextField) {
        let bounds = host.bounds
        guard field.frame.minY != bounds.minY || field.frame.height != bounds.height else { return }
        field.frame = NSRect(x: field.frame.minX, y: bounds.minY, width: field.frame.width, height: bounds.height)
    }
}
