import Testing
import Foundation
@_spi(Testing) @testable import FileManagerCore

@Suite(.serialized)
@MainActor
final class FilenameSearchRelevanceTests {
    private let fixture: URL
    private let manager = FileManager.default
    private var indexes: [FilenameSearchIndex] = []

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        fixture = project.appendingPathComponent(".build/test-fixtures/search-relevance-\(UUID().uuidString)", isDirectory: true)
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
    @discardableResult private func file(_ relative: String) throws -> URL {
        let url = fixture.appendingPathComponent(relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }
    private func index() -> FilenameSearchIndex {
        let index = FilenameSearchIndex(databaseURL: fixture.appendingPathComponent("index-\(indexes.count).sqlite"))
        indexes.append(index)
        return index
    }
    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: "Timed out: " + label))
        guard condition() else { throw CocoaError(.coderReadCorrupt) }
    }
    private func seed(_ index: FilenameSearchIndex, scope: URL, entries: [FilenameSearchEntry]) async throws {
        var finished = false, error: Error?
        index.seedCatalog(in: scope, entries: entries) { error = $0; finished = true }
        try await wait("seed relevance catalog") { finished }
        if let error { throw error }
    }
    private func search(_ index: FilenameSearchIndex, scope: URL, query: String, limit: Int = 1_000,
                        order: FilenameSearchOrder = .bestMatch, excludeGenerated: Bool = false,
                        hidden: Bool = true) async throws -> FilenameSearchSnapshot {
        var result: FilenameSearchSnapshot?
        let subscription = index.search(in: scope, query: query, includeHidden: hidden, limit: limit,
                                        order: order, excludeGenerated: excludeGenerated) { snapshot in
            #expect(Thread.isMainThread)
            if snapshot.isComplete { result = snapshot }
        }
        defer { subscription.cancel() }
        try await wait("relevance query \(query)") { result != nil }
        let snapshot = try #require(result)
        #expect(snapshot.errorMessage == nil)
        return snapshot
    }
    private func paths(_ result: FilenameSearchSnapshot) -> [String] { result.entries.map { $0.url.path } }

    @Test func exactAndPrefixMatchesBeyondTheFirstThousandAreRankedBeforeTheLimit() async throws {
        let scope = try directory("scope")
        let index = index()
        var entries = (0..<1_500).map {
            FilenameSearchEntry(url: scope.appendingPathComponent(String(format: "a-needle-%04d.txt", $0)))
        }
        let exact = scope.appendingPathComponent("zz/deep/needle")
        let shallowPrefix = scope.appendingPathComponent("needle-z.txt")
        let deepPrefix = scope.appendingPathComponent("level/needle-a.txt")
        entries += [FilenameSearchEntry(url: exact), FilenameSearchEntry(url: shallowPrefix), FilenameSearchEntry(url: deepPrefix)]
        try await seed(index, scope: scope, entries: entries)
        let named = try await search(index, scope: scope, query: "needle", limit: 2, order: .name)
        #expect(named.entries.map(\.name) == ["a-needle-0000.txt", "a-needle-0001.txt"])
        let ranked = try await search(index, scope: scope, query: "needle", limit: 3)
        #expect(paths(ranked) == [exact.path, shallowPrefix.path, deepPrefix.path])
        #expect(ranked.totalMatchCount == 1_503 && ranked.entries.count == 3)
        let tiny = try await search(index, scope: scope, query: "needle", limit: 1)
        #expect(paths(tiny) == [exact.path] && tiny.totalMatchCount == 1_503)
    }

    @Test func rankThenDepthThenFolderAndNaturalNameOrderProduceStablePages() async throws {
        let scope = try directory("scope")
        let index = index()
        let entries = [
            FilenameSearchEntry(url: scope.appendingPathComponent("needle-z-folder"), isDirectory: true),
            FilenameSearchEntry(url: scope.appendingPathComponent("needle-10.txt")),
            FilenameSearchEntry(url: scope.appendingPathComponent("needle-2.txt")),
            FilenameSearchEntry(url: scope.appendingPathComponent("b/needle-same.txt")),
            FilenameSearchEntry(url: scope.appendingPathComponent("a/needle-same.txt")),
            FilenameSearchEntry(url: scope.appendingPathComponent("deep/more/needle")),
            FilenameSearchEntry(url: scope.appendingPathComponent("contains-needle.txt"))
        ]
        try await seed(index, scope: scope, entries: Array(entries.reversed()))
        let all = try await search(index, scope: scope, query: "needle", limit: 0)
        let expected = ["deep/more/needle", "needle-z-folder", "needle-2.txt", "needle-10.txt",
                        "a/needle-same.txt", "b/needle-same.txt", "contains-needle.txt"].map { scope.appendingPathComponent($0).path }
        #expect(paths(all) == expected)
        for limit in [1, 2, 4, 6, 100] {
            let page = try await search(index, scope: scope, query: "needle", limit: limit)
            #expect(paths(page) == Array(expected.prefix(limit)))
            #expect(page.totalMatchCount == expected.count)
        }
        let repeated = try await search(index, scope: scope, query: "needle", limit: 4)
        #expect(paths(repeated) == Array(expected.prefix(4)))
    }

    @Test func unicodeExactAndPrefixRankingUsesTheSameMatchingSemanticsAsFiltering() async throws {
        let scope = try directory("scope")
        let index = index()
        let groups = [
            ("resume", ["Résumé", "RÉSUMÉ-final.txt", "a résumé notes.txt"]),
            ("STRASSE", ["Straße", "Straße-old.txt", "a Straße notes.txt"]),
            ("file", ["ﬁle", "ﬁle-old.txt", "a ﬁle notes.txt"]),
            ("مستند", ["مُستند", "مستند-final.txt", "a مستند notes.txt"])
        ]
        let entries = groups.flatMap { $0.1 }.map { FilenameSearchEntry(url: scope.appendingPathComponent($0)) }
        try await seed(index, scope: scope, entries: entries)
        for (query, names) in groups {
            let result = try await search(index, scope: scope, query: query, limit: 0)
            #expect(names.allSatisfy { $0.localizedStandardContains(query) })
            #expect(result.entries.map(\.name) == names, Comment(rawValue: "Unicode relevance for " + query))
            #expect(result.totalMatchCount == 3)
        }
    }

    @Test func generatedExclusionsAreReversibleAndDoNotHideOrdinaryUserFolderNames() async throws {
        let scope = try directory("scope")
        let excluded = [
            "node_modules/pkg/needle.js", "Nested/NODE_MODULES/pkg/needle.js", ".git/needle.txt",
            ".svn/needle.txt", ".hg/needle.txt", ".build/needle.txt", ".swiftpm/needle.txt",
            "__pycache__/needle.pyc", ".pytest_cache/needle.txt", ".mypy_cache/needle.txt",
            ".ruff_cache/needle.txt", ".next/needle.txt", ".nuxt/needle.txt", ".cache/needle.txt",
            ".gradle/needle.txt", "Library/Caches/tool/needle.txt",
            "Library/Developer/Xcode/DerivedData/App/needle.txt", ".claude/projects/session/needle.txt",
            ".codex/artifacts/session/needle.txt", ".npm/_cacache/needle.txt", ".yarn/cache/needle.txt"
        ]
        let kept = [
            "needle.txt", "build/needle.txt", "dist/needle.txt", "bin/needle.txt", "obj/needle.txt",
            "coverage/needle.txt", "DerivedData/needle.txt", "Caches/needle.txt", "projects/needle.txt",
            "my-node_modules/needle.txt", "node_modules-not/needle.txt", "SomeLibrary/Caches/needle.txt",
            "Library/CachesNotes/needle.txt", ".claude/settings/needle.txt", ".codex/config/needle.txt"
        ]
        for path in excluded + kept { try file("scope/" + path) }
        let index = index()
        let all = try await search(index, scope: scope, query: "needle", limit: 0)
        #expect(all.totalMatchCount == excluded.count + kept.count)
        let filtered = try await search(index, scope: scope, query: "needle", limit: 0, excludeGenerated: true)
        #expect(Set(paths(filtered)) == Set(kept.map { scope.appendingPathComponent($0).path }))
        #expect(filtered.totalMatchCount == kept.count)
        let restored = try await search(index, scope: scope, query: "needle", limit: 0)
        #expect(Set(paths(restored)) == Set(paths(all)), "Excluding generated results must not delete them from the catalog")
        let directoryResult = try await search(index, scope: scope, query: "node_modules", limit: 0, excludeGenerated: true)
        #expect(!directoryResult.entries.contains { ["node_modules", "NODE_MODULES"].contains($0.name) })
        #expect(directoryResult.entries.contains { $0.name == "my-node_modules" })
        let allNames = try await search(index, scope: scope, query: "", limit: 0)
        let filteredNames = try await search(index, scope: scope, query: "", limit: 0, excludeGenerated: true)
        let expectedNames = allNames.entries.filter {
            FilenameSearchFilter.includes(url: $0.url, in: scope, excludeGenerated: true)
        }
        #expect(Set(paths(filteredNames)) == Set(expectedNames.map { $0.url.path }),
                "Cached parent decisions must also filter generated directories and sequence endings themselves")
    }

    @Test func explicitGeneratedRootSearchRemainsUsefulAndFiltersOnlyDescendants() async throws {
        let scope = try directory("scope")
        let modules = try directory("scope/node_modules")
        let caches = try directory("scope/Library/Caches")
        let wantedModule = try file("scope/node_modules/pkg/needle.js")
        let wantedCache = try file("scope/Library/Caches/tool/needle.txt")
        _ = try file("scope/node_modules/.cache/needle.txt")
        let index = index()
        let parent = try await search(index, scope: scope, query: "needle", limit: 0, excludeGenerated: true)
        #expect(parent.entries.isEmpty)
        let explicitModules = try await search(index, scope: modules, query: "needle", limit: 0, excludeGenerated: true)
        #expect(paths(explicitModules) == [wantedModule.path])
        let explicitCaches = try await search(index, scope: caches, query: "needle", limit: 0, excludeGenerated: true)
        #expect(paths(explicitCaches) == [wantedCache.path])
        #expect(FilenameSearchFilter.includes(url: wantedModule, in: modules, excludeGenerated: true))
        #expect(!FilenameSearchFilter.includes(url: wantedModule, in: scope, excludeGenerated: true))
    }

    @Test func hiddenPreferenceAndGeneratedExclusionRemainIndependent() async throws {
        let scope = try directory("scope")
        let ordinary = try file("scope/needle.txt")
        let hidden = try file("scope/.personal/needle.txt")
        let generated = try file("scope/node_modules/needle.txt")
        let index = index()
        let visible = try await search(index, scope: scope, query: "needle", excludeGenerated: false, hidden: false)
        #expect(Set(paths(visible)) == [ordinary.path, generated.path])
        let filtered = try await search(index, scope: scope, query: "needle", excludeGenerated: true, hidden: false)
        #expect(paths(filtered) == [ordinary.path])
        let includeHidden = try await search(index, scope: scope, query: "needle", excludeGenerated: true, hidden: true)
        #expect(Set(paths(includeHidden)) == [ordinary.path, hidden.path])
    }

    @Test func intermediateAncestorsStillExcludeKnownCacheSequences() async throws {
        let library = try directory("scope/Library")
        let xcode = try directory("scope/Library/Developer/Xcode")
        let claude = try directory("scope/.claude")
        _ = try file("scope/Library/Caches/tool/needle-cache.txt")
        _ = try file("scope/Library/Developer/Xcode/DerivedData/needle-generated.txt")
        let document = try file("scope/Library/Documents/needle-document.txt")
        _ = try file("scope/.claude/projects/session/needle-generated.txt")
        let setting = try file("scope/.claude/settings/needle-setting.txt")
        let index = index()
        let fromLibrary = try await search(index, scope: library, query: "needle", excludeGenerated: true)
        #expect(paths(fromLibrary) == [document.path])
        let fromXcode = try await search(index, scope: xcode, query: "needle", excludeGenerated: true)
        #expect(fromXcode.entries.isEmpty)
        let fromClaude = try await search(index, scope: claude, query: "needle", excludeGenerated: true)
        #expect(paths(fromClaude) == [setting.path])
    }
}
