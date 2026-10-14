import AppKit
import MailUI
import SwiftUI

struct WindowZoomMenuItem: View {
    var state = WindowZoomMenuState.shared

    var body: some View {
        Button(state.isZoomed ? "Return to default size" : "Zoom") {
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
            WindowZoomController.toggle(window)
        }
        .keyboardShortcut(WindowZoomCommands.shortcut)
        .disabled(!state.canZoom)
    }
}

public struct WindowZoomCommands: Commands {
    public static let shortcut = KeyboardShortcut("z", modifiers: [.control, .command])

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { (NSApp.keyWindow ?? NSApp.mainWindow)?.miniaturize(nil) }
                .keyboardShortcut("m", modifiers: .command)
            WindowZoomMenuItem()
        }
    }
}
