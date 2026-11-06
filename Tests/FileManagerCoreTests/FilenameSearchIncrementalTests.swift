import Testing
import Foundation
import Darwin
import CoreServices
import SQLite3
@_spi(Testing) @testable import FileManagerCore

@Suite(.serialized)
@MainActor
final class FilenameSearchIncrementalTests {
    private let fixture: URL
    private let manager = FileManager.default
    private var indexes: [FilenameSearchIndex] = []

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        fixture = project.appendingPathComponent(".build/test-fixtures/incremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }
    deinit {
        for index in indexes { index.close() }
        try? FileManager.default.removeItem(at: fixture)
    }
    private func directory(_ name: String) throws -> URL {
        let url = fixture.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult private func file(_ name: String) throws -> URL {
        let url = fixture.appendingPathComponent(name)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }
    private func index(_ name: String = "catalog", batchSize: Int = 32, delay: TimeInterval = 0) -> FilenameSearchIndex {
        let value = FilenameSearchIndex(databaseURL: fixture.appendingPathComponent("\(name).sqlite"), scanBatchSize: batchSize, scanBatchDelay: delay)
        indexes.append(value)
        return value
    }
    private func wait(_ label: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: "Timed out: " + label))
        guard condition() else { throw CocoaError(.coderReadCorrupt) }
    }
    private func diagnostics(_ index: FilenameSearchIndex) async -> FilenameSearchDiagnostics {
        await withCheckedContinuation { continuation in index.diagnostics { continuation.resume(returning: $0) } }
    }
    private func waitForIncrement(_ index: FilenameSearchIndex, after count: Int) async throws -> FilenameSearchDiagnostics {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            let value = await diagnostics(index)
            if value.incrementalUpdateCount > count && value.activeScanCount == 0 { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    private func seed(_ index: FilenameSearchIndex, scope: URL, entries: [FilenameSearchEntry]) async throws {
        var finished = false, failure: Error?
        index.seedCatalog(in: scope, entries: entries) { failure = $0; finished = true }
        try await wait("seed") { finished }
        if let failure { throw failure }
    }
    private func complete(_ index: FilenameSearchIndex, scope: URL, query: String = "needle") async throws -> FilenameSearchSnapshot {
        var result: FilenameSearchSnapshot?
        let subscription = index.search(in: scope, query: query, includeHidden: true) {
            if $0.isComplete { result = $0 }
        }
        defer { subscription.cancel() }
        try await wait("complete") { result != nil }
        return try #require(result)
    }
    private func notify(_ index: FilenameSearchIndex, root: URL, path: URL, flags: UInt32) {
        index.receiveForTesting([FilenameSearchChange(path: path.path, eventID: 0, requiresFullRescan: false,
                                                     historyDone: false, flags: flags)], in: root)
    }
    private func paths(_ snapshot: FilenameSearchSnapshot?) -> Set<String> {
        Set(snapshot?.entries.map { $0.url.path } ?? [])
    }

    @Test func systemAliasSearchUsesPhysicalKeysWithoutFollowingSymlinkEntries() async throws {
        let name = "filename-search-" + UUID().uuidString
        let logical = URL(fileURLWithPath: "/tmp").appendingPathComponent(name, isDirectory: true)
        let physical = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: logical, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: logical) }
        let target = physical.appendingPathComponent("needle.txt")
        let link = physical.appendingPathComponent("needle-link")
        try Data().write(to: target)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let catalog = logical.appendingPathComponent("catalog.sqlite")
        let stale = logical.appendingPathComponent("needle-stale")
        do {
            let old = try FilenameSearchDatabase(url: catalog)
            try old.saveScope(logical.path, complete: true, warnings: 0, eventID: 0, device: 0, inode: 0, volumeID: nil)
            try old.upsert([FilenameSearchEntry(url: stale)], scan: 1)
        }
        let service = FilenameSearchIndex(databaseURL: catalog)
        defer { service.close() }
        let scanned = try await complete(service, scope: logical)
        #expect(paths(scanned) == [target.path, link.path])
        #expect(scanned.entries.first { $0.url == link }?.isSymbolicLink == true)
        #expect(try await complete(service, scope: physical, query: "catalog").entries.isEmpty)
        let db = try FilenameSearchDatabase(url: catalog, readOnly: true)
        #expect(try db.scopes().map { $0.0 } == [physical.path])
        #expect(try db.entry(at: stale.path) == nil)

        // Synthetic baselines have no watcher, so only this logical-path deletion
        // event can remove the physical key. The link's target must survive.
        try await seed(service, scope: logical, entries: scanned.entries)
        try manager.removeItem(at: link)
        notify(service, root: logical, path: logical.appendingPathComponent("needle-link"),
               flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsSymlink))
        let after = try await complete(service, scope: physical)
        #expect(paths(after) == [target.path])
    }

    @Test func contentOnlyChangesRefreshMatchingMetadataWithoutRecursiveWalksOrUnrelatedQueries() async throws {
        let scope = try directory("scope")
        let target = try file("scope/needle.txt")
        let quiet = try directory("scope/quiet")
        let quietFile = try file("scope/quiet/other.txt")
        let service = index()
        try await seed(service, scope: scope, entries: [FilenameSearchEntry(url: target), FilenameSearchEntry(url: quiet, isDirectory: true), FilenameSearchEntry(url: quietFile)])
        var targetSnapshots: [FilenameSearchSnapshot] = [], quietSnapshots: [FilenameSearchSnapshot] = []
        let targetRequest = service.search(in: scope, query: "needle", includeHidden: true) { targetSnapshots.append($0) }
        let quietRequest = service.search(in: quiet, query: "other", includeHidden: true) { quietSnapshots.append($0) }
        defer { targetRequest.cancel(); quietRequest.cancel() }
        try await wait("initial reads") { targetSnapshots.last?.isComplete == true && quietSnapshots.last?.isComplete == true }
        let before = await diagnostics(service), oldTargetCount = targetSnapshots.count, oldQuietCount = quietSnapshots.count
        try Data("changed content and size".utf8).write(to: target)
        notify(service, root: scope, path: target, flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
        let after = try await waitForIncrement(service, after: before.incrementalUpdateCount)
        try await wait("metadata read refresh") { targetSnapshots.count > oldTargetCount && targetSnapshots.last?.queryFinished == true }
        #expect(after.scanCount == before.scanCount)
        #expect(quietSnapshots.count == oldQuietCount)
        #expect(targetSnapshots.last?.isIndexing == false)
    }

    @Test func shallowMutationInvalidationDiscoversRenamedAndDeletedSubtrees() async throws {
        let scope = try directory("scope")
        let service = index()
        try await seed(service, scope: scope, entries: [])
        _ = try file("scope/old/deep/needle.txt")
        service.invalidate(in: scope, recursive: false)
        var result = try await complete(service, scope: scope)
        #expect(paths(result) == [scope.appendingPathComponent("old/deep/needle.txt").path])
        let afterCreate = await diagnostics(service)
        #expect(afterCreate.scanCount == 1, "Only the newly discovered subtree needs a recursive walk")
        let renamed = scope.appendingPathComponent("new", isDirectory: true)
        try manager.moveItem(at: scope.appendingPathComponent("old"), to: renamed)
        service.invalidate(in: scope, recursive: false)
        result = try await complete(service, scope: scope)
        #expect(paths(result) == [renamed.appendingPathComponent("deep/needle.txt").path])
        try manager.removeItem(at: renamed)
        service.invalidate(in: scope, recursive: false)
        result = try await complete(service, scope: scope)
        #expect(result.totalMatchCount == 0)
        let afterRemove = await diagnostics(service)
        #expect(afterRemove.scanCount == 2, "Rename scans its new subtree; parent membership and removal stay shallow")
        let db = try FilenameSearchDatabase(url: fixture.appendingPathComponent("catalog.sqlite"), readOnly: true)
        let diagnostic = await diagnostics(service)
        #expect(diagnostic.indexedEntryCount == (try db.scalar("SELECT count(*) FROM entries")))
    }

    @Test func queryCompletionIsIndependentOfBackgroundWorkInAnotherSubfolder() async throws {
        let scope = try directory("scope")
        let quiet = try directory("scope/quiet")
        let noisy = try directory("scope/noisy")
        let needle = try file("scope/quiet/needle.txt")
        var entries = [FilenameSearchEntry(url: quiet, isDirectory: true), FilenameSearchEntry(url: noisy, isDirectory: true), FilenameSearchEntry(url: needle)]
        for number in 0..<48 { entries.append(FilenameSearchEntry(url: try file("scope/noisy/log-\(number).txt"))) }
        let service = index(batchSize: 2, delay: 0.02)
        try await seed(service, scope: scope, entries: entries)
        notify(service, root: scope, path: noisy, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified))
        var homeSnapshots: [FilenameSearchSnapshot] = [], quietSnapshots: [FilenameSearchSnapshot] = []
        let homeRequest = service.search(in: scope, query: "needle", includeHidden: true) { homeSnapshots.append($0) }
        let quietRequest = service.search(in: quiet, query: "needle", includeHidden: true) { quietSnapshots.append($0) }
        defer { homeRequest.cancel(); quietRequest.cancel() }
        try await wait("independent query stages") {
            homeSnapshots.contains { $0.queryFinished && $0.isUpdating && !$0.isIndexing } && quietSnapshots.contains { $0.isComplete }
        }
        for _ in 0..<12 {
            notify(service, root: scope, path: noisy.appendingPathComponent("log-0.txt"), flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified))
            try await Task.sleep(for: .milliseconds(5))
        }
        try await wait("maintenance drained") { homeSnapshots.last?.isComplete == true }
        #expect(homeSnapshots.allSatisfy { !$0.isIndexing })
        #expect(quietSnapshots.allSatisfy { !$0.isIndexing && !$0.isUpdating })
        #expect(homeSnapshots.last?.totalMatchCount == 1)
    }

    @Test func eventsReceivedDuringABaselineAreReconciledAfterThatScan() async throws {
        let scope = try directory("scope")
        let original = try file("scope/needle-old.txt")
        for number in 0..<120 { _ = try file("scope/deep/file-\(number).txt") }
        let service = index(batchSize: 4, delay: 0.008)
        var latest: FilenameSearchSnapshot?
        let request = service.search(in: scope, query: "needle", includeHidden: true) { latest = $0 }
        defer { request.cancel() }
        try await wait("old entry already visited") { self.paths(latest).contains(original.path) && latest?.isIndexing == true }
        let renamed = scope.appendingPathComponent("needle-new.txt")
        try manager.moveItem(at: original, to: renamed)
        notify(service, root: scope, path: original, flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))
        notify(service, root: scope, path: renamed, flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))
        try await wait("post-scan dirty membership") { latest?.isComplete == true && self.paths(latest) == [renamed.path] }
    }

    @Test func queuedCompletionCannotOutliveNewlyScheduledWork() async throws {
        let scope = try directory("scope")
        let target = try file("scope/needle.txt")
        let service = index(delay: 0.2)
        try await seed(service, scope: scope, entries: [FilenameSearchEntry(url: target)])
        var snapshots: [FilenameSearchSnapshot] = []
        let request = service.search(in: scope, query: "needle", includeHidden: true) { snapshots.append($0) }
        defer { request.cancel() }
        // Deliberately hold the main actor until a real callback is queued, then
        // schedule work on the state queue before permitting that callback to run.
        var queued = false
        let deadline = Date().addingTimeInterval(3)
        while !queued, Date() < deadline {
            let semaphore = DispatchSemaphore(value: 0)
            service.pendingDeliveriesForTesting { queued = $0 > 0; semaphore.signal() }
            #expect(semaphore.wait(timeout: .now() + 1) == .success)
            if !queued { usleep(1_000) }
        }
        #expect(queued)
        let scheduled = DispatchSemaphore(value: 0)
        service.receiveForTesting([FilenameSearchChange(path: target.path, eventID: 0, requiresFullRescan: false,
            historyDone: false, flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified))], in: scope) { scheduled.signal() }
        #expect(scheduled.wait(timeout: .now() + 1) == .success)
        try await wait("old callback and later fresh completion") { snapshots.last?.isComplete == true }
        #expect(snapshots.first?.isComplete == false)
        #expect(snapshots.first?.isUpdating == true)
        #expect(snapshots.last?.queryFinished == true)
    }

    @Test func activatingAParentDoesNotDiscardPreservedChildBaselineJobs() async throws {
        let parent = try directory("parent")
        let a = try file("parent/a/needle-a.txt"), b = try file("parent/b/needle-b.txt")
        let first = index()
        _ = try await complete(first, scope: a.deletingLastPathComponent())
        _ = try await complete(first, scope: b.deletingLastPathComponent())
        first.close()
        let reopened = index(batchSize: 1, delay: 0.01)
        let result = try await complete(reopened, scope: parent)
        #expect(paths(result) == [a.path, b.path])
        #expect(!result.isIndexing)
    }

    @Test func aPreservedParentJobCannotAbsorbARequiredFullParentRefresh() async throws {
        let parent = try directory("parent"), child = try directory("parent/child"), busy = try directory("busy")
        for number in 0..<80 { _ = try file("busy/file-\(number).txt") }
        let phantom = child.appendingPathComponent("needle-stale.txt")
        let service = index(batchSize: 2, delay: 0.005)
        try await seed(service, scope: child, entries: [FilenameSearchEntry(url: phantom)])
        let busyRequest = service.search(in: busy, query: "file", includeHidden: true) { _ in }
        defer { busyRequest.cancel() }
        var latest: FilenameSearchSnapshot?
        let parentRequest = service.search(in: parent, query: "needle", includeHidden: true) { latest = $0 }
        defer { parentRequest.cancel() }
        service.invalidate(in: parent)
        try await wait("whole-parent refresh") { latest?.isComplete == true }
        #expect(latest?.totalMatchCount == 0)
    }

    @Test func restoringDirectoryPermissionsFindsChangesUnderKnownNestedDirectories() async throws {
        let scope = try directory("scope"), protected = try directory("scope/protected")
        let nested = try directory("scope/protected/known/deep")
        let old = try file("scope/protected/known/deep/needle-old.txt")
        let service = index()
        try await seed(service, scope: scope, entries: [FilenameSearchEntry(url: protected, isDirectory: true),
            FilenameSearchEntry(url: protected.appendingPathComponent("known"), isDirectory: true),
            FilenameSearchEntry(url: nested, isDirectory: true), FilenameSearchEntry(url: old)])
        let descriptor = open(nested.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor); chmod(protected.path, 0o700) }
        #expect(chmod(protected.path, 0) == 0)
        let newFile = openat(descriptor, "needle-new.txt", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        #expect(newFile >= 0)
        if newFile >= 0 { close(newFile) }
        #expect(chmod(protected.path, 0o700) == 0)
        notify(service, root: scope, path: protected, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemInodeMetaMod))
        let result = try await complete(service, scope: scope)
        #expect(paths(result) == [old.path, nested.appendingPathComponent("needle-new.txt").path])
    }

    @Test func parentKeyCollisionsCannotSelectOrDeleteAnotherFoldersChildren() throws {
        let a = try file("a/a.txt"), b = try file("b/b.txt")
        let database = try FilenameSearchDatabase(url: fixture.appendingPathComponent("collision.sqlite"))
        #expect(try database.upsert([FilenameSearchEntry(url: a), FilenameSearchEntry(url: b)], scan: 1) == 2)
        let key = FilenameSearchDatabase.parentKey(for: a.deletingLastPathComponent().path)
        try database.execute("UPDATE entries SET parent_key=\(key) WHERE name='b.txt'")
        let children = try database.unseenChildren(in: a.deletingLastPathComponent().path, scan: 2)
        #expect(children == [a.path])
        for path in children { try database.deleteSubtree(path) }
        #expect(try database.entry(at: b.path) != nil)
    }

    @Test func oldCatalogMigrationPreservesRowsAndLazilyAddsParentKeys() throws {
        let url = fixture.appendingPathComponent("old-schema.sqlite"), child = try file("scope/needle.txt")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        let schema = "CREATE TABLE entries(path TEXT PRIMARY KEY,name TEXT NOT NULL,folded TEXT NOT NULL,flags INTEGER NOT NULL,non_ascii INTEGER NOT NULL,scan INTEGER NOT NULL)"
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO entries VALUES(?,'needle.txt','needle.txt',0,0,1)", -1, &statement, nil) == SQLITE_OK)
        let insert = try #require(statement)
        child.path.withCString { _ = sqlite3_bind_text(insert, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(insert) == SQLITE_DONE)
        sqlite3_finalize(insert); sqlite3_close(db)
        let migrated = try FilenameSearchDatabase(url: url)
        #expect(try migrated.entry(at: child.path) != nil)
        #expect(try migrated.scalar("SELECT count(*) FROM entries WHERE parent_key IS NULL") == 1)
        #expect(try migrated.upsert([FilenameSearchEntry(url: child)], scan: 2) == 0)
        #expect(try migrated.unseenChildren(in: child.deletingLastPathComponent().path, scan: 3) == [child.path])
    }
}
