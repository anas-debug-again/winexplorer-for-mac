import Foundation
import Darwin

// Foundation shortens these physical paths when standardizing URLs. Its directory
// enumerator returns the physical spelling. Normalize the leading system alias only:
// a symlink elsewhere in the tree (including a missing leaf in a deletion event)
// must keep its own catalog key. An explicit search root may itself be an alias.
private let searchSystemAliases: [(logical: String, physical: String)] = ["/var", "/tmp", "/etc"].compactMap { logical in
    guard let resolved = realpath(logical, nil) else { return nil }
    defer { free(resolved) }
    let physical = String(cString: resolved)
    return physical == logical ? nil : (logical, physical)
}

private func searchCatalogPath(_ path: String, resolvingRoot: Bool = false) -> String {
    for alias in searchSystemAliases {
        if resolvingRoot && path == alias.logical { return alias.physical }
        if path.hasPrefix(alias.logical + "/") {
            return alias.physical + path.dropFirst(alias.logical.count)
        }
    }
    return path
}

private func searchRootPath(_ url: URL) -> String {
    searchCatalogPath(url.standardizedFileURL.resolvingSymlinksInPath().path, resolvingRoot: true)
}

/// A shared, persistent filename catalog. Filesystem scans are serialized and batched;
/// independent SQLite readers let typing cancel/replace queries without restarting scans.
public final class FilenameSearchIndex: @unchecked Sendable {
    private final class Scope {
        let path: String
        var baselineComplete: Bool
        var historyReady = false
        var active = false
        var warnings: Int
        var eventID: UInt64
        var device: UInt64
        var inode: UInt64
        var volumeID: String?
        var watcher: FilenameSearchWatcher?
        var error: String?
        var watcherError: String?
        var persisted: String = ""
        init(path: String, complete: Bool = false, warnings: Int = 0, eventID: UInt64 = 0,
             device: UInt64 = 0, inode: UInt64 = 0, volumeID: String? = nil) {
            self.path = path; baselineComplete = complete; self.warnings = warnings
            self.eventID = eventID; self.device = device; self.inode = inode; self.volumeID = volumeID
        }
    }
    private final class Request {
        let id: UUID
        let root: String
        let query: String
        let hidden: Bool
        let limit: Int
        let order: FilenameSearchOrder
        let excludeGenerated: Bool
        let callback: (FilenameSearchSnapshot) -> Void
        weak var subscription: FilenameSearchSubscription?
        var queryRunning = false
        var refreshPending = false
        var needsRefresh = false
        var maintenanceReported = false
        var pendingDeliveries = 0
        init(id: UUID, root: String, query: String, hidden: Bool, limit: Int,
             order: FilenameSearchOrder, excludeGenerated: Bool,
             subscription: FilenameSearchSubscription, callback: @escaping (FilenameSearchSnapshot) -> Void) {
            self.id = id; self.root = root; self.query = query; self.hidden = hidden; self.limit = limit
            self.order = order; self.excludeGenerated = excludeGenerated
            self.subscription = subscription; self.callback = callback
        }
    }
    private let databaseURL: URL
    private let excludedPaths: Set<String>
    private let stateQueue = DispatchQueue(label: "FileManager.search.state", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "FileManager.search.scan", qos: .utility)
    private let queryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FileManager.search.query"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let stateKey = DispatchSpecificKey<Bool>()
    private let batchSize: Int
    private let batchDelay: TimeInterval
    private let queryBatchDelay: TimeInterval
    private var database: FilenameSearchDatabase?
    private var storageError: String?
    private var scopes: [String: Scope] = [:]
    private var requests: [UUID: Request] = [:]
    private var pending: [FilenameSearchScan] = []
    private var active: FilenameSearchScan?
    private var nextScan = Int64(Date().timeIntervalSince1970 * 1_000_000)
    private var closed = false
    private var refreshScheduled = false
    private var scanCount = 0
    private var incrementalUpdateCount = 0
    private var indexedEntryCount = 0
    private var queryCount = 0
    private var lastQueryDuration: TimeInterval = 0

    public convenience init(databaseURL: URL) { self.init(databaseURL: databaseURL, scanBatchSize: 512, scanBatchDelay: 0) }

