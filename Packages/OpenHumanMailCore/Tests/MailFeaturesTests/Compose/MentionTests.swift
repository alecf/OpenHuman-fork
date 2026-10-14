import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private func address(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }

@Suite struct MentionTriggerTests {
    @Test func opensAfterTheTriggerAtAWordStart() {
        #expect(MentionTrigger.pending(in: "@pj", caret: 3)?.query == "pj")
        #expect(MentionTrigger.pending(in: "@pj", caret: 3)?.range == 0..<3)
        #expect(MentionTrigger.pending(in: "Hi +dana", caret: 8)?.query == "dana")
        #expect(MentionTrigger.pending(in: "Hi +dana", caret: 8)?.range == 3..<8)
        #expect(MentionTrigger.pending(in: "line\n@sam", caret: 9)?.range == 5..<9)
        #expect(MentionTrigger.pending(in: "(@sam", caret: 5)?.query == "sam")
        #expect(MentionTrigger.pending(in: "ask @o'neil-ruiz.", caret: 17)?.query == "o'neil-ruiz.")
    }

    @Test func plusIsTheSameAsAt() {
        let at = MentionTrigger.pending(in: "x @lee", caret: 6)
        let plus = MentionTrigger.pending(in: "x +lee", caret: 6)
        #expect(at?.query == plus?.query && at?.range == plus?.range)
    }

    @Test func aBareTriggerHasAnEmptyQuery() {
        #expect(MentionTrigger.pending(in: "a @", caret: 3)?.query == "")
    }

    @Test func neverInsideAnAddressOrMidWord() {
        #expect(MentionTrigger.pending(in: "me@ab", caret: 5) == nil)
        #expect(MentionTrigger.pending(in: "1+2", caret: 3) == nil)
        #expect(MentionTrigger.pending(in: "a+b@c", caret: 5) == nil)
        #expect(MentionTrigger.pending(in: "word@x", caret: 6) == nil)
        #expect(MentionTrigger.pending(in: "@@x", caret: 3) == nil)
    }

    @Test func endsAtASpaceNewlinePunctuationOrWhenTheCaretLeaves() {
        #expect(MentionTrigger.pending(in: "@pj ", caret: 4) == nil)
        #expect(MentionTrigger.pending(in: "@pj\n", caret: 4) == nil)
        #expect(MentionTrigger.pending(in: "@pj,", caret: 4) == nil)
        #expect(MentionTrigger.pending(in: "@pj and more", caret: 12) == nil)
        #expect(MentionTrigger.pending(in: "hello", caret: 5) == nil)
        #expect(MentionTrigger.pending(in: "", caret: 0) == nil)
        #expect(MentionTrigger.pending(in: "@pj", caret: 9) == nil)
    }

    @Test func caretInTheMiddleOfTheQueryUsesTheTextBeforeIt() {
        let found = MentionTrigger.pending(in: "@dana tomorrow", caret: 3)
        #expect(found?.query == "da" && found?.range == 0..<3)
    }

    @Test func offsetsCountUTF16() {
        let found = MentionTrigger.pending(in: "😀 @zoë", caret: 7)
        #expect(found?.range == 3..<7 && found?.query == "zoë")
    }

    @Test func tooLongAQueryIsNotAMention() {
        let long = "@" + String(repeating: "a", count: MentionTrigger.maxQueryLength + 1)
        #expect(MentionTrigger.pending(in: long, caret: (long as NSString).length) == nil)
    }
}

@Suite struct MentionRankingTests {
    private let source = [
        address("operations@acme.example", "Pat Jones"),
        address("pat@acme.example", "Pat Jones"),
        address("pat@other.example", "Pat Jones"),
        address("sam@acme.example", "Sam Patel"),
        address("lee@acme.example", "Lee Ng"),
        address("pat@acme.example", "Pat Jones"),
    ]

