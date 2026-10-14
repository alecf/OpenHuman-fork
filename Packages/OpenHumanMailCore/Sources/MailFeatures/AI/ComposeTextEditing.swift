import Foundation

@MainActor
public protocol ComposeTextEditing: AnyObject {
    var editorText: String { get }
    var editorSelection: Range<Int> { get }
    func replaceText(in range: Range<Int>, with text: String) -> Bool
    func focusEditor()
    func placeCaret(at offset: Int)
    var isOnScreen: Bool { get }
    var editorUndoManager: UndoManager? { get }
}

extension ComposeTextEditing {
    public func placeCaret(at offset: Int) {}
    public var isOnScreen: Bool { true }
    public var editorUndoManager: UndoManager? { nil }

    func text(in range: Range<Int>) -> String? {
        let text = editorText as NSString
        guard range.lowerBound >= 0, range.upperBound <= text.length else { return nil }
        return text.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    var fullRange: Range<Int> { 0..<(editorText as NSString).length }
}
