import Foundation

public enum FilenameSearchOrder: Equatable, Sendable {
    case name, bestMatch
}

/// Shared by indexed and current-folder searches. Ranking uses the same localized
/// match range as filtering, including case, accents, and expanded Unicode forms.
public enum FilenameSearchRanking {
    public static func rank(name: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        guard let range = name.localizedStandardRange(of: query) else { return nil }
        if range.lowerBound == name.startIndex {
            return range.upperBound == name.endIndex ? 0 : 1
        }
        return 2
    }

    public static func depth(path: String, root: String) -> Int {
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return Int.max }
        return path.dropFirst(prefix.count).utf8.reduce(0) { $1 == 47 ? $0 + 1 : $0 }
    }
}

/// An opt-in lexical filter: no filesystem reads and no loss of catalog entries.
/// Only components below the search root count, so opening a cache and searching
/// inside it remains useful. Generic names such as build, dist, and bin are kept.
public enum FilenameSearchFilter {
    private static let generated: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", ".swiftpm", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".nuxt", ".cache", ".gradle"
    ]
    private static let generatedSequences: [[String]] = [
        ["library", "caches"], ["library", "developer", "xcode", "deriveddata"],
        [".claude", "projects"], [".codex", "artifacts"], [".npm", "_cacache"], [".yarn", "cache"]
    ]
    private static let sequenceEndings = Set(generatedSequences.compactMap(\.last))

    /// Allows the query's bounded parent cache to reuse an ancestor decision for
    /// ordinary sibling filenames. Potential folder boundaries use includes again.
    public static func mayExcludeName(_ name: String) -> Bool {
        let component = name.lowercased()
        return generated.contains(component) || sequenceEndings.contains(component)
    }

    public static func includes(url: URL, in root: URL, excludeGenerated: Bool) -> Bool {
        includes(path: url.path, in: root.path, excludeGenerated: excludeGenerated)
    }

    public static func includes(path: String, in root: String, excludeGenerated: Bool) -> Bool {
        guard excludeGenerated else { return true }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return true }
        let components = path.dropFirst(prefix.count).split(separator: "/").map { $0.lowercased() }
        guard !components.contains(where: { generated.contains($0) }) else { return false }
        // A search starting in Library should still filter its Caches child, while
        // a search starting inside Library/Caches intentionally keeps its contents.
        let fullComponents = path.split(separator: "/").map { $0.lowercased() }
        let rootDepth = root.split(separator: "/").count
        for sequence in generatedSequences where fullComponents.count >= sequence.count {
            for offset in 0...(fullComponents.count - sequence.count) where offset + sequence.count > rootDepth {
                if fullComponents[offset..<(offset + sequence.count)].elementsEqual(sequence) { return false }
            }
        }
        return true
    }
}

public struct FilenameSearchEntry: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isAlias: Bool
    public let isHidden: Bool
    public init(url: URL, name: String? = nil, isDirectory: Bool = false, isPackage: Bool = false,
                isSymbolicLink: Bool = false, isAlias: Bool = false, isHidden: Bool = false) {
        self.url = url; self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory; self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink; self.isAlias = isAlias; self.isHidden = isHidden
    }
    var flags: Int32 {
        (isDirectory ? 1 : 0) | (isPackage ? 2 : 0) | (isSymbolicLink ? 4 : 0)
        | (isAlias ? 8 : 0) | (isHidden ? 16 : 0)
    }
    init(path: String, name: String, flags: Int32) {
        // The catalog already knows the type; do not ask URL to infer it from disk.
        self.init(url: URL(fileURLWithPath: path, isDirectory: flags & 1 != 0), name: name, isDirectory: flags & 1 != 0,
                  isPackage: flags & 2 != 0, isSymbolicLink: flags & 4 != 0,
                  isAlias: flags & 8 != 0, isHidden: flags & 16 != 0)
    }
    var sortsAsFolder: Bool { isDirectory && !isPackage && !isAlias && !isSymbolicLink }
    static func precedes(_ a: Self, _ b: Self) -> Bool {
        if a.sortsAsFolder != b.sortsAsFolder { return a.sortsAsFolder }
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.url.path < b.url.path : order == .orderedAscending
    }
}

public struct FilenameSearchSnapshot: Sendable {
    public let entries: [FilenameSearchEntry]
    /// Exact for a completed query; a growing lower bound while discovery/query work continues.
    public let totalMatchCount: Int
    public let isComplete: Bool
    /// The count is exact for the SQLite snapshot once query enumeration ends.
    public let queryFinished: Bool
    /// Initial discovery or startup reconciliation has not verified this scope yet.
    public let isIndexing: Bool
    /// Known changes are being reconciled after initial discovery has finished.
    public let isUpdating: Bool
    public let warningCount: Int
    public let errorMessage: String?
    public init(entries: [FilenameSearchEntry], totalMatchCount: Int, isComplete: Bool,
                warningCount: Int = 0, errorMessage: String? = nil,
                queryFinished: Bool? = nil, isIndexing: Bool? = nil, isUpdating: Bool = false) {
        self.entries = entries; self.totalMatchCount = totalMatchCount; self.isComplete = isComplete
        self.warningCount = warningCount; self.errorMessage = errorMessage
        self.queryFinished = queryFinished ?? isComplete
        self.isIndexing = isIndexing ?? !isComplete
        self.isUpdating = isUpdating
    }
}

public struct FilenameSearchDiagnostics: Sendable {
    public let scanCount: Int
    public let indexedEntryCount: Int
    public let queryCount: Int
    public let lastQueryDuration: TimeInterval
    public let activeScanCount: Int
    public let incrementalUpdateCount: Int
    public init(scanCount: Int, indexedEntryCount: Int, queryCount: Int, lastQueryDuration: TimeInterval,
                activeScanCount: Int, incrementalUpdateCount: Int = 0) {
        self.scanCount = scanCount; self.indexedEntryCount = indexedEntryCount
        self.queryCount = queryCount; self.lastQueryDuration = lastQueryDuration
        self.activeScanCount = activeScanCount; self.incrementalUpdateCount = incrementalUpdateCount
    }
}

public final class FilenameSearchSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var generation = 0
    private var revision: UInt64 = 0
    var onCancel: (() -> Void)?
    public func cancel() {
        lock.lock(); let first = !cancelled; cancelled = true; lock.unlock()
        if first { onCancel?() }
    }
    func nextGeneration() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return nil }
        generation &+= 1; return generation
    }
    func accepts(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && generation == value
    }
    func catalogChanged() { lock.lock(); revision &+= 1; lock.unlock() }
    var catalogRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    deinit { cancel() }
}

enum FilenameSearchFailure: Error, LocalizedError {
    case database(String), cancelled
    var errorDescription: String? {
        switch self {
        case .database(let message): return "The filename search index is unavailable. \(message)"
        case .cancelled: return "Search cancelled."
        }
    }
}

func filenamePathContains(_ parent: String, _ child: String) -> Bool {
    parent == child || child.hasPrefix(parent == "/" ? "/" : parent + "/")
}

func filenamePrefix(_ path: String) -> (String, String) {
    let prefix = path == "/" ? "/" : path + "/"
    return (prefix, String(prefix.dropLast()) + "0")
}
