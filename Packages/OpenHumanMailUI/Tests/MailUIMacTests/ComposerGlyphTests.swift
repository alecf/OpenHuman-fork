import AppKit
import Testing
@testable import MailUI

struct ComposerGlyphTests {
    @Test func theAIGlyphsSymbolsExist() {
        #expect(AIWordButton.pencilSymbol == "pencil" && AIWordButton.sparkleSymbol == "sparkle")
        for name in [AIWordButton.pencilSymbol, AIWordButton.sparkleSymbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is an SF Symbol here")
        }
    }
}