    @Test func matchesAddressPrefixNameAndLaterNameWords() {
        let rows = MentionRanking.rank(source, query: "pat", limit: 10)
        #expect(rows.map(\.address.email) == ["operations@acme.example", "pat@acme.example", "pat@other.example",
                                              "sam@acme.example"])
        #expect(!rows.contains { $0.address.email == "lee@acme.example" })
    }

    @Test func theSamePersonAppearsOncePerAddress() {
        let rows = MentionRanking.rank(source, query: "pat", limit: 10)
        #expect(rows.filter { $0.displayName == "Pat Jones" }.count == 3)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func keepsTheSourceOrderForRecencyAndFrequency() {
        let rows = MentionRanking.rank(source.reversed(), query: "pat", limit: 10)
        #expect(rows.map(\.address.email) == ["pat@acme.example", "pat@other.example", "operations@acme.example",
                                              "sam@acme.example"])
    }

    @Test func typedPrefixOfTheAddressIsMarked() {
        let rows = MentionRanking.rank(source, query: "PAT", limit: 10)
        let pat = rows.first { $0.address.email == "pat@acme.example" }
        #expect(pat?.emailMatched == "pat" && pat?.emailRest == "@acme.example")
        let operations = rows.first { $0.address.email == "operations@acme.example" }
        #expect(operations?.emailMatched == "" && operations?.emailRest == "operations@acme.example")
    }

    @Test func ignoresCaseAndAccents() {
        let rows = MentionRanking.rank([address("zoe@acme.example", "Zoë Ruiz")], query: "zoe", limit: 5)
        #expect(rows.count == 1)
    }

    @Test func limitsAndDropsWhatDoesNotMatch() {
        #expect(MentionRanking.rank(source, query: "pat", limit: 2).count == 2)
        #expect(MentionRanking.rank(source, query: "zzz", limit: 5).isEmpty)
        #expect(MentionRanking.rank(source, query: "pat", limit: 0).isEmpty)
    }

    @Test func aContactWithoutANameShowsItsAddress() {
        let row = MentionRow(address: address("ops@acme.example"))
        #expect(row.displayName == "ops@acme.example")
    }
}

@Suite struct MentionEditTests {
    @Test func replacesOnlyTheTypedMentionWithTheFullName() throws {
        let result = try #require(MentionEdit.apply(to: "Thanks @pat, see you", replacing: 7..<11,
                                                    with: address("pat@acme.example", "Pat Jones")))
        #expect(result.text == "Thanks Pat Jones, see you")
        #expect(result.caret == 16)
    }

    @Test func quotedNamesLoseTheirQuotesAndNamelessContactsInsertTheAddress() {
        #expect(MentionEdit.insertedName(for: address("a@acme.example", "\"Lee Ng\"")) == "Lee Ng")
        #expect(MentionEdit.insertedName(for: address("a@acme.example", "  ")) == "a@acme.example")
    }

    @Test func aRangeThatNoLongerFitsChangesNothing() {
        #expect(MentionEdit.apply(to: "@p", replacing: 0..<5, with: address("p@acme.example", "P")) == nil)
    }
}

@MainActor
private final class UndoableEditor: ComposeTextEditing {
    var text: String
    var selection: Range<Int>
    let undo = UndoManager()
    init(session: ComposeSession, text: String) {
        self.text = text
        let end = (text as NSString).length
        selection = end..<end
        undo.groupsByEvent = false
        session.editor = self
    }

    var editorText: String { text }
    var editorSelection: Range<Int> { selection }
    var editorUndoManager: UndoManager? { undo }

    func replaceText(in range: Range<Int>, with new: String) -> Bool {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return false }
        set(ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: new))
        return true
    }

    private func set(_ new: String) {
        let old = text
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.set(old) }
        }
        text = new
    }

    func focusEditor() {}
    func placeCaret(at offset: Int) { selection = offset..<offset }
}

