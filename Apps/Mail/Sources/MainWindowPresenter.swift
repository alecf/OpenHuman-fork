import AppKit
import SwiftUI

@MainActor
enum MainWindowPresenter {
    static var reopen: OpenWindowAction?

    static func show() {
        NSApp.activate()
        if let window = mainWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let reopen {
            reopen(id: DevFeedbackRuntime.mainWindowID)
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(DevFeedbackRuntime.mainWindowID) == true }
    }
}
