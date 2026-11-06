import Foundation
import Darwin

enum SendToService {
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    struct Failure: LocalizedError {
        let createdURLs: [URL]
        let failedSource: URL?
        let underlyingError: Error
        var errorDescription: String? {
            let error = underlyingError as NSError
            let cancelled = error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
            let reason = cancelled ? "Shortcut creation was cancelled." :
                "Could not create \(failedSource.map { "a shortcut for “\($0.lastPathComponent)”" } ?? "shortcuts"): \(error.localizedDescription)"
            guard !createdURLs.isEmpty else { return reason }
            return reason + " \(createdURLs.count) \(createdURLs.count == 1 ? "shortcut was" : "shortcuts were") created and kept."
        }
    }

    /// Synchronous; the caller runs this on a background queue. App-owned shortcut documents use
    /// Foundation bookmark metadata, not copies or symlinks. Completed shortcuts remain on later error
    /// or cancellation and are returned in Failure.createdURLs. Existing destination entries survive.
    static func createAliases(for sources: [URL], in destination: URL,
                              isCancelled: () -> Bool = { false }) throws -> [URL] {
        guard !sources.isEmpty else { return [] }
        var created: [URL] = []
        var currentSource: URL?
        do {
            try checkCancellation(isCancelled)
            guard destination.isFileURL, !destination.path.contains("\0") else { throw posix(EINVAL, destination) }
            let descriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw posix(errno, destination) }
            defer { close(descriptor) }
            let originalDestination = try identity(of: descriptor, at: destination)
            let stage = try AliasStage(parent: descriptor, parentURL: destination)
            defer { stage.cleanup() }
            let nameLimit = fpathconf(descriptor, _PC_NAME_MAX)
            guard nameLimit > 0 else { throw posix(ENAMETOOLONG, destination) }
            var seen = Set<String>()
            for source in sources {
                try checkCancellation(isCancelled)
                guard seen.insert(source.path).inserted else { continue }
                currentSource = source
                guard source.isFileURL, !source.path.contains("\0") else { throw posix(EINVAL, source) }
                let sourceIdentity = try identity(at: source, follow: false)
                // The document stores a bookmark reference, never the source's contents.
                let document = try AppShortcutDocument.data(for: source)
                try checkCancellation(isCancelled)
                guard try identity(at: source, follow: false) == sourceIdentity else { throw posix(ESTALE, source) }
                try validate(destination, descriptor: descriptor, expected: originalDestination)
                var stagedURL = try stage.prepareItem()
                try stage.writeDocument(document)
                var values = URLResourceValues(); values.hasHiddenExtension = true
                try stagedURL.setResourceValues(values)
                try stage.validateWrittenItem()
                try checkCancellation(isCancelled)
                guard try identity(at: source, follow: false) == sourceIdentity else { throw posix(ESTALE, source) }
                var published = false
                for attempt in 1...10_000 {
                    try checkCancellation(isCancelled)
                    try validate(destination, descriptor: descriptor, expected: originalDestination)
                    try stage.validateWrittenItem()
                    let name = try aliasName(for: aliasBaseName(for: source), attempt: attempt, maximumBytes: Int(nameLimit))
                    if renameatx_np(stage.descriptor, stage.itemName, descriptor, name, UInt32(RENAME_EXCL)) == 0 {
                        created.append(destination.appendingPathComponent(name))
                        stage.didPublish()
                        published = true
                        break
                    }
                    let code = errno
                    if code != EEXIST { throw posix(code, destination.appendingPathComponent(name)) }
                }
                guard published else { throw posix(EEXIST, destination) }
            }
            return created
        } catch {
            throw Failure(createdURLs: created, failedSource: currentSource, underlyingError: error)
        }
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CocoaError(.userCancelled) }
    }
    private static func validate(_ url: URL, descriptor: Int32, expected: AliasIdentity) throws {
        guard try identity(of: descriptor, at: url) == expected,
              try identity(at: url, follow: true) == expected else { throw posix(ESTALE, url) }
    }
    private static func aliasBaseName(for source: URL) -> String {
        let name = source.lastPathComponent
        guard name.isEmpty || name == "/" else { return name }
        // A volume root has no filename: `/` must never become an absolute renameat target.
        let displayName = FileManager.default.displayName(atPath: source.path)
        return displayName.isEmpty || displayName.contains("/") || displayName.contains("\0") ? "Volume" : displayName
    }
    private static func aliasName(for original: String, attempt: Int, maximumBytes: Int) throws -> String {
        guard !original.contains("/"), !original.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        let suffix = (attempt == 1 ? " - Shortcut" : " - Shortcut (\(attempt))") + "." + AppShortcutDocument.fileExtension
        let available = maximumBytes - suffix.utf8.count
        guard available > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        var stem = original.isEmpty ? "Item" : original
        while stem.utf8.count > available { stem.removeLast() }
        if stem.isEmpty { stem = "Item"; while stem.utf8.count > available { stem.removeLast() } }
        return stem + suffix
    }

    private struct AliasIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; type = value.st_mode & S_IFMT }
    }
    private static func identity(at url: URL, follow: Bool) throws -> AliasIdentity {
        var value = stat()
        let result = follow ? stat(url.path, &value) : lstat(url.path, &value)
        guard result == 0 else { throw posix(errno, url) }
        return AliasIdentity(value)
    }
    private static func identity(of descriptor: Int32, at url: URL) throws -> AliasIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posix(errno, url) }
        return AliasIdentity(value)
    }
    private static func posix(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }

    private final class AliasStage {
        let descriptor: Int32
        private let parent: Int32
        private let name: String
        private let url: URL
        private let ownIdentity: AliasIdentity
        private var itemIdentity: AliasIdentity?
        private(set) var itemName = ""

        init(parent: Int32, parentURL: URL) throws {
            self.parent = parent
            name = ".filemanager-alias-" + UUID().uuidString
            url = parentURL.appendingPathComponent(name, isDirectory: true)
            guard mkdirat(parent, name, 0o700) == 0 else { throw posix(errno, url) }
            descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                let code = errno
                // Remove only an empty directory; never recursively remove an unexpected entry.
                unlinkat(parent, name, AT_REMOVEDIR)
                throw posix(code, url)
            }
            do { ownIdentity = try identity(of: descriptor, at: url) }
            catch { close(descriptor); unlinkat(parent, name, AT_REMOVEDIR); throw error }
        }
        deinit { close(descriptor) }

        func prepareItem() throws -> URL {
            itemName = "item-" + UUID().uuidString
            let liveURL = try currentURL()
            let item = openat(descriptor, itemName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard item >= 0 else { throw posix(errno, liveURL.appendingPathComponent(itemName)) }
            defer { close(item) }
            itemIdentity = try identity(of: item, at: liveURL.appendingPathComponent(itemName))
            return liveURL.appendingPathComponent(itemName)
        }
        func writeDocument(_ data: Data) throws {
            guard let itemIdentity else { throw posix(ESTALE, url) }
            let item = openat(descriptor, itemName, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard item >= 0 else { throw posix(errno, url) }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            guard try identity(of: item, at: url) == itemIdentity else { throw posix(ESTALE, url) }
            try handle.write(contentsOf: data)
            try validateWrittenItem()
        }
        func validateWrittenItem() throws {
            guard let itemIdentity else { throw posix(ESTALE, url) }
            var value = stat()
            guard fstatat(descriptor, itemName, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  AliasIdentity(value) == itemIdentity else { throw posix(ESTALE, url) }
        }
        func didPublish() { itemIdentity = nil; itemName = "" }
        private func currentURL() throws -> URL {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw posix(errno, url) }
            let liveURL = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            guard try identity(at: liveURL, follow: false) == ownIdentity else { throw posix(ESTALE, liveURL) }
            return liveURL
        }
        func cleanup() {
            if !itemName.isEmpty, let itemIdentity {
                var item = stat()
                if fstatat(descriptor, itemName, &item, AT_SYMLINK_NOFOLLOW) == 0, AliasIdentity(item) == itemIdentity {
                    unlinkat(descriptor, itemName, 0)
                }
            }
            var stage = stat()
            if fstatat(parent, name, &stage, AT_SYMLINK_NOFOLLOW) == 0, AliasIdentity(stage) == ownIdentity {
                unlinkat(parent, name, AT_REMOVEDIR)
            }
        }
    }
}
