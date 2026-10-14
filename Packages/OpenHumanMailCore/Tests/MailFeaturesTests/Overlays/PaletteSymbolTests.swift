#if canImport(AppKit)
import AppKit
#endif
import MailActions
import Testing
@testable import MailFeatures

@MainActor
@Suite struct PaletteSymbolTests {
    @Test func everyCatalogActionHasARealSymbol() {
        for descriptor in ActionCatalog.all {
            let symbol = PaletteController.symbol(for: descriptor.id)
            #expect(!symbol.isEmpty, "\(descriptor.id) has no palette symbol")
            if descriptor.id != .commandPalette {
                #expect(symbol != "command", "\(descriptor.id) shows the placeholder ⌘")
            }
            #if canImport(AppKit)
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(descriptor.id): \(symbol)")
            #endif
        }
    }

    @Test func theDesignMapIsFollowed() {
        #expect(PaletteController.symbol(for: .move) == "folder")
        #expect(PaletteController.symbol(for: .reply) == "arrowshape.turn.up.left")
        #expect(PaletteController.symbol(for: .replyAll) == "arrowshape.turn.up.left.2")
        #expect(PaletteController.symbol(for: .forward) == "arrowshape.turn.up.right")
        #expect(PaletteController.symbol(for: .spam) == "xmark.octagon")
        #expect(PaletteController.symbol(for: .moveToInbox) == "tray.and.arrow.down")
        #expect(PaletteController.symbol(for: .goInbox) == "tray")
        #expect(PaletteController.symbol(for: .settingsPage("general")) == "gearshape")
        #expect(PaletteController.symbol(for: .themeAccent("blue")) == "paintpalette")
        #expect(PaletteController.symbol(for: ActionID("unknown.action")) == "", "unknown ids keep an empty slot")
    }

    #if canImport(AppKit)
    @Test func theRowSymbolsOutsideTheCatalogExist() {
        for symbol in ["sparkle", "magnifyingglass", "envelope", "tray", "tag", "bookmark", "person.crop.circle",
                       "rectangle.split.3x1", "bell", "clock"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }
    #endif
}
