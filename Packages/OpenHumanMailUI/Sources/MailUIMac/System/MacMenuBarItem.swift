import AppKit
import MailFeatures
import MailModel

@MainActor
public final class MacMenuBarItem: NSObject, MenuBarItemControlling {
    public static let shared = MacMenuBarItem()
    public static let imageName = "MenuBarTemplate"

    private var item: NSStatusItem?
    var handler: (@MainActor (MenuBarCommand) -> Void)?
    private(set) var threads: [MenuBarThreadItem] = []
    private var openThread: (@MainActor (ThreadKey) -> Void)?
    static let maxLineLength = 60

    override public init() {}

    public func show(_ handler: @escaping @MainActor (MenuBarCommand) -> Void) {
        self.handler = handler
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.icon()
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel(Self.accessibilityLabel(count: ""))
        }
        item.menu = makeMenu()
        self.item = item
    }

    public func setCount(_ label: String) {
        guard let button = item?.button else { return }
        button.title = label
        button.setAccessibilityLabel(Self.accessibilityLabel(count: label))
    }

    public func setThreads(_ items: [MenuBarThreadItem], open: @escaping @MainActor (ThreadKey) -> Void) {
        threads = items
        openThread = open
        item?.menu = makeMenu()
    }

    public func hide() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        handler = nil
        threads = []
        openThread = nil
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if !threads.isEmpty {
            let header = NSMenuItem(title: "Unread", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, thread) in threads.enumerated() {
                let entry = NSMenuItem(title: Self.line(thread), action: #selector(chooseThread(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index + 1
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }
        for command in MenuBarCommand.allCases {
            if command == .quit { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: MenuBarModel.title(command), action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = command.rawValue
            menu.addItem(entry)
        }
        return menu
    }

    static func line(_ thread: MenuBarThreadItem) -> String {
        let text = thread.detail.isEmpty ? thread.title : "\(thread.title): \(thread.detail)"
        return text.count > maxLineLength ? String(text.prefix(maxLineLength - 1)) + "…" : text
    }

    @objc func chooseThread(_ sender: NSMenuItem) {
        guard threads.indices.contains(sender.tag - 1) else { return }
        openThread?(threads[sender.tag - 1].key)
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = MenuBarCommand(rawValue: raw) else { return }
        handler?(command)
    }

    static func accessibilityLabel(count: String) -> String {
        count.isEmpty ? "OpenHuman Mail" : "OpenHuman Mail, \(count) unread"
    }

    static func icon() -> NSImage? {
        let image = NSImage(named: imageName)
            ?? NSImage(systemSymbolName: "envelope", accessibilityDescription: "OpenHuman Mail")
        image?.isTemplate = true
        return image
    }
}