    @_spi(Testing)
    public init(databaseURL: URL, scanBatchSize: Int, scanBatchDelay: TimeInterval, queryBatchDelay: TimeInterval = 0) {
        let canonicalDatabase = URL(fileURLWithPath: searchRootPath(databaseURL), isDirectory: false)
        self.databaseURL = canonicalDatabase
        excludedPaths = Set([canonicalDatabase.path, canonicalDatabase.path + "-wal", canonicalDatabase.path + "-shm", canonicalDatabase.path + "-journal"])
        batchSize = max(1, min(4096, scanBatchSize)); batchDelay = max(0, scanBatchDelay)
        self.queryBatchDelay = max(0, queryBatchDelay)
        stateQueue.setSpecific(key: stateKey, value: true)
        stateQueue.async { [weak self] in self?.initialize() }
    }

    private func initialize() {
        guard !closed else { return }
        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let connection = try FilenameSearchDatabase(url: databaseURL)
            database = connection
            for row in try connection.scopes() {
                if searchCatalogPath(row.0, resolvingRoot: true) != row.0 {
                    // Old enumerated rows already have physical keys. Discard the
                    // obsolete scope and its logical rows; activation verifies the cache.
                    try connection.discardLegacyScope(row.0)
                    continue
                }
                scopes[row.0] = Scope(path: row.0, complete: row.1, warnings: row.2, eventID: row.3,
                                      device: row.4, inode: row.5, volumeID: row.6)
            }
            indexedEntryCount = try connection.scalar("SELECT count(*) FROM entries")
        } catch { storageError = error.localizedDescription }
    }

    /// A nonpositive limit (or Int.max) requests all matches. Counts are provisional
    /// during discovery; a finished read reports its exact catalog-snapshot count.
    @discardableResult
    public func search(in root: URL, query: String, includeHidden: Bool, limit: Int = 1000,
                       order: FilenameSearchOrder = .name, excludeGenerated: Bool = false,
                       onUpdate: @escaping (FilenameSearchSnapshot) -> Void) -> FilenameSearchSubscription {
        let subscription = FilenameSearchSubscription()
        let id = UUID()
        trace("subscribe", id: id)
        subscription.onCancel = { [weak self] in self?.stateQueue.async { [weak self] in self?.requests.removeValue(forKey: id) } }
        stateQueue.async { [weak self, subscription] in
            guard let self, !subscription.isCancelled else { return }
            self.trace("state entered", id: id)
            let normalized = root.isFileURL ? searchRootPath(root) : root.absoluteString
            let request = Request(id: id, root: normalized, query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                  hidden: includeHidden, limit: limit, order: order, excludeGenerated: excludeGenerated,
                                  subscription: subscription, callback: onUpdate)
            self.requests[id] = request
            guard !self.closed, root.isFileURL else {
                self.deliverError(request, self.closed ? "The filename search index has been closed." : "Choose a filesystem folder to search.")
                return
            }
            guard self.storageError == nil else { self.deliverError(request, self.storageError!); return }
            do { try self.ensureScope(normalized) }
            catch { self.deliverError(request, "The folder cannot be searched. " + error.localizedDescription); return }
            self.trace("scope ready", id: id)
            self.runQuery(request)
        }
        return subscription
    }

    /// Reconcile a known scope only; file operations do not accidentally start indexing new roots.
    public func invalidate(in root: URL, recursive: Bool = true) {
        guard root.isFileURL else { return }
        stateQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            let path = searchRootPath(root)
            for scope in self.scopes.values where scope.active && (filenamePathContains(scope.path, path) || filenamePathContains(path, scope.path)) {
                guard !self.isBelowOpaqueEntry(path, scope: scope.path) else { continue }
                self.scheduleScan(filenamePathContains(scope.path, path) ? path : scope.path, mode: recursive ? .recursive : .shallow)
            }
        }
    }

    public func diagnostics(completion: @escaping (FilenameSearchDiagnostics) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let result = FilenameSearchDiagnostics(scanCount: self.scanCount, indexedEntryCount: self.indexedEntryCount,
                queryCount: self.queryCount, lastQueryDuration: self.lastQueryDuration, activeScanCount: self.active == nil ? 0 : 1,
                incrementalUpdateCount: self.incrementalUpdateCount)
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func close() {
        let stop = {
            guard !self.closed else { return }
            self.closed = true
            for request in self.requests.values { request.subscription?.cancel() }
            self.requests.removeAll()
            self.active?.cancel(); self.pending.removeAll()
            for scope in self.scopes.values { scope.watcher?.close(); scope.watcher = nil }
            self.database = nil
        }
        if DispatchQueue.getSpecific(key: stateKey) != nil { stop() } else { stateQueue.sync(execute: stop) }
        queryQueue.cancelAllOperations()
        queryQueue.waitUntilAllOperationsAreFinished()
    }
    public func shutdown() { close() }
    deinit {
        active?.cancel()
        for scope in scopes.values { scope.watcher?.close() }
    }

    private func identity(_ path: String) throws -> (UInt64, UInt64) {
        var info = stat()
        guard stat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard access(path, R_OK | X_OK) == 0 else { throw CocoaError(.fileReadNoPermission) }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }

    private func ensureScope(_ path: String) throws {
        _ = try identity(path)
        if let scope = scopes.values.filter({ filenamePathContains($0.path, path) }).min(by: { $0.path.count < $1.path.count }) {
            if !scope.active { activate(scope) }
            return
        }
        let scope = Scope(path: path)
        scopes[path] = scope
        activate(scope)
    }

    private func activate(_ scope: Scope) {
        guard !scope.active else { return }
        scope.active = true
        let root = URL(fileURLWithPath: scope.path)
        let currentIdentity = try? identity(scope.path)
        let volumeID = FilenameSearchWatcher.eventStoreIdentifier(for: root)
        let reusable = scope.baselineComplete && scope.eventID > 0 && volumeID != nil && volumeID == scope.volumeID
            && currentIdentity?.0 == scope.device && currentIdentity?.1 == scope.inode
        scope.device = currentIdentity?.0 ?? 0; scope.inode = currentIdentity?.1 ?? 0; scope.volumeID = volumeID
        // A persisted catalog is useful immediately, but FSEvents replay/flush cannot
        // prove that the daemon has observed an arbitrarily recent offline mutation.
        // Reconcile once when a scope becomes active in this service lifetime, keeping
        // cached results partial until that background scan has verified the baseline.
        scope.historyReady = true; scope.baselineComplete = false
        if !reusable { scope.eventID = FilenameSearchWatcher.currentEventID }
        do {
            scope.watcher = try FilenameSearchWatcher(root: root, since: reusable ? scope.eventID : 0, queue: stateQueue) { [weak self, weak scope] events in
                guard let self, let scope, !self.closed else { return }
                self.consume(events, scope: scope)
            }
        } catch {
            scope.watcherError = "Live folder updates are unavailable. Refresh to rescan. " + error.localizedDescription
            scope.historyReady = true; scope.baselineComplete = false
        }
        let covered = scopes.values.filter { $0 !== scope && filenamePathContains(scope.path, $0.path) }
        for child in covered where !child.active { activate(child) }
        scheduleScan(scope.path, preserving: covered.filter(\.active).map(\.path))
        persist(scope)
    }

    private func consume(_ events: [FilenameSearchChange], scope: Scope) {
        for event in events {
            if event.historyDone {
                scope.historyReady = true
                scope.eventID = max(scope.eventID, event.eventID)
                continue
            }
            let path = searchCatalogPath(event.path)
            guard !excludedPaths.contains(path) else { continue }
            scope.eventID = max(scope.eventID, event.eventID)
            if event.requiresFullRescan {
                scope.baselineComplete = false; scope.historyReady = true
                scheduleScan(scope.path)
            } else if filenamePathContains(scope.path, path), !isBelowOpaqueEntry(path, scope: scope.path) {
                if event.isStructural || event.flags == 0 {
                    // Membership changes need only an immediate-directory comparison.
                    // A genuinely new/moved folder gets a recursive job of its own.
                    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    scheduleScan(filenamePathContains(scope.path, parent) ? parent : scope.path, mode: .shallow)
                    if event.isDirectory && event.mayHaveNewSubtree { scheduleScan(path, mode: .recursive) }
                } else if event.isDirectory && event.directoryMetadataChanged {
                    // Permission/owner changes can reveal changes underneath already
                    // known children which a shallow comparison cannot discover.
                    scheduleScan(path)
                } else if event.isDirectory && event.contentsChanged {
                    scheduleScan(path, mode: .shallow)
                } else {
                    scheduleScan(path, mode: .entry)
                }
            }
        }
        persist(scope)
    }

    private func isBelowOpaqueEntry(_ path: String, scope: String) -> Bool {
        guard let database else { return false }
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != scope && filenamePathContains(scope, parent) {
            if let flags = try? database.flags(at: parent) {
                if flags & (2 | 4 | 8) != 0 { return true }
            } else {
                let metadata = try? URL(fileURLWithPath: parent).resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey, .isAliasFileKey])
                if metadata?.isPackage == true || metadata?.isSymbolicLink == true || metadata?.isAliasFile == true { return true }
            }
            let next = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            if next == parent { break }; parent = next
        }
        return false
    }

    private func overlapsWork(_ path: String) -> Bool {
        let tasks = pending + (active.map { [$0] } ?? [])
        return tasks.contains { $0.affects(path) }
    }
    private func baselineReady(_ path: String) -> Bool {
        guard scopes.values.contains(where: { $0.active && filenamePathContains($0.path, path) && $0.baselineComplete && $0.historyReady }) else { return false }
        return !scopes.values.contains { $0.active && filenamePathContains(path, $0.path) && (!$0.baselineComplete || !$0.historyReady) }
    }
    private func ready(_ scope: Scope) -> Bool {
        baselineReady(scope.path) && !overlapsWork(scope.path)
    }
    private func persist(_ scope: Scope) {
        guard let database, !closed else { return }
        let complete = ready(scope) && scope.watcher != nil
        // Never advance a replay checkpoint past pending reconciliation.
        let event = complete ? scope.eventID : 0
        let signature = "\(complete)|\(scope.warnings)|\(event)|\(scope.device)|\(scope.inode)|\(scope.volumeID ?? "")"
        guard signature != scope.persisted else { return }
        do {
            try database.saveScope(scope.path, complete: complete, warnings: scope.warnings, eventID: event,
                                   device: scope.device, inode: scope.inode, volumeID: scope.volumeID)
            scope.persisted = signature
        } catch { storageError = error.localizedDescription }
    }

    private func scheduleScan(_ path: String, mode: FilenameSearchScanMode = .recursive, preserving: [String] = []) {
        guard !closed, database != nil, !excludedPaths.contains(path) else { return }
        nextScan &+= 1
        let task = FilenameSearchScan(path: path, id: nextScan, mode: mode, excluded: excludedPaths, preserving: preserving)
        if pending.contains(where: { $0.covers(task) }) { return }
        pending.removeAll { task.covers($0) }
        pending.append(task)
        for request in requests.values where task.affects(request.root) {
            // A callback already queued for main must not claim quiescence after
            // overlapping work is scheduled. If that read is in flight/queued,
            // arrange a fresh completion even when the later metadata is unchanged.
            request.subscription?.catalogChanged()
            if request.queryRunning { request.refreshPending = true }
            if request.pendingDeliveries > 0 { request.needsRefresh = true }
        }
        // Active work never absorbs a later event: an already-enumerated directory
        // could have changed. Retain one coalesced follow-up at the smallest scope.
        if mode != .entry { requestRefresh(in: path) }
        for scope in scopes.values where scope.active { persist(scope) }
        scheduleRefresh()
        startNextScan()
    }
    private func startNextScan() {
        guard !closed, active == nil, !pending.isEmpty else { return }
        let task = pending.removeFirst(); active = task
        if task.mode == .recursive { scanCount += 1 }
        readNextBatch(task)
    }
    private func readNextBatch(_ task: FilenameSearchScan) {
        scanQueue.asyncAfter(deadline: .now() + batchDelay) { [weak self, task] in
            guard let self, !task.isCancelled else { return }
            let batch = task.readBatch(maximum: self.batchSize)
            self.stateQueue.async { [weak self, task] in self?.accept(batch, from: task) }
        }
    }
    private func accept(_ batch: FilenameSearchScan.Batch, from task: FilenameSearchScan) {
        guard !closed, active === task, let database else { return }
        var changedPaths = Set<String>()
        var inserted = 0, removed = 0
        do {
            try database.transaction {
                if task.mode == .recursive {
                    inserted += try database.upsert(batch.entries, scan: task.id)
                    changedPaths.formUnion(batch.entries.map { $0.url.path })
                } else {
                    var writes: [FilenameSearchEntry] = []
                    for entry in batch.entries {
                        let previous = try database.entry(at: entry.url.path)
                        if previous == nil { inserted += 1 }
                        if previous != entry {
                            changedPaths.insert(entry.url.path)
                            if entry.sortsAsFolder && previous?.sortsAsFolder != true &&
                                (task.mode == .entry || entry.url.path != task.path) {
                                task.discoveredDirectories.insert(entry.url.path)
                            }
                            if previous?.sortsAsFolder == true && !entry.sortsAsFolder {
                                removed += try database.deleteSubtree(entry.url.path, includingRoot: false)
                            }
                        }
                        // Shallow membership comparison needs an epoch on every direct
                        // child; unchanged single-file metadata requires no database write.
                        if task.mode == .shallow || previous != entry { writes.append(entry) }
                    }
                    if !writes.isEmpty { try database.upsert(writes, scan: task.id) }
                }
                if batch.finished && batch.errorMessage == nil {
                    switch task.mode {
                    case .recursive:
                        removed += try database.deleteSubtree(task.path, exceptScan: task.id, preserving: task.preserving)
                        if removed > 0 { changedPaths.insert(task.path) }
                    case .shallow:
                        if !task.rootExists {
                            removed += try database.deleteSubtree(task.path)
                            if removed > 0 { changedPaths.insert(task.path) }
                        } else {
                            for missing in try database.unseenChildren(in: task.path, scan: task.id) {
                                removed += try database.deleteSubtree(missing)
                                changedPaths.insert(missing)
                            }
                        }
                    case .entry:
                        if !task.rootExists {
                            removed += try database.deleteSubtree(task.path)
                            if removed > 0 { changedPaths.insert(task.path) }
                        }
                    }
                }
                if batch.finished && task.directoryUnavailable {
                    removed += try database.deleteSubtree(task.path, includingRoot: false)
                    if removed > 0 { changedPaths.insert(task.path) }
                }
            }
            indexedEntryCount = max(0, indexedEntryCount + inserted - removed)
            for path in changedPaths { markCatalogChanged(in: path) }
        } catch {
            storageError = error.localizedDescription; task.cancel()
            active = nil; pending.removeAll()
            for request in requests.values { request.needsRefresh = true }
            scheduleRefresh(); return
        }
        if batch.finished {
            active = nil
            if task.mode != .recursive { incrementalUpdateCount += 1 }
            for scope in scopes.values where task.mode == .recursive && scope.active && filenamePathContains(task.path, scope.path) && !task.preserving.contains(where: { filenamePathContains($0, scope.path) }) {
                scope.baselineComplete = true
                scope.warnings = task.warningCount
                let current = try? identity(scope.path)
                scope.error = current == nil ? (batch.errorMessage ?? "The search folder is unavailable or permission was denied.") : (task.path == scope.path ? batch.errorMessage : nil)
                scope.device = current?.0 ?? 0; scope.inode = current?.1 ?? 0
                scope.volumeID = FilenameSearchWatcher.eventStoreIdentifier(for: URL(fileURLWithPath: scope.path))
            }
            for scope in scopes.values where scope.active && filenamePathContains(scope.path, task.path) {
                scope.warnings = task.mode == .recursive && task.path == scope.path ? task.warningCount : max(scope.warnings, task.warningCount)
            }
            if task.mode == .entry && changedPaths.isEmpty { requestMetadataRefresh(for: batch.entries) }
            requestRefresh(in: task.path, onlyIfReported: task.mode == .entry && changedPaths.isEmpty)
            for directory in task.discoveredDirectories {
                scheduleScan(directory)
            }
            for scope in scopes.values where scope.active { persist(scope) }
            startNextScan()
        } else { readNextBatch(task) }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled, !closed else { return }
        refreshScheduled = true
        stateQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.closed else { return }
            self.refreshScheduled = false
            for request in self.requests.values where request.needsRefresh { self.runQuery(request) }
        }
    }
    private func markCatalogChanged(in path: String) {
        for request in requests.values where filenamePathContains(request.root, path) || filenamePathContains(path, request.root) {
            request.subscription?.catalogChanged()
            request.needsRefresh = true
            if request.queryRunning { request.refreshPending = true }
        }
    }
    private func requestRefresh(in path: String, onlyIfReported: Bool = false) {
        for request in requests.values where filenamePathContains(request.root, path) || filenamePathContains(path, request.root) {
            if !onlyIfReported || request.maintenanceReported { request.needsRefresh = true }
        }
    }
    private func requestMetadataRefresh(for entries: [FilenameSearchEntry]) {
        for request in requests.values {
            if entries.contains(where: { entry in
                entry.url.path != request.root && filenamePathContains(request.root, entry.url.path) &&
                    (request.hidden || !entry.isHidden) &&
                    FilenameSearchFilter.includes(path: entry.url.path, in: request.root, excludeGenerated: request.excludeGenerated) &&
                    (request.query.isEmpty || entry.name.localizedStandardContains(request.query))
            }) { request.needsRefresh = true }
        }
    }
    private func trace(_ stage: String, id: UUID) {
        guard ProcessInfo.processInfo.environment["FILE_MANAGER_SEARCH_TRACE"] == "1" else { return }
        fputs(String(format: "[search-core] %.3f %@ %@\n", ProcessInfo.processInfo.systemUptime,
                     String(id.uuidString.prefix(6)), stage), stderr)
    }
    // Deterministic event-path coverage in fixture tests, without posting system input
    // or relying on the daemon's variable delivery latency. Normal callers use FSEvents.
    func receiveForTesting(_ events: [FilenameSearchChange], in root: URL, completion: (() -> Void)? = nil) {
        stateQueue.async { [weak self] in
            defer { completion?() }
            guard let self, !self.closed, let scope = self.scopes[searchRootPath(root)], scope.active else { return }
            self.consume(events, scope: scope)
        }
    }
    func pendingDeliveriesForTesting(_ completion: @escaping (Int) -> Void) {
        stateQueue.async { [weak self] in completion(self?.requests.values.reduce(0) { $0 + $1.pendingDeliveries } ?? 0) }
    }
    private func deliverError(_ request: Request, _ message: String) {
        guard let subscription = request.subscription, let generation = subscription.nextGeneration() else { return }
        DispatchQueue.main.async {
            guard subscription.accepts(generation) else { return }
            request.callback(FilenameSearchSnapshot(entries: [], totalMatchCount: 0, isComplete: true, errorMessage: message))
        }
    }
    private func runQuery(_ request: Request) {
        guard !closed else { return }
        request.needsRefresh = false
        if request.queryRunning { request.refreshPending = true; return }
        guard let subscription = request.subscription, let generation = subscription.nextGeneration() else { return }
        if let storageError { deliverError(request, storageError); return }
        let covering = scopes.values.filter { $0.active && filenamePathContains($0.path, request.root) }
        let catalogRevision = subscription.catalogRevision
        let warningCount = (covering.map(\.warnings).max() ?? 0) + (covering.contains(where: { $0.watcherError != nil }) ? 1 : 0)
        let error = covering.compactMap(\.error).first ?? covering.compactMap(\.watcherError).first
        let databaseURL = self.databaseURL
        request.queryRunning = true; request.refreshPending = false
        queryQueue.addOperation { [weak self, subscription] in
            guard let self else { return }
            self.trace("query worker entered", id: request.id)
            let start = ProcessInfo.processInfo.systemUptime
            defer {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                self.trace("query ended", id: request.id)
                self.stateQueue.async { [weak self] in
                    guard let self else { return }
                    self.queryCount += 1; self.lastQueryDuration = elapsed
                    request.queryRunning = false
                    if request.refreshPending { self.runQuery(request) }
                }
            }
            guard subscription.accepts(generation) else { return }
            do {
                let reader = try FilenameSearchDatabase(url: databaseURL, readOnly: true)
                self.trace("reader ready", id: request.id)
                try reader.query(root: request.root, query: request.query, includeHidden: request.hidden,
                                 limit: request.limit, order: request.order, excludeGenerated: request.excludeGenerated,
                                 batchDelay: self.queryBatchDelay,
                                 cancelled: { !subscription.accepts(generation) }) { entries, count, queryFinished in
                    self.stateQueue.async { [weak self] in
                        guard let self else { return }
                        guard subscription.accepts(generation) else { return }
                        // Filesystem events can make an in-flight read stale. Check on
                        // delivery, not when it entered the worker queue, and never call
                        // that older catalog complete while reconciliation is pending.
                        let indexing = !self.baselineReady(request.root)
                        let updating = !indexing && self.overlapsWork(request.root)
                        let complete = !self.closed && !indexing && !updating
                        request.maintenanceReported = indexing || updating
                        request.pendingDeliveries += 1
                        DispatchQueue.main.async { [weak self] in
                            defer { self?.stateQueue.async { request.pendingDeliveries -= 1 } }
                            guard subscription.accepts(generation) else { return }
                            let stale = subscription.catalogRevision != catalogRevision
                            let snapshot = FilenameSearchSnapshot(entries: entries, totalMatchCount: count,
                                isComplete: complete && queryFinished && !stale,
                                warningCount: warningCount, errorMessage: error,
                                queryFinished: queryFinished, isIndexing: indexing, isUpdating: updating || (!indexing && stale))
                            request.callback(snapshot)
                        }
                    }
                }
            } catch FilenameSearchFailure.cancelled { return }
            catch {
                DispatchQueue.main.async {
                    guard subscription.accepts(generation) else { return }
                    request.callback(FilenameSearchSnapshot(entries: [], totalMatchCount: 0, isComplete: true,
                        warningCount: warningCount, errorMessage: error.localizedDescription))
                }
            }
        }
    }

    /// Benchmark-only import through the same schema and FTS triggers used by real scans.
    /// Synthetic rows are not watched: delayed fixture events must not overwrite the
    /// generated catalog. Explicit invalidation still reconciles against the disk,
    /// and reopening this database performs a real scan before reporting completeness.
    @_spi(Testing)
    public func seedCatalog(in root: URL, entries: [FilenameSearchEntry], completion: @escaping (Error?) -> Void) {
        stateQueue.async { [weak self] in
            guard let self, !self.closed, let database = self.database else {
                DispatchQueue.main.async { completion(FilenameSearchFailure.database("The index is not open.")) }; return
            }
            do {
                let path = searchRootPath(root)
                let identity = try self.identity(path)
                let logicalRoot = root.path
                let catalogEntries = path == logicalRoot ? entries : entries.map { entry -> FilenameSearchEntry in
                    guard filenamePathContains(logicalRoot, entry.url.path) else { return entry }
                    let physical = path + entry.url.path.dropFirst(logicalRoot.count)
                    return FilenameSearchEntry(path: physical, name: entry.name, flags: entry.flags)
                }
                try database.transaction { try database.deleteSubtree(path); try database.upsert(catalogEntries, scan: self.nextScan) }
                let scope = Scope(path: path, complete: true, eventID: FilenameSearchWatcher.currentEventID,
                                  device: identity.0, inode: identity.1,
                                  volumeID: FilenameSearchWatcher.eventStoreIdentifier(for: root))
                scope.active = true; scope.historyReady = true
                self.scopes[path]?.watcher?.close()
                self.scopes[path] = scope; self.persist(scope)
                self.indexedEntryCount = try database.scalar("SELECT count(*) FROM entries")
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }
}

private enum FilenameSearchScanMode { case recursive, shallow, entry }

private final class FilenameSearchScan: @unchecked Sendable {
    struct Batch { let entries: [FilenameSearchEntry]; let finished: Bool; let errorMessage: String? }
    let path: String
    let id: Int64
    let mode: FilenameSearchScanMode
    let preserving: [String]
    var discoveredDirectories = Set<String>()
    private(set) var rootExists = false
    private(set) var directoryUnavailable = false
    private let excluded: Set<String>
    private let cancellation = FilenameSearchSubscription()
    private var enumerator: FileManager.DirectoryEnumerator?
    private var started = false
    private var rootEntry: FilenameSearchEntry?
    private(set) var warningCount = 0
    var isCancelled: Bool { cancellation.isCancelled }
    init(path: String, id: Int64, mode: FilenameSearchScanMode, excluded: Set<String>, preserving: [String]) {
        self.path = path; self.id = id; self.mode = mode; self.excluded = excluded; self.preserving = preserving
    }
    func covers(_ other: FilenameSearchScan) -> Bool {
        switch mode {
        case .recursive:
            guard filenamePathContains(path, other.path), !preserving.contains(where: { filenamePathContains($0, other.path) }) else { return false }
            if other.mode == .recursive {
                // A parent job that skips a preserved child cannot absorb a later
                // whole-parent refresh which explicitly requires that child too.
                return !preserving.contains { skipped in
                    filenamePathContains(other.path, skipped) && !other.preserving.contains { filenamePathContains($0, skipped) }
                }
            }
            return true
        case .shallow:
            return (other.mode == .shallow && path == other.path) || (other.mode == .entry &&
                (path == other.path || URL(fileURLWithPath: other.path).deletingLastPathComponent().path == path))
        case .entry: return other.mode == .entry && other.path == path
        }
    }
    func affects(_ root: String) -> Bool {
        if filenamePathContains(root, path) { return true }
        guard filenamePathContains(path, root) else { return false }
        return !preserving.contains { filenamePathContains($0, root) }
    }
    func cancel() { cancellation.cancel() }
    private func entry(_ url: URL) -> (FilenameSearchEntry?, Bool) {
        do {
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey])
            let item = FilenameSearchEntry(url: url, isDirectory: v.isDirectory == true, isPackage: v.isPackage == true,
                isSymbolicLink: v.isSymbolicLink == true, isAlias: v.isAliasFile == true,
                isHidden: v.isHidden == true || url.lastPathComponent.hasPrefix("."))
            return (item, item.isSymbolicLink || item.isAlias || item.isPackage)
        } catch {
            warningCount += 1
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return (nil, true) }
            // Without trustworthy package/link metadata never descend into an unknown directory.
            return (FilenameSearchEntry(url: url, isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                isSymbolicLink: info.st_mode & S_IFMT == S_IFLNK,
                isHidden: info.st_flags & UInt32(UF_HIDDEN) != 0 || url.lastPathComponent.hasPrefix(".")), true)
        }
    }
    func readBatch(maximum: Int) -> Batch {
        if isCancelled { return Batch(entries: [], finished: true, errorMessage: nil) }
        if !started {
            started = true
            var info = stat()
            guard lstat(path, &info) == 0 else { return Batch(entries: [], finished: true, errorMessage: errno == ENOENT ? nil : String(cString: strerror(errno))) }
            let root = URL(fileURLWithPath: path)
            let rootMetadata = entry(root)
            rootEntry = rootMetadata.0
            rootExists = rootEntry != nil
            if mode == .entry || info.st_mode & S_IFMT != S_IFDIR || rootMetadata.1 {
                return Batch(entries: rootEntry.map { [$0] } ?? [], finished: true, errorMessage: nil)
            }
            guard access(path, R_OK | X_OK) == 0 else {
                warningCount += 1
                directoryUnavailable = true
                return Batch(entries: [], finished: true, errorMessage: "Permission to search this folder was denied.")
            }
            enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey],
                options: mode == .shallow ? [.skipsPackageDescendants, .skipsSubdirectoryDescendants] : [.skipsPackageDescendants], errorHandler: { [weak self] _, _ in
                    self?.warningCount += 1; return self?.isCancelled != true
                })
            guard enumerator != nil else { return Batch(entries: [], finished: true, errorMessage: "This folder could not be enumerated.") }
        }
        var entries: [FilenameSearchEntry] = []
        if let rootEntry { entries.append(rootEntry); self.rootEntry = nil }
        var examined = 0
        while examined < maximum, !isCancelled {
            guard let url = enumerator?.nextObject() as? URL else { return Batch(entries: entries, finished: true, errorMessage: nil) }
            examined += 1
            if excluded.contains(url.path) { enumerator?.skipDescendants(); continue }
            let metadata = entry(url)
            if let item = metadata.0 { entries.append(item) }
            if metadata.1 || preserving.contains(url.path) { enumerator?.skipDescendants() }
        }
        return Batch(entries: entries, finished: false, errorMessage: nil)
    }
}