@MainActor @Suite struct MentionSessionTests {
    private func openRows(_ session: ComposeSession, query: String, in text: String, rows: [MentionRow]) {
        session.updateMention(in: text, caret: (text as NSString).length, mayOpen: true)
        session.mentionState.task?.cancel()
        session.showMentions(rows)
    }

    @Test func aPickInsertsTheFullNameAndAddsTheRecipientAsOneUndoStep() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "Hello @pat")
        let pat = address("pat@acme.example", "Pat Jones")
        openRows(session, query: "pat", in: editor.text, rows: [MentionRow(address: pat, matchedPrefixLength: 3)])
        let picker = try #require(session.mentionPicker)
        picker.confirm()
        #expect(editor.text == "Hello Pat Jones")
        #expect(editor.selection == 15..<15)
        #expect(session.to.tokens == [pat])
        #expect(session.mentionPicker == nil)
        editor.undo.undo()
        #expect(editor.text == "Hello @pat")
        #expect(session.to.tokens.isEmpty)
        editor.undo.redo()
        #expect(editor.text == "Hello Pat Jones")
        #expect(session.to.tokens == [pat])
    }

    @Test func anAddressAlreadyInAnyFieldIsNotAddedAgain() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let pat = address("pat@acme.example", "Pat Jones")
        session.to.accept(address("PAT@acme.example"))
        let editor = UndoableEditor(session: session, text: "+pat")
        openRows(session, query: "pat", in: editor.text, rows: [MentionRow(address: pat)])
        session.mentionPicker?.confirm()
        #expect(editor.text == "Pat Jones")
        #expect(session.to.tokens.count == 1)
        editor.undo.undo()
        #expect(editor.text == "+pat")
        #expect(session.to.tokens.count == 1, "the recipient that was there before stays")

        let other = try #require(f.compose.openNew(placement: .modal))
        other.cc.accept(pat)
        let second = UndoableEditor(session: other, text: "@pat")
        openRows(other, query: "pat", in: second.text, rows: [MentionRow(address: pat)])
        other.mentionPicker?.confirm()
        #expect(other.to.tokens.isEmpty && other.cc.tokens == [pat])
    }

    @Test func noRowsMeansNoPopup() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.showMentions([])
        #expect(session.mentionPicker == nil)
    }

    @Test func escapeKeepsTheTypedTextAndStaysClosedUntilANewTrigger() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "@pa")
        let row = MentionRow(address: address("pat@acme.example", "Pat Jones"))
        openRows(session, query: "pa", in: editor.text, rows: [row])
        #expect(session.mentionPicker != nil)
        session.dismissMention()
        #expect(session.mentionPicker == nil && editor.text == "@pa" && session.to.tokens.isEmpty)
        session.updateMention(in: "@pat", caret: 4, mayOpen: true)
        #expect(session.mentionPicker == nil && session.mentionState.dismissedStart == 0)
        session.updateMention(in: "@pat and", caret: 8, mayOpen: true)
        #expect(session.mentionState.dismissedStart == nil)
    }

    @Test func typingPastTheQueryClosesThePopup() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "@pa")
        openRows(session, query: "pa", in: editor.text, rows: [MentionRow(address: address("pat@acme.example", "Pat Jones"))])
        #expect(session.mentionPicker != nil)
        session.updateMention(in: "@pa ", caret: 4, mayOpen: false)
        #expect(session.mentionPicker == nil)
    }

    @Test func aStaleRangeDoesNotEditTheText() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "@pat")
        let pat = address("pat@acme.example", "Pat Jones")
        openRows(session, query: "pat", in: editor.text, rows: [MentionRow(address: pat)])
        editor.text = "x"
        session.mentionPicker?.confirm()
        #expect(editor.text == "x" && session.to.tokens.isEmpty)
    }

    @Test func rowsFoundForAnEarlierQueryAreNotPickedByTheKeyboard() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "@jo")
        openRows(session, query: "jo", in: editor.text, rows: [MentionRow(address: address("jo@acme.example", "Jo Sample"))])
        editor.text = "@john"
        session.updateMention(in: editor.text, caret: 5, mayOpen: true)
        session.mentionState.task?.cancel()
        let picker = try #require(session.mentionPicker)
        picker.confirm()
        #expect(editor.text == "@john" && session.to.tokens.isEmpty)
        let john = address("john@acme.example", "John Sample")
        session.showMentions([MentionRow(address: john)])
        session.mentionPicker?.confirm()
        #expect(editor.text == "John Sample" && session.to.tokens == [john])
    }

    @Test func aOneLetterOrHandleLikeQueryNeedsAHighlightMoveBeforeTheKeyboardPicks() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "follow @sample_co")
        let team = address("team@sampleco.example", "Sample Team")
        openRows(session, query: "sample_co", in: editor.text, rows: [MentionRow(address: team)])
        session.mentionPicker?.confirm()
        #expect(editor.text == "follow @sample_co" && session.to.tokens.isEmpty, "a handle stays as typed")
        session.mentionPicker?.moveCursor(by: 1)
        session.mentionPicker?.confirm()
        #expect(editor.text == "follow Sample Team" && session.to.tokens == [team], "after ↓ the keyboard picks")

        let other = try #require(f.compose.openNew(placement: .modal))
        let second = UndoableEditor(session: other, text: "@j")
        openRows(other, query: "j", in: second.text, rows: [MentionRow(address: address("jo@acme.example", "Jo Sample"))])
        other.mentionPicker?.confirm()
        #expect(second.text == "@j" && other.to.tokens.isEmpty, "one letter is not enough for ↵")
        let clicked = try #require(other.mentionPicker?.rows.first)
        other.mentionPicker?.choose(clicked)
        #expect(second.text == "Jo Sample", "a click always picks")
    }

    @Test func closingTheComposerTakesItsMentionOutOfTheWindowsUndo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "Hello @pat")
        let pat = address("pat@acme.example", "Pat Jones")
        openRows(session, query: "pat", in: editor.text, rows: [MentionRow(address: pat, matchedPrefixLength: 3)])
        session.mentionPicker?.confirm()
        #expect(session.to.tokens == [pat])
        f.compose.close(session)
        editor.undo.undo()
        #expect(session.to.tokens == [pat], "the closed draft's recipients are not edited by the window's undo")
    }

    @Test func aStepWhoseComposerIsGoneDoesNothing() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let editor = UndoableEditor(session: session, text: "Hello @pat")
        let pat = address("pat@acme.example", "Pat Jones")
        openRows(session, query: "pat", in: editor.text, rows: [MentionRow(address: pat, matchedPrefixLength: 3)])
        session.mentionPicker?.confirm()
        session.mentionState.undoBox.session = nil
        editor.undo.undo()
        #expect(editor.text == "Hello @pat", "the text half still undoes")
        #expect(session.to.tokens == [pat], "the step reached no session")
        #expect(MentionTrigger.keyMayPick(query: "pat", highlightMoved: false))
        #expect(!MentionTrigger.keyMayPick(query: "dev42", highlightMoved: false))
        #expect(MentionTrigger.keyMayPick(query: "p", highlightMoved: true))
    }

    @Test func theCursorMovesAndClamps() {
        let rows = (1...3).map { MentionRow(address: address("p\($0)@acme.example", "P\($0)")) }
        let picker = MentionPickerModel(rows: rows, onChoose: { _ in })
        picker.moveCursor(by: -1)
        #expect(picker.cursor == 0)
        picker.moveCursor(by: 1); picker.moveCursor(by: 1); picker.moveCursor(by: 1)
        #expect(picker.cursor == 2)
        picker.setRows(Array(rows.prefix(1)))
        #expect(picker.cursor == 0)
    }
}
