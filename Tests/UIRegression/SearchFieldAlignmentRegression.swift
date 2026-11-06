import AppKit

private struct SearchFieldAlignmentFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct SearchFieldAlignmentRegression {
    private static var checks = 0

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw SearchFieldAlignmentFailure(description: message) }
    }

    private static func renderedTextRows(in field: NSSearchField) -> ClosedRange<Int>? {
        guard let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return nil }
        field.cacheDisplay(in: field.bounds, to: bitmap)
        var first = bitmap.pixelsHigh, last = -1
        // Limit to the text at the leading edge so the native clear icon cannot
        // conceal a placeholder/text baseline regression.
        let textWidth = min(bitmap.pixelsWide, Int(140 * CGFloat(bitmap.pixelsWide) / field.bounds.width))
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<textWidth where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                first = min(first, y); last = max(last, y)
            }
        }
        return last >= first ? first...last : nil
    }

    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let field = VerticallyCenteredSearchField(frame: NSRect(x: 10, y: 10, width: 260, height: 27))
        field.isBezeled = false
        field.drawsBackground = false
        field.placeholderString = "Search DEV"
        let cell = field.cell as! NSSearchFieldCell
        cell.searchButtonCell = nil
        let native = NSSearchFieldCell(textCell: "")
        native.isBezeled = false
        native.searchButtonCell = nil

        for size: CGFloat in [13, 17, 20] {
            field.font = .systemFont(ofSize: size)
            native.font = field.font
            for height: CGFloat in [27, 36] {
                field.setFrameSize(NSSize(width: 260, height: height))
                for query in ["", "map", "a filename with a longer query"] {
                    field.stringValue = query
                    native.stringValue = query
                    let rect = cell.searchTextRect(forBounds: field.bounds)
                    let original = native.searchTextRect(forBounds: field.bounds)
                    try require(abs(rect.midY - field.bounds.midY) < 0.01,
                                "Placeholder and query must be vertically centered at font \(size), height \(height)")
                    try require(rect.minX == original.minX && rect.width == original.width,
                                "Centering must retain native search/cancel-button horizontal space")
                    try require(rect.height >= NSLayoutManager().defaultLineHeight(for: field.font!),
                                "The text line must not clip ascenders or descenders")
                    try require(cell.cancelButtonRect(forBounds: field.bounds) == native.cancelButtonRect(forBounds: field.bounds),
                                "Native clear-button position must stay unchanged")
                }
            }
        }

        field.font = .systemFont(ofSize: 17)
        field.setFrameSize(NSSize(width: 260, height: 27))
        field.stringValue = "map"
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 90),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(field)
        defer { window.close() }
        field.stringValue = ""
        let attachedTextRect = cell.searchTextRect(forBounds: field.bounds)
        try require(cell.drawingRect(forBounds: field.bounds) == attachedTextRect,
                    "Attached unfocused drawing must use the same centered rectangle as editing")
        guard let placeholderRows = renderedTextRows(in: field) else {
            throw SearchFieldAlignmentFailure(description: "Placeholder did not render in the attached search field")
        }
        let scale = field.bitmapImageRepForCachingDisplay(in: field.bounds)!.pixelsHigh / Int(field.bounds.height)
        let inkCenter = CGFloat(placeholderRows.lowerBound + placeholderRows.upperBound) / (2 * CGFloat(scale))
        try require(abs(inkCenter - field.bounds.midY) <= 1,
                    "Actual placeholder glyphs must be centered, not just their nominal text rectangle")
        field.stringValue = "Search DEV"
        guard let queryRows = renderedTextRows(in: field) else {
            throw SearchFieldAlignmentFailure(description: "Query did not render in the attached search field")
        }
        // Opaque text can gain a row of antialiased pixels on each edge compared
        // with the lighter placeholder, even when their baselines match.
        let queryCenter = CGFloat(queryRows.lowerBound + queryRows.upperBound) / (2 * CGFloat(scale))
        try require(abs(queryCenter - inkCenter) <= 0.5 / CGFloat(scale),
                    "Unfocused query text must render on the same baseline as the placeholder")
        try require(abs(queryRows.lowerBound - placeholderRows.lowerBound) <= 1 &&
                    abs(queryRows.upperBound - placeholderRows.upperBound) <= 1,
                    "Placeholder and query glyphs must match at both edges within one antialiased pixel")
        try require(cell.drawingRect(forBounds: field.bounds).width == attachedTextRect.width,
                    "Drawing must reserve the clear-button space exactly once")
        field.stringValue = "map"
        try require(window.makeFirstResponder(field), "Search field must accept keyboard focus")
        guard let editor = field.currentEditor() as? NSTextView else {
            throw SearchFieldAlignmentFailure(description: "Missing native search field editor")
        }
        let editorRect = editor.convert(editor.bounds, to: field)
        let textRect = cell.searchTextRect(forBounds: field.bounds)
        try require(abs(editorRect.midY - field.bounds.midY) < 0.01,
                    "Focused text and caret must share the centered display baseline")
        try require(editorRect == textRect, "The native field editor must occupy the search text rectangle")
        try require(editor.string == "map", "Focusing search must preserve its query")
        editor.selectedRange = NSRange(location: 3, length: 0)
        editor.insertText("x", replacementRange: editor.selectedRange)
        try require(editor.string == "mapx", "The centered editor must still accept native text insertion")
        field.setFrameSize(NSSize(width: 190, height: 27))
        window.contentView!.layoutSubtreeIfNeeded()
        try require(editor.convert(editor.bounds, to: field) == cell.searchTextRect(forBounds: field.bounds),
                    "Resizing a focused field must retain centering and clear-button space")
        try require(editor.selectedRange == NSRange(location: 4, length: 0),
                    "Resizing search must preserve the insertion point")
        window.makeFirstResponder(nil)
        try require(field.stringValue == "mapx", "Ending editing must commit the query")
        print("PASS: \(checks) search field alignment checks")
    }
}
