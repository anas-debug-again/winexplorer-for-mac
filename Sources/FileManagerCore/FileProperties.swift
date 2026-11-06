import Foundation
import Darwin

public enum FilePropertyKind: String, Sendable {
    case regularFile, directory, symbolicLink, socket, characterDevice, blockDevice, fifo, other

    fileprivate init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFREG: self = .regularFile
        case S_IFDIR: self = .directory
        case S_IFLNK: self = .symbolicLink
        case S_IFSOCK: self = .socket
        case S_IFCHR: self = .characterDevice
        case S_IFBLK: self = .blockDevice
        case S_IFIFO: self = .fifo
        default: self = .other
        }
    }
}

/// Metadata for the directory entry itself. A symbolic link is never replaced by its target.
/// Owner and group IDs are deliberately numeric: resolving account names can contact directory services.
public struct FilePropertySnapshot: Sendable {
    public let url: URL
    public var name: String { url.lastPathComponent }
    public var path: String { url.path }
    public var locationURL: URL { url.deletingLastPathComponent() }
    public var pathExtension: String { url.pathExtension }
    public let kind: FilePropertyKind
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let created: Date
    public let modified: Date
    public let accessed: Date
    public let metadataChanged: Date
    public let ownerID: UInt32
    public let groupID: UInt32
    public let mode: UInt32
    public let flags: UInt32
    public let device: UInt64
    public let inode: UInt64
    /// Nine permission characters, including setuid, setgid and sticky-bit notation.
    public let permissions: String
    public let isHidden: Bool
    public let isLocked: Bool
    /// The stored target, which can be relative or nonexistent. This does not resolve the target.
    public let symbolicLinkTarget: String?
}

/// A bounded, best-effort metadata scan, not an atomic snapshot of a changing directory tree.
/// Files includes symbolic links and other non-directory entries; symbolicLinkCount is a subset.
/// Folders excludes selected top-level directory roots and includes their descendant directories.
/// Hidden entries are included. Overlapping roots are visited once. Hard-link directory entries
/// count separately, but their bytes count once. Logical and allocated bytes exclude directory
/// inode storage; allocated bytes are st_blocks * 512, not exclusive physical/APFS-clone usage.
public struct FilePropertyTotals: Sendable {
    public fileprivate(set) var logicalSize: Int64 = 0
    public fileprivate(set) var allocatedSize: Int64 = 0
    public fileprivate(set) var fileCount: Int = 0
    public fileprivate(set) var folderCount: Int = 0
    public fileprivate(set) var symbolicLinkCount: Int = 0
    /// Entries or directories whose metadata/contents could not be read, including changed entries.
    public fileprivate(set) var inaccessibleCount: Int = 0
    public fileprivate(set) var isCancelled = false
    /// An entry/depth limit or numeric overflow stopped the scan from producing complete totals.
    public fileprivate(set) var isTruncated = false
    public var isPartial: Bool { isCancelled || isTruncated || inaccessibleCount > 0 }
}

public enum FileProperties {
    /// Reads metadata only. Does not open file contents, follow the final symbolic link, or resolve accounts.
    public static func snapshot(for url: URL) throws -> FilePropertySnapshot {
        guard url.isFileURL else { throw propertiesError(EINVAL, url: url) }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw propertiesError(errno, url: url) }
        let kind = FilePropertyKind(mode: metadata.st_mode)
        let target = kind == .symbolicLink ? try linkTarget(at: url, metadata: metadata) : nil
        return FilePropertySnapshot(
            url: url, kind: kind,
            logicalSize: max(0, Int64(metadata.st_size)), allocatedSize: allocatedBytes(metadata),
            created: date(metadata.st_birthtimespec), modified: date(metadata.st_mtimespec),
            accessed: date(metadata.st_atimespec), metadataChanged: date(metadata.st_ctimespec),
            ownerID: metadata.st_uid, groupID: metadata.st_gid, mode: UInt32(metadata.st_mode),
            flags: metadata.st_flags, device: UInt64(UInt32(bitPattern: metadata.st_dev)),
            inode: metadata.st_ino, permissions: permissionString(metadata.st_mode),
            isHidden: url.lastPathComponent.hasPrefix(".") || metadata.st_flags & UInt32(UF_HIDDEN) != 0,
            isLocked: metadata.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0,
            symbolicLinkTarget: target)
    }

    /// Synchronous by design; call on a background queue. Cancellation is checked between every entry.
    /// Enumeration uses directory descriptors, no-follow child metadata, and identity checks before
    /// entering a directory, so replacing a child with a symbolic link cannot redirect recursion.
    /// At most maximumEntries entries and 128 directory levels are scanned. No file contents are read.
    public static func aggregate(urls: [URL], maximumEntries: Int = 250_000,
                                 cancellation: () -> Bool = { false }) -> FilePropertyTotals {
        withoutActuallyEscaping(cancellation) { callback in
            PropertyScanner(maximumEntries: max(0, maximumEntries), cancellation: callback).scan(urls)
        }
    }
}

