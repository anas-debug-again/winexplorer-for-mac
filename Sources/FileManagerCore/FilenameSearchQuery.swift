import Foundation
import SQLite3
import Darwin

private final class FilenameQueryCancellation {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}

/// Match classification and depth are computed once, never inside heap/sort comparisons.
private struct FilenameQueryCandidate {
    let entry: FilenameSearchEntry
    let matchRank: Int
    let depth: Int

    static func precedes(_ a: Self, _ b: Self) -> Bool {
        if a.matchRank != b.matchRank { return a.matchRank < b.matchRank }
        if a.depth != b.depth { return a.depth < b.depth }
        return FilenameSearchEntry.precedes(a.entry, b.entry)
    }
}

/// A max heap retains only the best K results while a query counts every match.
private struct FilenameQueryHeap {
    let capacity: Int
    var values: [FilenameQueryCandidate] = []

    mutating func insert(_ entry: FilenameQueryCandidate) {
        guard capacity > 0 else { return }
        if values.count < capacity {
            values.append(entry)
            var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard FilenameQueryCandidate.precedes(values[parent], values[child]) else { break }
                values.swapAt(parent, child); child = parent
            }
        } else if FilenameQueryCandidate.precedes(entry, values[0]) {
            values[0] = entry
            var parent = 0
            while parent * 2 + 1 < values.count {
                let left = parent * 2 + 1, right = left + 1
                let worst = right < values.count && FilenameQueryCandidate.precedes(values[left], values[right]) ? right : left
                guard FilenameQueryCandidate.precedes(values[parent], values[worst]) else { break }
                values.swapAt(parent, worst); parent = worst
            }
        }
    }
}

