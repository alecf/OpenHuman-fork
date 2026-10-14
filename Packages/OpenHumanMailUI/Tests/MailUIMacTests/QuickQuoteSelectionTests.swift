import AppKit
import Testing
@testable import MailUIMac

@MainActor
@Suite struct QuickQuoteSelectionTests {
    @Test func selectionReportsAreStringsCutToTheLimit() {
        #expect(SelectionMessageRouter.parse(42) == nil)
        #expect(SelectionMessageRouter.parse(["text": "x"]) == nil)
        #expect(SelectionMessageRouter.parse("a selected line") == "a selected line")
        let long = String(repeating: "x", count: ReaderWebKit.maxSelection + 10)
        #expect(SelectionMessageRouter.parse(long)?.count == ReaderWebKit.maxSelection)
        #expect(ReaderWebKit.selectionScript.contains(ReaderWebKit.selectionHandlerName))
    }

    @Test func printingFitsThePageWidth() {
        let info = ConversationPrinter.printInfo()
        #expect(info.horizontalPagination == .fit && info.verticalPagination == .automatic)
    }
}
