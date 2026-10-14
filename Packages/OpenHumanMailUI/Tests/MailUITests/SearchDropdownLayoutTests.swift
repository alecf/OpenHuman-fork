import CoreGraphics
import Testing
@testable import MailUI

struct SearchDropdownLayoutTests {
    let field = CGRect(x: 120, y: 10, width: 640, height: 32)

    @Test func itSitsUnderTheFieldAsWideAsIt() {
        let content = SearchDropdownLayout.contentHeight(rows: 4, headers: 1, interpretation: false, padding: 4)
        #expect(content == CGFloat(4 * 32 + 28 + 8))
        let frame = SearchDropdownLayout.frame(field: field, container: CGSize(width: 1100, height: 800), contentHeight: content,
                                               gap: 4, margin: 16)
        #expect(frame.minY == field.maxY + 4, "top-aligned directly under the field")
        #expect(frame.minX == field.minX && frame.width == field.width)
        #expect(frame.height == content, "all its rows fit")
        #expect(!frame.intersects(field), "never over the field")
    }

    @Test func escClosesTheDropDownBeforeTheModelsEsc() {
        var state = SearchDropdownState()
        #expect(state.shows(focused: true, hasContent: true))
        #expect(!state.shows(focused: false, hasContent: true), "only while the field has the keys")
        #expect(!state.shows(focused: true, hasContent: false), "nothing to show")
        let first = state.escape(showing: true)
        #expect(first, "the first Esc only closes the drop-down")
        #expect(!state.shows(focused: true, hasContent: true))
        let second = state.escape(showing: false)
        #expect(!second, "the second Esc goes to the model (clears the text)")
        #expect(!state.shows(focused: true, hasContent: true), "the cleared field's suggestions stay closed")
        let third = state.escape(showing: false)
        #expect(!third, "the third Esc goes to the model too (closes the field)")
        state.open()
        #expect(state.shows(focused: true, hasContent: true), "typing opens it again")
        let empty = state.escape(showing: false)
        #expect(!empty, "nothing showing (no suggestions): Esc is the model's at once")
    }

    @Test func aShortWindowLimitsItsHeightAndItScrolls() {
        let content = SearchDropdownLayout.contentHeight(rows: 8, headers: 3, interpretation: true, padding: 4)
        let container = CGSize(width: 1100, height: 300)
        let frame = SearchDropdownLayout.frame(field: field, container: container, contentHeight: content, gap: 4, margin: 16)
        #expect(frame.height < content)
        #expect(frame.maxY == container.height - 16, "it stops a margin above the window's bottom")
        let tiny = SearchDropdownLayout.frame(field: field, container: CGSize(width: 600, height: 60), contentHeight: content,
                                              gap: 4, margin: 16)
        #expect(tiny.height == SearchDropdownLayout.rowHeight)
    }
}
