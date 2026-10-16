import Foundation
import Testing
@testable import MailFeatures

@Suite struct AutoListTests {
    func trigger(_ line: String, caret: Int? = nil, quoted: Bool = false, signature: Bool = false) -> AutoList.Trigger? {
        AutoList.trigger(line: line, caret: caret ?? (line as NSString).length, isQuoted: quoted, isSignature: signature)
    }

    @Test func aMarkerAndASpaceAtTheStartOfALineStartAList() {
        #expect(trigger("1. ") == AutoList.Trigger(marker: .number(1), length: 3))
        #expect(trigger("12. ") == AutoList.Trigger(marker: .number(12), length: 4))
        #expect(trigger("999. ")?.start == 999)
        #expect(trigger("- ") == AutoList.Trigger(marker: .bullet("-"), length: 2))
        #expect(trigger("* ") == AutoList.Trigger(marker: .bullet("*"), length: 2))
        #expect(trigger("3. ")?.isOrdered == true && trigger("3. ")?.start == 3, "numbering starts at the typed number")
        #expect(trigger("- ")?.isOrdered == false)
    }

    @Test func nothingElseIsATrigger() {
        #expect(trigger("1.") == nil, "no space yet")
        #expect(trigger("a. ") == nil)
        #expect(trigger("1) ") == nil)
        #expect(trigger("1234. ") == nil, "at most three digits")
        #expect(trigger("0. ") == nil)
        #expect(trigger("-- ") == nil)
        #expect(trigger("+ ") == nil)
        #expect(trigger(" - ") == nil, "not after a space")
        #expect(trigger("") == nil)
    }

    @Test func neverMidLine() {
        #expect(trigger("see 1. ") == nil)
        #expect(trigger("Hi - ") == nil)
        #expect(trigger("1. one", caret: 6) == nil, "the caret is past the marker")
        #expect(trigger("1. one", caret: 3)?.start == 1, "typed in front of existing text")
        #expect(trigger("1.  ", caret: 4) == nil)
    }

    @Test func neverInQuotedTextOrTheSignature() {
        #expect(trigger("1. ", quoted: true) == nil)
        #expect(trigger("- ", signature: true) == nil)
        #expect(AutoList.isQuotedLine("> - quoted"))
        #expect(!AutoList.isQuotedLine("- mine"))
        let text = "Hi\n-- \nSam\n- "
        let last = (text as NSString).length - 2
        #expect(AutoList.isInSignature(text, lineStart: last))
        #expect(!AutoList.isInSignature(text, lineStart: 3), "the delimiter line itself")
        #expect(!AutoList.isInSignature("Hi\n- ", lineStart: 3))
        #expect(AutoList.isInSignature("Hi\n--\nSam", lineStart: 6), "a delimiter whose space was trimmed")
        #expect(!AutoList.isInSignature("x", lineStart: 0))
    }

    @Test func protectedTextIsNeverATrigger() {
        #expect(ProtectedTextRanges.find(in: "- a@b.example").allSatisfy { $0.location >= 2 })
        #expect(trigger("- a@b.example", caret: 2) != nil, "an address after the marker is not touched")
    }

