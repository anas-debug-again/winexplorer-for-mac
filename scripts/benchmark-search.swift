// Opt-in release benchmark; no user directories are scanned or changed.
// Build the release core, then compile from the project directory:
// xcrun swiftc -O -parse-as-library -I .build/release/Modules scripts/benchmark-search.swift \
//   .build/release/FileManagerCore.build/*.swift.o -lsqlite3 -framework CoreServices \
//   -o .build/qa/benchmark-search
// .build/qa/benchmark-search
// Options: --counts 100000,1000000 --real-files 10000 --queries 100 --keep
//          --order name|bestMatch --exclude-generated
// Synthetic rows exercise the actual database/query engine; they are not real files.
// Cold catalog queries use a fresh service on a newly seeded catalog, not a purged OS page cache.
import Foundation
import Darwin
@_spi(Testing) import FileManagerCore

private struct SearchBenchmarkFailure: Error, CustomStringConvertible { let description: String }

@main struct SearchBenchmark {
    private static let clock = ContinuousClock()
    private static var selectedOrder: FilenameSearchOrder = .name
    private static var selectedOrderName = "name"
    private static var excludeGenerated = false
    private static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private static func option(_ key: String, fallback: String) -> String {
        guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return fallback }
        return CommandLine.arguments[i + 1]
    }
    private static func pump(until condition: () -> Bool, timeout: TimeInterval = 300) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
        if !condition() { throw SearchBenchmarkFailure(description: "Benchmark operation exceeded \(timeout) seconds") }
    }
    private struct QueryTiming: Codable {
        let query: String
        let firstUpdateMS: Double
        let firstResultMS: Double?
        let completeMS: Double
        let matches: Int
        let returned: Int
        let updates: Int
    }
    private static func query(_ index: FilenameSearchIndex, scope: URL, text: String, limit: Int = 1_000) throws -> QueryTiming {
        let start = clock.now
        var firstUpdate: Double?, firstResult: Double?, completed: Double?
        var latest: FilenameSearchSnapshot?, updates = 0
        let subscription = index.search(in: scope, query: text, includeHidden: false, limit: limit,
                                        order: selectedOrder, excludeGenerated: excludeGenerated) { snapshot in
            updates += 1
            if firstUpdate == nil { firstUpdate = seconds(start) }
            if !snapshot.entries.isEmpty && firstResult == nil { firstResult = seconds(start) }
            latest = snapshot
            if snapshot.isComplete { completed = seconds(start) }
        }
        defer { subscription.cancel() }
        try pump { completed != nil }
        guard let latest, let completed else { throw SearchBenchmarkFailure(description: "No complete query result") }
        if let error = latest.errorMessage { throw SearchBenchmarkFailure(description: error) }
        return QueryTiming(query: text, firstUpdateMS: (firstUpdate ?? completed) * 1_000,
                           firstResultMS: firstResult.map { $0 * 1_000 }, completeMS: completed * 1_000,
                           matches: latest.totalMatchCount, returned: latest.entries.count, updates: updates)
    }
    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    private static func bytes(_ database: URL) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm"].map { suffix in
            let path = database.path + suffix
            let value = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return (suffix.isEmpty ? "database" : String(suffix.dropFirst()), value)
        })
    }
    private static func diagnostics(_ index: FilenameSearchIndex) throws -> [String: Double] {
        var result: FilenameSearchDiagnostics?
        index.diagnostics { result = $0 }
        try pump { result != nil }
        guard let result else { return [:] }
        return ["scanCount": Double(result.scanCount), "indexedEntryCount": Double(result.indexedEntryCount),
                "queryCount": Double(result.queryCount), "lastQueryDurationSeconds": result.lastQueryDuration,
                "activeScanCount": Double(result.activeScanCount)]
    }
    private struct CatalogResult: Codable {
        let kind: String
        let order: String
        let excludeGenerated: Bool
        let entries: Int
        let seedSeconds: Double?
        let cold: QueryTiming
        let warm: QueryTiming
        let warmQueryCount: Int
        let warmP95FirstResultMS: Double
        let warmP95CompleteMS: Double
        let selectiveP95FirstResultMS: Double
        let selectiveP95CompleteMS: Double
        let broadAndShortP95FirstResultMS: Double?
        let broadAndShortP95CompleteMS: Double?
        let databaseBytes: [String: Int64]
        let diagnostics: [String: Double]
        let legacy: LegacyResult?
    }
    private struct LegacyResult: Codable {
        let coldCompleteMS: Double
        let warmCompleteMS: Double
        let selectiveQueryCount: Int
        let selectiveP95CompleteMS: Double
        let notes: String
    }
    private static func legacyScan(_ scope: URL, query: String) throws -> (milliseconds: Double, count: Int) {
        let start = clock.now
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isAliasFileKey, .isSymbolicLinkKey,
                                     .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey]
        guard let enumerator = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw SearchBenchmarkFailure(description: "Legacy baseline could not enumerate its fixture")
        }
        // Retain results and requested metadata just as the former recursive browser path did.
        var results: [(URL, Int, Date?, Date?, String, Bool, Bool)] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants() }
            if url.lastPathComponent.localizedStandardContains(query) {
                let values = try url.resourceValues(forKeys: Set(keys))
                results.append((url, values.fileSize ?? 0, values.contentModificationDate, values.creationDate,
                                values.localizedTypeDescription ?? "", values.isDirectory == true, values.isAliasFile == true))
            }
        }
        return (seconds(start) * 1_000, results.count)
    }
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    private static func run() throws {
        #if DEBUG
        throw SearchBenchmarkFailure(description: "Compile this benchmark with -O and the release core")
        #endif
        selectedOrderName = option("--order", fallback: "name")
        guard ["name", "bestMatch"].contains(selectedOrderName) else {
            throw SearchBenchmarkFailure(description: "--order must be name or bestMatch")
        }
        selectedOrder = selectedOrderName == "bestMatch" ? .bestMatch : .name
        excludeGenerated = CommandLine.arguments.contains("--exclude-generated")
        let counts = option("--counts", fallback: "100000,1000000").split(separator: ",").compactMap { Int($0) }
        guard !counts.isEmpty, counts.allSatisfy({ $0 > 0 && $0 <= 5_000_000 }),
              let realCount = Int(option("--real-files", fallback: "10000")), realCount > 0 && realCount <= 100_000,
              let queryCount = Int(option("--queries", fallback: "100")), queryCount >= 10 && queryCount <= 1_000 else {
            throw SearchBenchmarkFailure(description: "Invalid benchmark dimensions")
        }
        let manager = FileManager.default
        let project = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
        guard manager.fileExists(atPath: project.appendingPathComponent("Package.swift").path) else {
            throw SearchBenchmarkFailure(description: "Run from the directory containing Package.swift")
        }
        let fixture = project.appendingPathComponent(".build/test-fixtures/search-benchmark-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { if !CommandLine.arguments.contains("--keep") { try? manager.removeItem(at: fixture) } }
        var results: [CatalogResult] = []
        print("Filename search benchmark: release build, actual SQLite catalog/query path; fixture \(fixture.path)")
        print("Search options: order=\(selectedOrderName), excludeGenerated=\(excludeGenerated)")
        print("Synthetic rows have no backing files. Cold means first query of a new seeded service; OS caches are not purged.")
        for count in counts {
            let scope = fixture.appendingPathComponent("synthetic-\(count)", isDirectory: true)
            try manager.createDirectory(at: scope, withIntermediateDirectories: true)
            let database = fixture.appendingPathComponent("catalog-\(count).sqlite")
            let index = FilenameSearchIndex(databaseURL: database)
            defer { index.close() }
            let seedStart = clock.now
            var entries: [FilenameSearchEntry] = []
            entries.reserveCapacity(count)
            for i in 0..<count {
                let name = String(format: "project-%06d-report-%03d.txt", i, i % 997)
                entries.append(FilenameSearchEntry(url: scope.appendingPathComponent("group-\(i % 250)/" + name), name: name))
            }
            var seeded = false, seedError: Error?
            index.seedCatalog(in: scope, entries: entries) { seedError = $0; seeded = true }
            try pump { seeded }
            entries.removeAll(keepingCapacity: false)
            if let seedError { throw seedError }
            let seedSeconds = seconds(seedStart)
            let cold = try query(index, scope: scope, text: "report-042")
            let expected = count > 42 ? ((count - 1 - 42) / 997) + 1 : 0
            guard cold.matches == expected else { throw SearchBenchmarkFailure(description: "Synthetic catalog count mismatch: \(cold.matches), expected \(expected)") }
            let warm = try query(index, scope: scope, text: "report-042")
            var timings: [QueryTiming] = []
            for i in 0..<queryCount {
                // Mix common, selective, one/two-character and literal punctuation queries.
                let text: String
                switch i % 10 {
                case 0: text = "p"
                case 1: text = "-0"
                case 2: text = ".txt"
                default: text = String(format: "report-%03d", (i * 37) % 997)
                }
                timings.append(try query(index, scope: scope, text: text))
            }
            let result = CatalogResult(kind: "synthetic catalog", order: selectedOrderName, excludeGenerated: excludeGenerated,
                entries: count, seedSeconds: seedSeconds,
                cold: cold, warm: warm, warmQueryCount: queryCount,
                warmP95FirstResultMS: percentile95(timings.compactMap(\.firstResultMS)),
                warmP95CompleteMS: percentile95(timings.map(\.completeMS)),
                selectiveP95FirstResultMS: percentile95(timings.enumerated().filter { $0.offset % 10 >= 3 }.compactMap { $0.element.firstResultMS }),
                selectiveP95CompleteMS: percentile95(timings.enumerated().filter { $0.offset % 10 >= 3 }.map { $0.element.completeMS }),
                broadAndShortP95FirstResultMS: percentile95(timings.enumerated().filter { $0.offset % 10 < 3 }.compactMap { $0.element.firstResultMS }),
                broadAndShortP95CompleteMS: percentile95(timings.enumerated().filter { $0.offset % 10 < 3 }.map { $0.element.completeMS }),
                databaseBytes: bytes(database), diagnostics: try diagnostics(index), legacy: nil)
            results.append(result)
            print("Catalog \(count): seed \(String(format: "%.2f", seedSeconds))s; cold first result \(String(format: "%.2f", cold.firstResultMS ?? -1))ms; warm \(String(format: "%.2f", warm.firstResultMS ?? -1))ms; p95 complete \(String(format: "%.2f", result.warmP95CompleteMS))ms; DB/WAL/SHM \(result.databaseBytes)")
            print("  Selective p95 first/complete: \(String(format: "%.2f", result.selectiveP95FirstResultMS))/\(String(format: "%.2f", result.selectiveP95CompleteMS))ms; broad/short p95 first/complete: \(String(format: "%.2f", result.broadAndShortP95FirstResultMS ?? 0))/\(String(format: "%.2f", result.broadAndShortP95CompleteMS ?? 0))ms")
        }
        let scope = fixture.appendingPathComponent("real-files", isDirectory: true)
        let fileStart = clock.now
        for folder in 0..<100 { try manager.createDirectory(at: scope.appendingPathComponent("level/\(folder)"), withIntermediateDirectories: true) }
        for i in 0..<realCount {
            let url = scope.appendingPathComponent("level/\(i % 100)/actual-\(i)-report.txt")
            try Data("benchmark fixture\n".utf8).write(to: url)
        }
        print("Created \(realCount) actual files in \(String(format: "%.2f", seconds(fileStart)))s before timing the scan.")
        let legacyCold = try legacyScan(scope, query: "report")
        let legacyWarm = try legacyScan(scope, query: "report")
        guard legacyCold.count == realCount && legacyWarm.count == realCount else {
            throw SearchBenchmarkFailure(description: "Legacy baseline count mismatch")
        }
        let legacyQueryCount = min(queryCount, 20)
        var legacyTimes: [Double] = []
        for i in 0..<legacyQueryCount {
            legacyTimes.append(try legacyScan(scope, query: "actual-\((i * 31) % realCount)-").milliseconds)
        }
        let legacy = LegacyResult(coldCompleteMS: legacyCold.milliseconds, warmCompleteMS: legacyWarm.milliseconds,
            selectiveQueryCount: legacyQueryCount, selectiveP95CompleteMS: percentile95(legacyTimes),
            notes: "Former metadata-rich recursive enumeration and result accumulation; no UI. OS filesystem caches are warm from fixture creation. Both old and new use the same folder/query; no page-cache flushing.")
        let database = fixture.appendingPathComponent("real.sqlite")
        let index = FilenameSearchIndex(databaseURL: database)
        defer { index.close() }
        let cold = try query(index, scope: scope, text: "report")
        guard cold.matches == realCount else { throw SearchBenchmarkFailure(description: "Real scan count mismatch") }
        let warm = try query(index, scope: scope, text: "report")
        var timings: [QueryTiming] = []
        for i in 0..<queryCount { timings.append(try query(index, scope: scope, text: "actual-\((i * 31) % realCount)-")) }
        let real = CatalogResult(kind: "actual nested filesystem scan", order: selectedOrderName, excludeGenerated: excludeGenerated,
            entries: realCount, seedSeconds: nil,
            cold: cold, warm: warm, warmQueryCount: queryCount,
            warmP95FirstResultMS: percentile95(timings.compactMap(\.firstResultMS)),
            warmP95CompleteMS: percentile95(timings.map(\.completeMS)),
            selectiveP95FirstResultMS: percentile95(timings.compactMap(\.firstResultMS)),
            selectiveP95CompleteMS: percentile95(timings.map(\.completeMS)),
            broadAndShortP95FirstResultMS: nil, broadAndShortP95CompleteMS: nil,
            databaseBytes: bytes(database), diagnostics: try diagnostics(index), legacy: legacy)
        results.append(real)
        print("Real scan \(realCount): cold first result \(String(format: "%.2f", cold.firstResultMS ?? -1))ms; complete \(String(format: "%.2f", cold.completeMS))ms; warm \(String(format: "%.2f", warm.firstResultMS ?? -1))ms; p95 complete \(String(format: "%.2f", real.warmP95CompleteMS))ms")
        print("Legacy enumeration: first \(String(format: "%.2f", legacy.coldCompleteMS))ms; warm \(String(format: "%.2f", legacy.warmCompleteMS))ms; selective p95 \(String(format: "%.2f", legacy.selectiveP95CompleteMS))ms. Warm report speed ratio: \(String(format: "%.2f", legacy.warmCompleteMS / max(warm.completeMS, 0.000_001)))x")
        let output = project.appendingPathComponent(".build/qa/search-benchmark.json")
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        print("Measured results: \(output.path)")
    }
}
