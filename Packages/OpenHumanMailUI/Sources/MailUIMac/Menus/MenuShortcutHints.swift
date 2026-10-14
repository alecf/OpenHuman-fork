import AppKit
import MailActions

@MainActor
public final class MenuShortcutHints {
    private var observer: (any NSObjectProtocol)?
    private let source: @MainActor () -> [ActionDescriptor]

    public init(descriptors: [ActionDescriptor] = ActionCatalog.all) {
        source = { descriptors }
    }

    public init(source: @escaping @MainActor () -> [ActionDescriptor]) {
        self.source = source
    }

    private var hints: [String: String] { Self.hints(for: source()) }

    static func hints(for descriptors: [ActionDescriptor]) -> [String: String] {
        var hints: [String: String] = [:]
        for descriptor in descriptors where descriptor.appearsInMenu {
            let equivalent = descriptor.menuKeyEquivalent
            let keys = descriptor.defaultBindings.filter { $0 != equivalent }.map(\.description)
            guard !keys.isEmpty else { continue }
            hints[descriptor.title] = keys.joined(separator: ", ")
        }
        return hints
    }

    public func install(center: NotificationCenter = .default) {
        guard observer == nil else { return }
        observer = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let main = NSApp.mainMenu else { return }
                self.apply(to: main)
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func apply(to menu: NSMenu) {
        apply(to: menu, hints: hints)
    }

    private func apply(to menu: NSMenu, hints: [String: String]) {
        let font: NSFont = menu.font ?? NSFont.menuFont(ofSize: 0)
        var width: CGFloat = 0
        for item in menu.items where hints[item.title] != nil {
            width = max(width, (item.title as NSString).size(withAttributes: [.font: font]).width)
        }
        for item in menu.items {
            if let submenu = item.submenu { apply(to: submenu, hints: hints) }
            guard let hint = hints[item.title], item.keyEquivalent.isEmpty else { continue }
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: width + 64)]
            let title = NSMutableAttributedString(string: item.title, attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: "\t" + hint, attributes: [
                .font: NSFont.menuFont(ofSize: font.pointSize), .paragraphStyle: style,
            ]))
            if item.attributedTitle?.string != title.string { item.attributedTitle = title }
        }
    }

    public func hint(for title: String) -> String? { hints[title] }
}
