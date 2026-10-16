import AppKit
import MailFeatures
import MailRender

extension ComposerTextView {
    struct ListLine {
        let paragraph: NSRange
        let line: NSRange
        let content: Int
        let lists: [NSTextList]
        let quoted: Bool

        var hasMarker: Bool { content > line.location }
    }

    var autoListsOn: Bool { textFlags?.autoLists ?? true }

    func listLine(at location: Int) -> ListLine? {
        guard let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(max(location, 0), ns.length), length: 0))
        var line = paragraph
        while line.length > 0, Self.isParagraphBreak(ns.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        let inside = line.location < storage.length
        let style = inside ? storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle : nil
        let lists = style?.textLists ?? []
        let quoted = inside && storage.attribute(AttributedBridge.quoteKey, at: line.location, effectiveRange: nil) != nil
        let content = lists.isEmpty ? line.location : AttributedBridge.droppingMarker(line, in: ns).location
        return ListLine(paragraph: paragraph, line: line, content: content, lists: lists, quoted: quoted)
    }

    static func isParagraphBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D || c == 0x2029 }

    func autoListAfterSpace(openGroupsBeforeTyping: Int) {
        guard autoListsOn, !isPlainTextMode, let storage = textStorage else { return }
        let selection = selectedRange()
        guard selection.length == 0, let info = listLine(at: selection.location), info.lists.isEmpty, !info.quoted else {
            return
        }
        let text = (storage.string as NSString).substring(with: info.line)
        guard let trigger = AutoList.trigger(line: text, caret: selection.location - info.line.location, isQuoted: info.quoted,
                                             isSignature: false) else { return }
        let list = NSTextList(markerFormat: trigger.isOrdered ? .decimal : .disc, options: 0)
        list.startingItemNumber = trigger.start
        let style = bridge.paragraphStyle(lists: [list]) ?? NSMutableParagraphStyle()
        let marker = AttributedBridge.marker(list, number: trigger.start)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: info.paragraph))
        replacement.replaceCharacters(in: NSRange(location: 0, length: trigger.length),
                                      with: NSAttributedString(string: marker, attributes: bridge.typingAttributes))
        replacement.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: replacement.length))
        closeTypingUndoGroup(openGroupsBeforeTyping: openGroupsBeforeTyping)
        guard applyListEdit(info.paragraph, replacement, caret: info.line.location + (marker as NSString).length) else { return }
        typingAttributes = listTypingAttributes(style, quoted: false)
    }

    // A space that started new typing opened this event's undo group; closing it makes the conversion its own Undo step
    func closeTypingUndoGroup(openGroupsBeforeTyping: Int) {
        guard let manager = undoManager, manager.groupsByEvent, openGroupsBeforeTyping == 0, manager.groupingLevel == 1,
              !manager.isUndoing, !manager.isRedoing else { return }
        manager.endUndoGrouping()
    }

    func autoListReturn() -> Bool {
        guard autoListsOn, !hasMarkedText(), let storage = textStorage else { return false }
        let selection = selectedRange()
        guard selection.length == 0, let info = listLine(at: selection.location) else { return false }
        if isPlainTextMode {
            let text = (storage.string as NSString).substring(with: info.line)
            let signature = AutoList.isInSignature(storage.string, lineStart: info.line.location)
            guard let edit = AutoList.plainReturn(line: text, caret: selection.location - info.line.location,
                                                  isQuoted: AutoList.isQuotedLine(text), isSignature: signature)
            else { return false }
            return applyPlainListEdit(edit, info: info)
        }
        guard let level = info.lists.last, selection.location >= info.content else { return false }
        let content = (storage.string as NSString).substring(with: NSRange(location: info.content,
                                                                           length: NSMaxRange(info.line) - info.content))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            if info.lists.count > 1 {
                changeListLevel(outdent: true)
                return true
            }
            return removeListMarker(info)
        }
        let number = itemNumber(info)
        let style = storage.attribute(.paragraphStyle, at: info.line.location, effectiveRange: nil) as? NSParagraphStyle
        let insertion = NSAttributedString(string: "\n" + AttributedBridge.marker(level, number: number + 1),
                                           attributes: listTypingAttributes(style, quoted: info.quoted))
        let followers = AttributedBridge.isOrdered(level) ? siblings(after: info) : []
        let end = followers.last.map { NSMaxRange($0.paragraph) } ?? selection.location
        let affected = NSRange(location: selection.location, length: end - selection.location)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: affected))
        for (offset, follower) in followers.enumerated().reversed() {
            renumber(follower, list: level, number: number + 2 + offset, in: replacement, base: affected.location)
        }
        replacement.insert(insertion, at: 0)
        return applyListEdit(affected, replacement, caret: selection.location + insertion.length)
    }

    func autoListBackspace() -> Bool {
        guard autoListsOn, !hasMarkedText(), let storage = textStorage else { return false }
        let selection = selectedRange()
        guard selection.length == 0, let info = listLine(at: selection.location) else { return false }
        if isPlainTextMode {
            let text = (storage.string as NSString).substring(with: info.line)
            guard let edit = AutoList.plainBackspace(line: text, caret: selection.location - info.line.location,
                                                     isQuoted: AutoList.isQuotedLine(text),
                                                     isSignature: AutoList.isInSignature(storage.string,
                                                                                         lineStart: info.line.location))
            else { return false }
            return applyPlainListEdit(edit, info: info)
        }
        guard !info.lists.isEmpty, info.hasMarker, selection.location == info.content else { return false }
        if info.lists.count > 1 {
            changeListLevel(outdent: true)
            return true
        }
        return removeListMarker(info)
    }

    func autoListTab(outdent: Bool) -> Bool {
        guard autoListsOn, !hasMarkedText(), let storage = textStorage else { return false }
        let selection = selectedRange()
        guard let info = listLine(at: selection.location) else { return false }
        if isPlainTextMode {
            guard selection.length == 0 else { return false }
            let text = (storage.string as NSString).substring(with: info.line)
            guard let edit = AutoList.plainTab(line: text, caret: selection.location - info.line.location, outdent: outdent,
                                               isQuoted: AutoList.isQuotedLine(text),
                                               isSignature: AutoList.isInSignature(storage.string, lineStart: info.line.location))
            else { return false }
            return applyPlainListEdit(edit, info: info)
        }
        guard !info.lists.isEmpty else { return false }
        if !outdent, selection.length == 0, selection.location != info.content { return false }
        changeListLevel(outdent: outdent)
        return true
    }

    // The empty line after a final newline takes the previous character's style, which would make it a list item
    func keepTheLastEmptyLineOutOfLists() {
        guard autoListsOn, !hasMarkedText(), let storage = textStorage, storage.length > 0 else { return }
        let selection = selectedRange()
        guard selection.length == 0, selection.location == storage.length,
              Self.isParagraphBreak((storage.string as NSString).character(at: storage.length - 1)),
              let style = typingAttributes[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty else { return }
        let quoted = typingAttributes[AttributedBridge.quoteKey] != nil
        typingAttributes = listTypingAttributes(bridge.paragraphStyle(quoted: quoted) ?? NSMutableParagraphStyle(),
                                                quoted: quoted)
    }

    func removeListMarker(_ info: ListLine) -> Bool {
        guard let storage = textStorage, let level = info.lists.last else { return false }
        let followers = AttributedBridge.isOrdered(level) ? siblings(after: info) : []
        let end = followers.last.map { NSMaxRange($0.paragraph) } ?? NSMaxRange(info.paragraph)
        let affected = NSRange(location: info.paragraph.location, length: end - info.paragraph.location)
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: affected))
        for (offset, follower) in followers.enumerated().reversed() {
            renumber(follower, list: level, number: level.startingItemNumber + offset, in: replacement,
                     base: affected.location)
        }
        let style = bridge.paragraphStyle(quoted: info.quoted) ?? NSMutableParagraphStyle()
        replacement.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: info.paragraph.length))
        replacement.deleteCharacters(in: NSRange(location: 0, length: info.content - info.line.location))
        guard applyListEdit(affected, replacement, caret: info.line.location) else { return false }
        typingAttributes = listTypingAttributes(style, quoted: info.quoted)
        return true
    }

    func itemNumber(_ info: ListLine) -> Int {
        guard let storage = textStorage, let level = info.lists.last else { return 1 }
        let ns = storage.string as NSString
        var count = 0
        var location = info.paragraph.location
        while location > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: location - 1, length: 0))
            guard let line = listLine(at: previous.location), sharesLevels(line, with: info) else { break }
            if line.lists.count == info.lists.count { count += 1 }
            location = previous.location
        }
        return level.startingItemNumber + count
    }

    func siblings(after info: ListLine) -> [ListLine] {
        guard let storage = textStorage else { return [] }
        var found: [ListLine] = []
        var location = NSMaxRange(info.paragraph)
        while location < storage.length, let next = listLine(at: location), NSMaxRange(next.paragraph) > location,
              sharesLevels(next, with: info) {
            if next.lists.count == info.lists.count { found.append(next) }
            location = NSMaxRange(next.paragraph)
        }
        return found
    }

    func sharesLevels(_ line: ListLine, with info: ListLine) -> Bool {
        line.lists.count >= info.lists.count && zip(line.lists, info.lists).allSatisfy { $0 === $1 }
    }

    func renumber(_ line: ListLine, list: NSTextList, number: Int, in text: NSMutableAttributedString, base: Int) {
        guard line.hasMarker else { return }
        let range = NSRange(location: line.line.location - base, length: line.content - line.line.location)
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return }
        let attrs = text.attributes(at: range.location, effectiveRange: nil)
        text.replaceCharacters(in: range, with: NSAttributedString(string: AttributedBridge.marker(list, number: number),
                                                                    attributes: attrs))
    }

    func listTypingAttributes(_ style: NSParagraphStyle?, quoted: Bool) -> [NSAttributedString.Key: Any] {
        var attrs = bridge.typingAttributes
        if let style { attrs[.paragraphStyle] = style }
        if quoted { attrs[AttributedBridge.quoteKey] = true }
        return attrs
    }

    func applyPlainListEdit(_ edit: AutoList.PlainEdit, info: ListLine) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let attrs = bridge.typingAttributes
        switch edit {
        case .newItem(let prefix):
            let caret = selectedRange().location
            let insertion = NSAttributedString(string: "\n" + prefix, attributes: attrs)
            return applyListEdit(NSRange(location: caret, length: 0), insertion, caret: caret + insertion.length)
        case .removeMarker(let length):
            return applyListEdit(NSRange(location: info.line.location, length: length), NSAttributedString(),
                                 caret: info.line.location)
        case .indent, .outdent:
            let current = ns.substring(with: info.line)
            let lines = Array(ns.substring(to: info.line.location).components(separatedBy: "\n").dropLast()) + [current]
            guard let old = AutoList.plainItem(current),
                  let text = AutoList.reindented(lines, at: lines.count - 1, outdent: edit == .outdent),
                  let new = AutoList.plainItem(text) else { return true }
            let prefix = (text as NSString).substring(to: new.prefixLength)
            let caret = selectedRange().location + new.prefixLength - old.prefixLength
            return applyListEdit(NSRange(location: info.line.location, length: old.prefixLength),
                                 NSAttributedString(string: prefix, attributes: attrs),
                                 caret: max(info.line.location + new.prefixLength, caret))
        }
    }

    @discardableResult
    func applyListEdit(_ range: NSRange, _ replacement: NSAttributedString, caret: Int) -> Bool {
        guard let storage = textStorage, range.location >= 0, NSMaxRange(range) <= storage.length else { return false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return false }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        AttributedBridge.uncapLineHeights(in: storage, range: NSRange(location: range.location, length: replacement.length))
        storage.endEditing()
        setSelectedRange(NSRange(location: min(max(caret, 0), storage.length), length: 0))
        didChangeText()
        return true
    }
}