    @Test func returnContinuesTheListWithTheNextMarker() {
        #expect(AutoList.plainReturn(line: "1. one", caret: 6, isQuoted: false, isSignature: false) == .newItem("2. "))
        #expect(AutoList.plainReturn(line: "3. three", caret: 8, isQuoted: false, isSignature: false) == .newItem("4. "))
        #expect(AutoList.plainReturn(line: "- dash", caret: 6, isQuoted: false, isSignature: false) == .newItem("- "))
        #expect(AutoList.plainReturn(line: "* star", caret: 6, isQuoted: false, isSignature: false) == .newItem("* "))
        #expect(AutoList.plainReturn(line: "   1. nested", caret: 12, isQuoted: false, isSignature: false)
                == .newItem("   2. "), "keeps its indent")
        #expect(AutoList.plainReturn(line: "1. split here", caret: 8, isQuoted: false, isSignature: false) == .newItem("2. "))
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(AutoList.plainReturn(line: "2. ", caret: 3, isQuoted: false, isSignature: false) == .removeMarker(length: 3))
        #expect(AutoList.plainReturn(line: "- ", caret: 2, isQuoted: false, isSignature: false) == .removeMarker(length: 2))
        #expect(AutoList.plainReturn(line: "   - ", caret: 5, isQuoted: false, isSignature: false) == .outdent,
                "an empty nested item ends the nested list")
    }

    @Test func returnOutsideAListIsLeftAlone() {
        #expect(AutoList.plainReturn(line: "plain", caret: 5, isQuoted: false, isSignature: false) == nil)
        #expect(AutoList.plainReturn(line: "1. one", caret: 1, isQuoted: false, isSignature: false) == nil, "inside the marker")
        #expect(AutoList.plainReturn(line: "> 1. one", caret: 8, isQuoted: true, isSignature: false) == nil)
        #expect(AutoList.plainReturn(line: "- one", caret: 5, isQuoted: false, isSignature: true) == nil)
    }

    @Test func backspaceAtTheStartOfAnItemRemovesTheMarker() {
        #expect(AutoList.plainBackspace(line: "1. ", caret: 3, isQuoted: false, isSignature: false) == .removeMarker(length: 3))
        #expect(AutoList.plainBackspace(line: "- text", caret: 2, isQuoted: false, isSignature: false) == .removeMarker(length: 2))
        #expect(AutoList.plainBackspace(line: "  - text", caret: 4, isQuoted: false, isSignature: false) == .outdent)
        #expect(AutoList.plainBackspace(line: "- text", caret: 3, isQuoted: false, isSignature: false) == nil)
        #expect(AutoList.plainBackspace(line: "text", caret: 0, isQuoted: false, isSignature: false) == nil)
    }

    @Test func tabIndentsAtTheItemStartAndShiftTabOutdents() {
        #expect(AutoList.plainTab(line: "2. ", caret: 3, outdent: false, isQuoted: false, isSignature: false) == .indent)
        #expect(AutoList.plainTab(line: "2. two", caret: 5, outdent: false, isQuoted: false, isSignature: false) == nil)
        #expect(AutoList.plainTab(line: "2. two", caret: 5, outdent: true, isQuoted: false, isSignature: false) == .outdent)
        #expect(AutoList.plainTab(line: "two", caret: 0, outdent: false, isQuoted: false, isSignature: false) == nil)
    }

    @Test func numberingRestartsPerLevel() {
        let lines = ["1. one", "2. two", "3. three"]
        #expect(AutoList.reindented(lines, at: 2, outdent: false) == "   1. three", "nested under two, from 1")
        let deeper = ["1. one", "   1. a", "   2. b", "2. c"]
        #expect(AutoList.reindented(deeper, at: 3, outdent: false) == "   3. c", "joins the nested run")
        #expect(AutoList.reindented(deeper, at: 2, outdent: true) == "2. b", "back up: after one")
        #expect(AutoList.reindented(["1. one", "2. two"], at: 0, outdent: true) == nil, "already at the top")
        #expect(AutoList.reindented(["- a", "- b"], at: 1, outdent: false) == "  - b")
        #expect(AutoList.reindented(["x", "- b"], at: 1, outdent: false) == "  - b")
        #expect(AutoList.reindented(["plain"], at: 0, outdent: false) == nil)
    }

    @Test func plainItemsAreParsedWithTheirIndent() {
        let item = AutoList.plainItem("   12. twelve")
        #expect(item?.indent == 3 && item?.marker == .number(12) && item?.prefixLength == 7 && item?.content == "twelve")
        #expect(AutoList.plainItem("- ")?.isEmpty == true)
        #expect(AutoList.plainItem("-x") == nil)
        #expect(AutoList.Marker.number(9).next == .number(10))
        #expect(AutoList.Marker.bullet("*").next == .bullet("*"))
        #expect(AutoList.Marker.number(9).text == "9. " && AutoList.Marker.bullet("-").text == "- ")
    }
}
