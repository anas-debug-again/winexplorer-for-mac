import Foundation
import Darwin

/// A bookmark document owned by WinExplorer for Mac. Unlike a Finder alias, Launch Services
/// opens this document in WinExplorer for Mac before any target is resolved or opened.
enum AppShortcutDocument {
    static let fileExtension = "fmlink"
    static let typeIdentifier = "local.filemanager.shortcut"
    static let maximumDocumentBytes = 1_048_576

    private struct Document: Codable {
        let format: String
        let version: Int
        let bookmark: Data
    }

    struct InvalidDocument: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Classification does not resolve the bookmark, so a broken target still shows as a shortcut.
    static func isShortcut(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
        return values?.isDirectory != true && values?.isSymbolicLink != true && values?.isAliasFile != true
    }

    static func data(for target: URL) throws -> Data {
        try validateLocalURL(target)
        guard try target.checkResourceIsReachable() else { throw CocoaError(.fileNoSuchFile) }
        let bookmark = try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let document = Document(format: typeIdentifier, version: 1, bookmark: bookmark)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard !bookmark.isEmpty, data.count <= maximumDocumentBytes else {
            throw InvalidDocument(reason: "The shortcut bookmark is too large to save.")
        }
        return data
    }

    /// Accept only bounded regular files and a known envelope; never execute document contents,
    /// resolve remote URL schemes, mount a drive, or present a bookmark-resolution dialog.
    static func resolve(_ url: URL) throws -> URL {
        try validateLocalURL(url)
        guard isShortcut(url) else { throw InvalidDocument(reason: "This is not a WinExplorer for Mac shortcut.") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError(url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError(url) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximumDocumentBytes else {
            throw InvalidDocument(reason: "The shortcut document is empty, too large, or is not a regular file.")
        }
        let data = try handle.read(upToCount: maximumDocumentBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw InvalidDocument(reason: "The shortcut document is empty or too large.")
        }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw InvalidDocument(reason: "The shortcut document is damaged or has an invalid format.") }
        guard document.format == typeIdentifier, document.version == 1, !document.bookmark.isEmpty else {
            throw InvalidDocument(reason: "This shortcut uses an unsupported format or version.")
        }
        var stale = false
        let target = try URL(resolvingBookmarkData: document.bookmark, options: [.withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        try validateLocalURL(target)
        guard try target.checkResourceIsReachable() else { throw CocoaError(.fileNoSuchFile) }
        return target.standardizedFileURL
    }

    private static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty, !url.path.contains("\0"),
              url.host == nil || url.host?.isEmpty == true || url.host?.lowercased() == "localhost" else {
            throw InvalidDocument(reason: "WinExplorer for Mac shortcuts can only refer to local filesystem items.")
        }
    }

    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
}
