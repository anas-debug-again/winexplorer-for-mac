import AppKit

/// Cut intent belongs to the clipboard, so it survives moving between app windows.
final class FileClipboardState: NSObject {
    static let didChange = Notification.Name("FileManagerFileClipboardChanged")
    private static var states: [NSPasteboard.Name: FileClipboardState] = [:]
    static func shared(for pasteboard: NSPasteboard) -> FileClipboardState {
        if let state = states[pasteboard.name] { return state }
        let state = FileClipboardState()
        states[pasteboard.name] = state
        return state
    }
    var urls: [URL] = []
    var isCut = false
    var changeCount = -1
    var runningCutChanges = Set<Int>()

    func refresh(from pasteboard: NSPasteboard) {
        guard changeCount != pasteboard.changeCount, isCut else { return }
        urls = []; isCut = false; changeCount = -1
        notify()
    }
    func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
