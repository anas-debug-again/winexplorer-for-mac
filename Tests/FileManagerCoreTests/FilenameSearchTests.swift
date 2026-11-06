import Testing
import Foundation
import Darwin
@_spi(Testing) @testable import FileManagerCore

@Suite(.serialized)
@MainActor
final class FilenameSearchTests {
    private let fixture: URL
    private let manager = FileManager.default
    private var indexes: [FilenameSearchIndex] = []

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        fixture = project.appendingPathComponent(".build/test-fixtures/search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }
    deinit {
        for index in indexes { index.close() }
        try? FileManager.default.removeItem(at: fixture)
    }

    private func directory(_ relative: String) throws -> URL {
        let url = fixture.appendingPathComponent(relative, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult private func file(_ relative: String, contents: String = "fixture") throws -> URL {
        let url = fixture.appendingPathComponent(relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    private func index(_ name: String = "index", batchSize: Int = 128, delay: TimeInterval = 0,
                       queryDelay: TimeInterval = 0) -> FilenameSearchIndex {
        let value = FilenameSearchIndex(databaseURL: fixture.appendingPathComponent("\(name).sqlite"),
                                        scanBatchSize: batchSize, scanBatchDelay: delay, queryBatchDelay: queryDelay)
        indexes.append(value)
        return value
    }
    private func wait(_ label: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        #expect(condition(), Comment(rawValue: "Timed out: " + label))
        guard condition() else { throw CocoaError(.coderReadCorrupt) }
    }
    private func diagnostics(_ index: FilenameSearchIndex) async -> FilenameSearchDiagnostics {
        await withCheckedContinuation { continuation in index.diagnostics { continuation.resume(returning: $0) } }
    }
    private func complete(_ index: FilenameSearchIndex, scope: URL, query: String,
                          hidden: Bool = false, limit: Int = 1_000) async throws -> FilenameSearchSnapshot {
        var terminal: FilenameSearchSnapshot?
        let subscription = index.search(in: scope, query: query, includeHidden: hidden, limit: limit) { snapshot in
            #expect(Thread.isMainThread)
            if snapshot.isComplete { terminal = snapshot }
        }
        defer { subscription.cancel() }
        try await wait("complete search: \(query)") { terminal != nil }
        return try #require(terminal)
    }
    private func paths(_ snapshot: FilenameSearchSnapshot) -> Set<String> { Set(snapshot.entries.map { $0.url.path }) }
    private func seed(_ index: FilenameSearchIndex, scope: URL, entries: [FilenameSearchEntry]) async throws {
        var finished = false, error: Error?
        index.seedCatalog(in: scope, entries: entries) { error = $0; finished = true }
        try await wait("synthetic catalog seed") { finished }
        if let error { throw error }
    }

    @Test func nestedSearchMatchesFilenamesRatherThanParentPathsOrContents() async throws {
        let scope = try directory("scope")
        let direct = try file("scope/needle-direct.txt")
        let nested = try file("scope/deep/inside/NEEDLE-nested.md")
        _ = try file("scope/needle-parent/unrelated.txt", contents: "needle in contents is not a filename")
        _ = try file("scope/unrelated.txt", contents: "needle only in contents")
        let index = index()
        let result = try await complete(index, scope: scope, query: "needle")
        #expect(paths(result) == [direct.path, nested.path, scope.appendingPathComponent("needle-parent").path])
        #expect(result.totalMatchCount == 3 && result.warningCount == 0 && result.errorMessage == nil)
    }

    @Test func matchingIsLiteralCaseAndDiacriticInsensitiveAndSupportsArabicAndShortQueries() async throws {
        let scope = try directory("scope")
        let names = ["Résumé.TXT", "سجل المشروع.txt", "x.txt", "report%_literal.txt", "reportZZliteral.txt",
                     "[draft]*\"quote.txt", "and OR not.txt", "decomposed-e\u{301}.txt"]
        for name in names { try file("scope/" + name) }
        let index = index()
        for (query, matches) in [
            ("resume", ["Résumé.TXT"]), ("RÉSUMÉ", ["Résumé.TXT"]), ("المشروع", ["سجل المشروع.txt"]),
            ("س", ["سجل المشروع.txt"]), ("x.", ["x.txt"]), ("%_", ["report%_literal.txt"]),
            ("[draft]*\"", ["[draft]*\"quote.txt"]), ("and OR not", ["and OR not.txt"]),
            ("decomposed-é", ["decomposed-e\u{301}.txt"])
        ] {
            let result = try await complete(index, scope: scope, query: query)
            #expect(Set(result.entries.map(\.name)) == Set(matches), Comment(rawValue: "Literal query: " + query))
            #expect(result.totalMatchCount == matches.count)
        }
    }

    @Test func hiddenAncestorsAreExcludedOnlyRelativeToRequestedScope() async throws {
        let scope = try directory("scope")
        let visible = try file("scope/visible-match.txt")
        let dot = try file("scope/.hidden-match.txt")
        let belowDot = try file("scope/.hidden-folder/visible-match.txt")
        let flagged = try directory("scope/flagged-folder")
        let belowFlag = try file("scope/flagged-folder/flagged-match.txt")
        #expect(chflags(flagged.path, UInt32(UF_HIDDEN)) == 0)
        defer { chflags(flagged.path, 0) }
        let index = index()
        let filtered = try await complete(index, scope: scope, query: "match")
        #expect(paths(filtered) == [visible.path])
        let all = try await complete(index, scope: scope, query: "match", hidden: true)
        #expect(paths(all) == [visible.path, dot.path, belowDot.path, belowFlag.path])
        // The fixture itself lives below .build; explicit scopes must not inherit hidden ancestors outside the scope.
        let explicit = try await complete(index, scope: belowDot.deletingLastPathComponent(), query: "match")
        #expect(paths(explicit) == [belowDot.path])
    }

    @Test func unicodeCandidateSearchAgreesWithFoundationSubstringOracle() async throws {
        let scope = try directory("scope")
        let names = ["ﬁle-notes.txt", "Ｆｉｌｅ-width.txt", "Straße.txt", "STRASSE-copy.txt",
                     "encyclopædia.txt", "encyclopaedia-copy.txt", "مُستند.txt", "ordinary.txt"]
        for name in names { try file("scope/" + name) }
        let index = index()
        for query in ["file", "ﬁle", "ＦＩＬＥ", "strasse", "straße", "ædia", "aedia", "مستند", "مُستند"] {
            let expected = Set(names.filter { $0.localizedStandardContains(query) })
            let result = try await complete(index, scope: scope, query: query)
            #expect(Set(result.entries.map(\.name)) == expected,
                    Comment(rawValue: "Indexed candidates must not omit Foundation matches for " + query))
            #expect(result.totalMatchCount == expected.count)
        }
    }

    @Test func packagesAndDirectorySymlinksAreEntriesButAreNeverTraversed() async throws {
        let scope = try directory("scope")
        let package = try directory("scope/Needle.app")
        _ = try file("scope/Needle.app/Contents/needle-secret.txt")
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundlePackageType</key><string>APPL</string></dict></plist>".utf8)
            .write(to: package.appendingPathComponent("Contents/Info.plist"))
        let outside = try directory("outside")
        _ = try file("outside/needle-outside.txt")
        let link = scope.appendingPathComponent("needle-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let loop = scope.appendingPathComponent("needle-loop")
        try manager.createSymbolicLink(at: loop, withDestinationURL: scope)
        let broken = scope.appendingPathComponent("needle-broken")
        try manager.createSymbolicLink(at: broken, withDestinationURL: fixture.appendingPathComponent("missing"))
        let result = try await complete(index(), scope: scope, query: "needle")
        #expect(paths(result) == [package.path, link.path, loop.path, broken.path])
        #expect(result.entries.first { $0.url.path == package.path }?.isPackage == true)
        #expect(result.entries.filter(\.isSymbolicLink).count == 3)
    }

    @Test func resultCapsRetainHonestTotalAndUnlimitedRequestsReturnAllMatches() async throws {
        let scope = try directory("scope")
        for i in 0..<73 { try file("scope/match-\(i).txt") }
        let index = index()
        let bounded = try await complete(index, scope: scope, query: "match", limit: 7)
        #expect(bounded.entries.count == 7 && bounded.totalMatchCount == 73)
        #expect(Set(bounded.entries.map { $0.url.path }).count == 7)
        let unlimited = try await complete(index, scope: scope, query: "match", limit: 0)
        #expect(unlimited.entries.count == 73 && unlimited.totalMatchCount == 73)
        let absent = try await complete(index, scope: scope, query: "missing")
        #expect(absent.entries.isEmpty && absent.totalMatchCount == 0 && absent.errorMessage == nil)
    }

    @Test func packageInteriorEventsCannotBypassTheInitialTraversalBoundary() async throws {
        let scope = try directory("scope")
        let package = try directory("scope/Needle.app")
        let interior = try directory("scope/Needle.app/Contents/sub")
        let index = index()
        var snapshots: [FilenameSearchSnapshot] = []
        let subscription = index.search(in: scope, query: "needle", includeHidden: false) { snapshots.append($0) }
        defer { subscription.cancel() }
        try await wait("initial package exclusion") { snapshots.last?.isComplete == true }
        #expect(snapshots.last.map(paths) == [package.path])
        let observedBeforeMutation = snapshots.count
        _ = try file("scope/Needle.app/Contents/sub/needle-added.txt")
        index.invalidate(in: interior)
        // A correct implementation may ignore this event completely, so do not require a new scan.
        try await Task.sleep(for: .milliseconds(750))
        try await wait("package event reconciliation settled") { snapshots.last?.isComplete == true }
        #expect(snapshots.dropFirst(observedBeforeMutation).allSatisfy { paths($0).isSubset(of: [package.path]) },
                "Neither an intermediate nor complete update may leak package descendants")
        let fresh = try await complete(index, scope: scope, query: "needle")
        #expect(paths(fresh) == [package.path])
    }

    @Test func cancelledSubscriberStopsReceivingUpdatesWhileAnotherQueryReusesTheActualScan() async throws {
        let scope = try directory("scope")
        for i in 0..<800 { try file("scope/nested/item-\(i).txt") }
        let index = index(batchSize: 16, delay: 0.004)
        var oldEvents = 0, oldPartial = false, final: FilenameSearchSnapshot?
        let old = index.search(in: scope, query: "item", includeHidden: false) { snapshot in
            oldEvents += 1
            if !snapshot.isComplete && !snapshot.entries.isEmpty { oldPartial = true }
        }
        defer { old.cancel() }
        try await wait("actual scan has emitted a nonempty partial result") { oldPartial }
        let before = await diagnostics(index)
        #expect(before.activeScanCount > 0 && before.scanCount == 1)
        let current = index.search(in: scope, query: "item-79", includeHidden: false) { snapshot in
            #expect(Thread.isMainThread)
            if snapshot.isComplete { final = snapshot }
        }
        defer { current.cancel() }
        old.cancel()
        let countAtCancel = oldEvents
        try await wait("replacement query finishes shared scan") { final != nil }
        let after = await diagnostics(index)
        #expect(oldEvents == countAtCancel, "Cancellation must suppress already queued and later callbacks")
        #expect(after.scanCount == 1, "Typing a new query must not restart the filesystem traversal")
        #expect(final?.totalMatchCount == 11)
    }

    @Test func completedIndexIsReusedForDifferentQueriesWithoutASecondScan() async throws {
        let scope = try directory("scope")
        _ = try file("scope/alpha.txt"); _ = try file("scope/beta.txt")
        let index = index()
        _ = try await complete(index, scope: scope, query: "alpha")
        let before = await diagnostics(index)
        let result = try await complete(index, scope: scope, query: "beta")
        let after = await diagnostics(index)
        #expect(result.entries.map(\.name) == ["beta.txt"])
        #expect(after.scanCount == before.scanCount && after.queryCount > before.queryCount)
    }

    @Test func cancellingAnActivelyProcessingBroadQueryDoesNotBlockTheReplacementQuery() async throws {
        let scope = try directory("scope")
        let index = index(queryDelay: 0.03)
        let entries = (0..<6_000).map { FilenameSearchEntry(url: scope.appendingPathComponent("record-\($0).txt")) }
        try await seed(index, scope: scope, entries: entries)
        var oldEvents: [FilenameSearchSnapshot] = []
        let old = index.search(in: scope, query: "r", includeHidden: false, limit: 20) { oldEvents.append($0) }
        defer { old.cancel() }
        try await wait("broad query has processed actual catalog rows") {
            oldEvents.contains { !$0.isComplete && $0.totalMatchCount > 0 }
        }
        let oldCompletedBeforeCancellation = oldEvents.contains { $0.isComplete }
        #expect(!oldCompletedBeforeCancellation)
        old.cancel()
        let countAtCancel = oldEvents.count
        let replacement = try await complete(index, scope: scope, query: "record-5999.txt")
        #expect(replacement.totalMatchCount == 1 && paths(replacement) == [entries[5_999].url.path])
        // The second worker can finish before the old worker wakes; give its cancellation checkpoint time to run.
        try await Task.sleep(for: .milliseconds(100))
        #expect(oldEvents.count == countAtCancel, "Cancelled query progress or completion must not reach its old subscriber")
        let diagnostic = await diagnostics(index)
        #expect(diagnostic.scanCount == 0, "A replacement query over the seeded catalog must not enumerate files")
    }

    @Test func invalidationDuringAnActiveBroadQueryCannotPublishStaleCompleteResults() async throws {
        let scope = try directory("scope")
        let retained = try file("scope/record-retained.txt")
        let index = index(queryDelay: 0.03)
        let entries = (0..<6_000).map { FilenameSearchEntry(url: scope.appendingPathComponent("record-\($0).txt")) }
            + [FilenameSearchEntry(url: retained)]
        try await seed(index, scope: scope, entries: entries)
        var updates: [FilenameSearchSnapshot] = []
        let subscription = index.search(in: scope, query: "r", includeHidden: false, limit: 20) { updates.append($0) }
        defer { subscription.cancel() }
        try await wait("broad query before invalidation") { updates.contains { !$0.isComplete && $0.totalMatchCount > 0 } }
        let observedBeforeInvalidation = updates.count
        // The seed represents an old persisted catalog. Reconciliation sees the one actual remaining file.
        index.invalidate(in: scope)
        _ = await diagnostics(index) // Barrier: the state queue has accepted the invalidation.
        try await wait("reconciled broad query result") {
            updates.last?.isComplete == true && updates.last.map(self.paths) == [retained.path]
        }
        #expect(updates.dropFirst(observedBeforeInvalidation).filter(\.isComplete).allSatisfy {
            $0.totalMatchCount == 1 && paths($0) == [retained.path]
        }, "An obsolete read snapshot must never announce completion after reconciliation has been requested")
    }

    @Test func descendantCreateRenameAndDeleteReachALiveSubscription() async throws {
        let scope = try directory("scope")
        _ = try directory("scope/one/two")
        let index = index()
        var latest: FilenameSearchSnapshot?
        let subscription = index.search(in: scope, query: "needle", includeHidden: false) { latest = $0 }
        defer { subscription.cancel() }
        try await wait("initial live index") { latest?.isComplete == true }
        let created = try file("scope/one/two/needle-created.txt")
        try await wait("descendant creation") { latest?.isComplete == true && latest.map(self.paths) == [created.path] }
        let renamed = created.deletingLastPathComponent().appendingPathComponent("needle-renamed.txt")
        try manager.moveItem(at: created, to: renamed)
        try await wait("descendant rename") { latest?.isComplete == true && latest.map(self.paths) == [renamed.path] }
        try manager.removeItem(at: renamed)
        try await wait("descendant removal") { latest?.isComplete == true && latest?.totalMatchCount == 0 }
    }

    @Test func invalidationReconcilesChangedEntriesAndFolderRenames() async throws {
        let scope = try directory("scope")
        let old = try file("scope/old/needle.txt")
        let index = index()
        _ = try await complete(index, scope: scope, query: "needle")
        let renamed = scope.appendingPathComponent("new", isDirectory: true)
        try manager.moveItem(at: old.deletingLastPathComponent(), to: renamed)
        index.invalidate(in: scope)
        let result = try await complete(index, scope: scope, query: "needle")
        #expect(paths(result) == [renamed.appendingPathComponent("needle.txt").path])
    }

    @Test func persistentRestartCatchesChangesMadeWhileTheIndexWasClosed() async throws {
        let scope = try directory("scope")
        let removed = try file("scope/nested/needle-old.txt")
        var first: FilenameSearchIndex? = index()
        _ = try await complete(first!, scope: scope, query: "needle")
        first?.close()
        first = nil
        let rootModifiedBefore = try manager.attributesOfItem(atPath: scope.path)[.modificationDate] as? Date
        try manager.removeItem(at: removed)
        let created = try file("scope/nested/needle-new.txt")
        let rootModifiedAfter = try manager.attributesOfItem(atPath: scope.path)[.modificationDate] as? Date
        #expect(rootModifiedAfter == rootModifiedBefore, "The fixture must exercise deep changes without changing the scope root's mtime")
        let reopened = index()
        var snapshots: [FilenameSearchSnapshot] = []
        let subscription = reopened.search(in: scope, query: "needle", includeHidden: false) { snapshots.append($0) }
        defer { subscription.cancel() }
        try await wait("restart reconciliation") { snapshots.last?.isComplete == true }
        let final = try #require(snapshots.last)
        #expect(paths(final) == [created.path], "A complete result must never claim a stale persisted catalog is current")
        #expect(snapshots.filter(\.isComplete).allSatisfy { paths($0) == [created.path] })
        #expect(manager.fileExists(atPath: fixture.appendingPathComponent("index.sqlite").path))
    }

    @Test func overlappingScopesNeverLeakSiblingPrefixMatchesOrDuplicateRows() async throws {
        let scope = try directory("scope")
        let inner = try directory("scope/sub")
        let inside = try file("scope/sub/needle.txt")
        let sibling = try file("scope/submarine/needle.txt")
        let index = index()
        let parentResult = try await complete(index, scope: scope, query: "needle")
        #expect(paths(parentResult) == [inside.path, sibling.path])
        let childResult = try await complete(index, scope: inner, query: "needle")
        #expect(paths(childResult) == [inside.path] && childResult.totalMatchCount == 1)
        let again = try await complete(index, scope: scope, query: "needle")
        #expect(again.entries.count == 2 && again.totalMatchCount == 2)
    }

    @Test func invalidScopeReportsErrorAndUnreadableDescendantsRemainHonest() async throws {
        let index = index()
        let missing = try await complete(index, scope: fixture.appendingPathComponent("missing"), query: "x")
        #expect(missing.errorMessage != nil && missing.entries.isEmpty)
        guard geteuid() != 0 else { return }
        let scope = try directory("scope")
        let blocked = try directory("scope/blocked")
        _ = try file("scope/blocked/needle.txt")
        let visible = try file("scope/needle-visible.txt")
        #expect(chmod(blocked.path, 0o000) == 0)
        defer { chmod(blocked.path, 0o700) }
        let result = try await complete(index, scope: scope, query: "needle")
        #expect(paths(result) == [visible.path])
        #expect(result.warningCount > 0 || result.errorMessage != nil,
                "Unreadable descendants must not be presented as a complete error-free search")
    }
}