private struct PropertyIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ metadata: stat) { device = metadata.st_dev; inode = metadata.st_ino }
}

private struct PropertyEntry: Hashable {
    let parent: PropertyIdentity?
    let name: String
    let fallbackPath: String?
}

private final class PropertyDirectoryCursor {
    let directory: UnsafeMutablePointer<DIR>
    let descriptor: Int32
    let identity: PropertyIdentity
    let url: URL
    let depth: Int

    init(directory: UnsafeMutablePointer<DIR>, descriptor: Int32, identity: PropertyIdentity,
         url: URL, depth: Int) {
        self.directory = directory; self.descriptor = descriptor; self.identity = identity
        self.url = url; self.depth = depth
    }

    deinit { closedir(directory) }
}

private final class PropertyScanner {
    private let maximumEntries: Int
    private let cancellation: () -> Bool
    private var totals = FilePropertyTotals()
    private var entries = Set<PropertyEntry>()
    private var directories = Set<PropertyIdentity>()
    private var sizedItems = Set<PropertyIdentity>()
    private var examinedEntries = 0

    init(maximumEntries: Int, cancellation: @escaping () -> Bool) {
        self.maximumEntries = maximumEntries
        self.cancellation = cancellation
    }

    func scan(_ urls: [URL]) -> FilePropertyTotals {
        // Parents precede selected descendants. Directory identities then remove overlap even when
        // two paths reach the same folder through an ancestor alias (for example /tmp and /private/tmp).
        let roots = urls.sorted { lhs, rhs in
            let leftDepth = lhs.pathComponents.count, rightDepth = rhs.pathComponents.count
            return leftDepth == rightDepth ? lhs.path < rhs.path : leftDepth < rightDepth
        }
        var rootPaths = Set<String>()
        for url in roots {
            if stopped { break }
            guard rootPaths.insert(url.path).inserted else { continue }
            guard reserveEntry() else { break }
            guard url.isFileURL else { totals.inaccessibleCount += 1; continue }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { totals.inaccessibleCount += 1; continue }
            var parent = stat()
            let parentIdentity = stat(url.deletingLastPathComponent().path, &parent) == 0 ? PropertyIdentity(parent) : nil
            let key = PropertyEntry(parent: parentIdentity, name: url.lastPathComponent,
                                    fallbackPath: parentIdentity == nil ? url.path : nil)
            if let directory = visit(url: url, metadata: metadata, key: key, parentDescriptor: nil,
                                     name: nil, depth: 0, isSelectedRoot: true) {
                enumerate(directory)
            }
        }
        return totals
    }

    private var stopped: Bool {
        if totals.isCancelled || totals.isTruncated { return true }
        if cancellation() { totals.isCancelled = true; return true }
        return false
    }

    private func reserveEntry() -> Bool {
        guard examinedEntries < maximumEntries else { totals.isTruncated = true; return false }
        examinedEntries += 1
        return true
    }