extension FilenameSearchDatabase {
    /// Reads one consistent WAL snapshot. SQL narrows the candidates; Foundation is
    /// the final matching authority, preserving Finder-like Unicode name matching.
    func query(root: String, query: String, includeHidden: Bool, limit: Int,
               order: FilenameSearchOrder = .name, excludeGenerated: Bool = false, batchDelay: TimeInterval = 0,
               cancelled: @escaping () -> Bool,
               onUpdate: ([FilenameSearchEntry], Int, Bool) -> Void) throws {
        if cancelled() { throw FilenameSearchFailure.cancelled }
        var rootInfo = stat()
        guard stat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue,
                          userInfo: [NSFilePathErrorKey: root, NSLocalizedDescriptionKey: "The search folder is no longer available."])
        }
        guard access(root, R_OK | X_OK) == 0 else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                          userInfo: [NSFilePathErrorKey: root])
        }
        if query.unicodeScalars.contains(where: { $0.value == 0 }) { onUpdate([], 0, true); return }
        let cancellation = FilenameQueryCancellation(cancelled)
        sqlite3_progress_handler(handle, 1_000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<FilenameQueryCancellation>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer {
            sqlite3_progress_handler(handle, 0, nil, nil)
            _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            withExtendedLifetime(cancellation) {}
        }
        do {
            try execute("BEGIN")
            let range = filenamePrefix(root)
            var hiddenDirectories = Set<String>()
            if !includeHidden {
                let statement = try prepare("SELECT path FROM entries WHERE path>=? AND path<? AND (flags & 17)=17")
                defer { sqlite3_finalize(statement) }
                bind(range.0, to: statement, at: 1); bind(range.1, to: statement, at: 2)
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw failure() }
                    if cancelled() { throw FilenameSearchFailure.cancelled }
                    hiddenDirectories.insert(text(statement, 0))
                }
            }
            var visibleParents: [String: Bool] = [root: true]
            func parentIsVisible(_ path: String) -> Bool {
                guard !includeHidden, !hiddenDirectories.isEmpty else { return true }
                var parent = (path as NSString).deletingLastPathComponent
                var visited: [String] = []
                var visible = true
                while parent != root && filenamePathContains(root, parent) {
                    if let cached = visibleParents[parent] { visible = cached; break }
                    if hiddenDirectories.contains(parent) { visible = false; break }
                    visited.append(parent)
                    let next = (parent as NSString).deletingLastPathComponent
                    if next == parent { break }
                    parent = next
                }
                if visibleParents.count > 16_384 { visibleParents = [root: true] }
                for directory in visited { visibleParents[directory] = visible }
                return visible
            }

            // Generated-path rules depend on directory boundaries. Reuse each
            // parent's decision across its ordinary children instead of splitting
            // the entire absolute path again for every matching filename.
            var generatedParents: [String: Bool] = [root: true]
            func generatedPathIsVisible(_ path: String) -> Bool {
                guard excludeGenerated else { return true }
                guard let separator = path.lastIndex(of: "/") else {
                    return FilenameSearchFilter.includes(path: path, in: root, excludeGenerated: true)
                }
                let parent = separator == path.startIndex ? "/" : String(path[..<separator])
                let parentIncluded: Bool
                if let cached = generatedParents[parent] { parentIncluded = cached }
                else {
                    parentIncluded = FilenameSearchFilter.includes(path: parent, in: root, excludeGenerated: true)
                    if generatedParents.count >= 16_384 {
                        generatedParents.removeAll(keepingCapacity: true)
                        generatedParents[root] = true
                    }
                    generatedParents[parent] = parentIncluded
                }
                guard parentIncluded else { return false }
                let component = String(path[path.index(after: separator)...])
                guard FilenameSearchFilter.mayExcludeName(component) else { return true }
                // The child itself may be a generated directory or complete a
                // multi-component rule, even when its parent remains visible.
                return FilenameSearchFilter.includes(path: path, in: root, excludeGenerated: true)
            }

            let usesTrigram = hasTrigram && query.unicodeScalars.allSatisfy(\.isASCII) && query.unicodeScalars.count >= 3
            let hiddenClause = includeHidden ? "" : " AND (e.flags & 16)=0"
            let sql: String
            if usesTrigram {
                // Unicode names are deliberately included even if their normalized index
                // token differs from Foundation's locale-sensitive substring comparison.
                // CROSS JOIN keeps the FTS match as the driving table. An ordinary JOIN
                // can make SQLite probe FTS once for every ASCII filename in the scope.
                sql = """
                    SELECT e.path,e.name,e.flags FROM entry_fts CROSS JOIN entries e ON e.rowid=entry_fts.rowid
                    WHERE entry_fts MATCH ? AND e.path>=? AND e.path<? AND e.non_ascii=0\(hiddenClause)
                    UNION ALL
                    SELECT e.path,e.name,e.flags FROM entries e
                    WHERE e.non_ascii=1 AND e.path>=? AND e.path<?\(hiddenClause)
                    """
            } else {
                sql = "SELECT e.path,e.name,e.flags FROM entries e WHERE e.path>=? AND e.path<?\(hiddenClause)"
            }
            let unlimited = limit <= 0 || limit == Int.max
            var heap = FilenameQueryHeap(capacity: unlimited ? 1_000 : limit)
            var all: [FilenameQueryCandidate] = []
            var count = 0, visited = 0
            var lastUpdate = ProcessInfo.processInfo.systemUptime
            func sorted(_ entries: [FilenameQueryCandidate]) throws -> [FilenameSearchEntry] {
                var comparisons = 0
                return try entries.sorted {
                    comparisons &+= 1
                    if comparisons & 255 == 0, cancelled() { throw FilenameSearchFailure.cancelled }
                    return FilenameQueryCandidate.precedes($0, $1)
                }.map(\.entry)
            }
            do {
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                if usesTrigram {
                    let locale = Locale(identifier: "en_US_POSIX")
                    let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale).lowercased(with: locale)
                    // Binding protects SQL; quoting separately makes FTS operators and
                    // punctuation literal filename text rather than query syntax.
                    bind("\"" + folded.replacingOccurrences(of: "\"", with: "\"\"") + "\"", to: statement, at: 1)
                    bind(range.0, to: statement, at: 2); bind(range.1, to: statement, at: 3)
                    bind(range.0, to: statement, at: 4); bind(range.1, to: statement, at: 5)
                } else {
                    bind(range.0, to: statement, at: 1); bind(range.1, to: statement, at: 2)
                }
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw failure() }
                    if cancelled() { throw FilenameSearchFailure.cancelled }
                    visited += 1
                    let name = text(statement, 1)
                    let matchRank: Int?
                    if order == .bestMatch { matchRank = FilenameSearchRanking.rank(name: name, query: query) }
                    else { matchRank = query.isEmpty || name.localizedStandardContains(query) ? 0 : nil }
                    if let matchRank {
                        let path = text(statement, 0)
                        if path != root && parentIsVisible(path) && generatedPathIsVisible(path) {
                            let entry = FilenameSearchEntry(path: path, name: name, flags: sqlite3_column_int(statement, 2))
                            let candidate = FilenameQueryCandidate(entry: entry, matchRank: matchRank,
                                depth: order == .bestMatch ? FilenameSearchRanking.depth(path: path, root: root) : 0)
                            count += 1
                            heap.insert(candidate)
                            if unlimited { all.append(candidate) }
                        }
                    }
                    if visited & 511 == 0 {
                        // A test-only hook makes cancellation during a running query
                        // deterministic; production callers retain the zero default.
                        if batchDelay > 0 { Thread.sleep(forTimeInterval: min(batchDelay, 0.05)) }
                        if cancelled() { throw FilenameSearchFailure.cancelled }
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastUpdate >= 0.1 {
                            onUpdate(try sorted(heap.values), count, false)
                            lastUpdate = now
                        }
                    }
                }
            }
            // Do not pin the WAL while a potentially large result is naturally sorted.
            try execute("COMMIT")
            if cancelled() { throw FilenameSearchFailure.cancelled }
            let results = try sorted(unlimited ? all : heap.values)
            if cancelled() { throw FilenameSearchFailure.cancelled }
            onUpdate(results, count, true)
        } catch {
            if cancelled() { throw FilenameSearchFailure.cancelled }
            throw error
        }
    }
}
