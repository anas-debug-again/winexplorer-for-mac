import Foundation
import FileManagerCore

/// One catalog is shared by every window. Tests can redirect it without touching user folders.
enum BrowserSearchSupport {
    static let index: FilenameSearchIndex = {
        let override = ProcessInfo.processInfo.environment["FILE_MANAGER_SEARCH_INDEX_PATH"]
        let url = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? AppStorage.settingsURL.deletingLastPathComponent().appendingPathComponent("search-index.sqlite")
        return FilenameSearchIndex(databaseURL: url)
    }()
}
