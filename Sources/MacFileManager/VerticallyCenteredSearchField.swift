import AppKit

/// The borderless search control is taller than a text line. Keep the label,
/// placeholder and native field editor on the same centered baseline.
final class VerticallyCenteredSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { VerticallyCenteredSearchFieldCell.self }
        set { }
    }
}

final class VerticallyCenteredSearchFieldCell: NSSearchFieldCell {
    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        searchTextRect(forBounds: bounds)
    }

    override func searchTextRect(forBounds bounds: NSRect) -> NSRect {
        var rect = super.searchTextRect(forBounds: bounds)
        let height = min(rect.height, cellSize(forBounds: bounds).height)
        rect.origin.y = bounds.midY - height / 2
        rect.size.height = height
        return rect
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: controlView,
                     editor: editor, delegate: delegate, start: start, length: length)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView,
                   editor: editor, delegate: delegate, event: event)
    }
}