    private func visit(url: URL, metadata: stat, key: PropertyEntry, parentDescriptor: Int32?,
                       name: String?, depth: Int, isSelectedRoot: Bool) -> PropertyDirectoryCursor? {
        guard !stopped, !entries.contains(key) else { return nil }
        let identity = PropertyIdentity(metadata)
        let kind = FilePropertyKind(mode: metadata.st_mode)
        if kind == .directory, directories.contains(identity) { return nil }
        entries.insert(key)
        guard kind == .directory else {
            totals.fileCount += 1
            if kind == .symbolicLink { totals.symbolicLinkCount += 1 }
            if sizedItems.insert(identity).inserted {
                let logical = totals.logicalSize.addingReportingOverflow(max(0, Int64(metadata.st_size)))
                let allocated = totals.allocatedSize.addingReportingOverflow(allocatedBytes(metadata))
                totals.logicalSize = logical.overflow ? Int64.max : logical.partialValue
                totals.allocatedSize = allocated.overflow ? Int64.max : allocated.partialValue
                if logical.overflow || allocated.overflow { totals.isTruncated = true }
            }
            return nil
        }

        directories.insert(identity)
        if !isSelectedRoot { totals.folderCount += 1 }
        guard depth < 128 else { totals.isTruncated = true; return nil }
        let descriptor: Int32
        if let parentDescriptor, let name {
            descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { totals.inaccessibleCount += 1; return nil }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, PropertyIdentity(opened) == identity,
              FilePropertyKind(mode: opened.st_mode) == .directory else {
            close(descriptor); totals.inaccessibleCount += 1; return nil
        }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor); totals.inaccessibleCount += 1; return nil
        }
        return PropertyDirectoryCursor(directory: directory, descriptor: descriptor,
                                       identity: identity, url: url, depth: depth)
    }

    private func enumerate(_ root: PropertyDirectoryCursor) {
        // The stack lives on the heap. A deep tree must not exhaust the smaller stack of a
        // dispatch/Swift concurrency worker. Cursor destruction closes every held descriptor.
        var stack = [root]
        while !stopped, let cursor = stack.last {
            errno = 0
            guard let item = readdir(cursor.directory) else {
                if errno != 0 { totals.inaccessibleCount += 1 }
                stack.removeLast()
                continue
            }
            let childName = withUnsafePointer(to: item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if childName == "." || childName == ".." { continue }
            guard reserveEntry() else { break }
            var child = stat()
            guard fstatat(cursor.descriptor, childName, &child, AT_SYMLINK_NOFOLLOW) == 0 else {
                totals.inaccessibleCount += 1
                continue
            }
            let childKey = PropertyEntry(parent: cursor.identity, name: childName, fallbackPath: nil)
            if let directory = visit(url: cursor.url.appendingPathComponent(childName), metadata: child,
                                     key: childKey, parentDescriptor: cursor.descriptor, name: childName,
                                     depth: cursor.depth + 1, isSelectedRoot: false) {
                stack.append(directory)
            }
        }
    }

}

private func date(_ value: timespec) -> Date {
    Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
}

private func allocatedBytes(_ metadata: stat) -> Int64 {
    let (bytes, overflow) = max(0, Int64(metadata.st_blocks)).multipliedReportingOverflow(by: 512)
    return overflow ? Int64.max : bytes
}

private func permissionString(_ mode: mode_t) -> String {
    var result = Array("---------")
    let masks: [mode_t] = [S_IRUSR, S_IWUSR, S_IXUSR, S_IRGRP, S_IWGRP, S_IXGRP, S_IROTH, S_IWOTH, S_IXOTH]
    let letters = Array("rwxrwxrwx")
    for index in masks.indices where mode & masks[index] != 0 { result[index] = letters[index] }
    if mode & S_ISUID != 0 { result[2] = mode & S_IXUSR != 0 ? "s" : "S" }
    if mode & S_ISGID != 0 { result[5] = mode & S_IXGRP != 0 ? "s" : "S" }
    if mode & S_ISVTX != 0 { result[8] = mode & S_IXOTH != 0 ? "t" : "T" }
    return String(result)
}

private func linkTarget(at url: URL, metadata: stat) throws -> String {
    // readlink does not NUL-terminate. Grow for concurrent target changes, with a fixed upper bound.
    var capacity = max(256, Int(min(max(0, metadata.st_size), 1_048_575)) + 1)
    while capacity <= 1_048_576 {
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = readlink(url.path, &buffer, capacity)
        guard length >= 0 else { throw propertiesError(errno, url: url) }
        if length < capacity {
            var after = stat()
            guard lstat(url.path, &after) == 0 else { throw propertiesError(errno, url: url) }
            guard PropertyIdentity(after) == PropertyIdentity(metadata),
                  FilePropertyKind(mode: after.st_mode) == .symbolicLink,
                  after.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec else {
                throw propertiesError(ESTALE, url: url)
            }
            return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        capacity *= 2
    }
    throw propertiesError(ENAMETOOLONG, url: url)
}

private func propertiesError(_ code: Int32, url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
}
