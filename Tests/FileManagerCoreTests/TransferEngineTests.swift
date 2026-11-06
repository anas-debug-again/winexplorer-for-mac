import Testing
import Foundation
import Darwin
@testable import FileManagerCore

@Suite(.serialized)
@MainActor
final class TransferEngineTests {
    private let fixture: URL
    private let manager = FileManager.default

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let allowedRoot = project.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        let requestedRoot = ProcessInfo.processInfo.environment["FILE_MANAGER_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? allowedRoot
        // Resolve existing ancestors even when the requested subdirectory is new.
        var configuredRoot = URL(fileURLWithPath: "/", isDirectory: true)
        for component in requestedRoot.pathComponents.dropFirst() {
            configuredRoot = configuredRoot.appendingPathComponent(component, isDirectory: true).resolvingSymlinksInPath()
        }
        guard configuredRoot.path == allowedRoot.path || configuredRoot.path.hasPrefix(allowedRoot.path + "/") else {
            throw NSError(domain: "TransferTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test fixtures must remain inside the project .build/test-fixtures folder."])
        }
        fixture = configuredRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: fixture)
    }

    @discardableResult
    private func directory(_ relative: String) throws -> URL {
        let url = fixture.appendingPathComponent(relative, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ relative: String, _ text: String) throws -> URL {
        let url = fixture.appendingPathComponent(relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func run(
        _ kind: TransferKind = .copy,
        sources: [URL],
        destination: URL,
        conflict: @escaping (FileConflict) -> ConflictResolution = { _ in
            Issue.record("Unexpected filename conflict")
            return ConflictResolution(choice: .cancel)
        }
    ) async -> [TransferProgress] {
        await observe(kind, sources: sources, destination: destination) { request, resolve, _ in
            resolve(conflict(request))
        }
    }

    private func observe(
        _ kind: TransferKind = .copy,
        sources: [URL],
        destination: URL,
        progressHandler: @escaping (TransferProgress, TransferEngine) -> Void = { _, _ in },
        conflictHandler: @escaping (FileConflict, @escaping (ConflictResolution) -> Void, TransferEngine) -> Void
    ) async -> [TransferProgress] {
        await withCheckedContinuation { continuation in
            let engine = TransferEngine()
            var events: [TransferProgress] = []
            var finished = false
            var timeout: Task<Void, Never>?
            let id = engine.start(kind: kind, sources: sources, destination: destination) { progress in
                guard !finished else { return }
                #expect(Thread.isMainThread)
                events.append(progress)
                progressHandler(progress, engine)
                if [.completed, .cancelled, .failed].contains(progress.phase) {
                    finished = true
                    timeout?.cancel()
                    continuation.resume(returning: events)
                }
            } onConflict: { request, resolve in
                #expect(Thread.isMainThread)
                if finished { resolve(ConflictResolution(choice: .cancel)); return }
                conflictHandler(request, resolve, engine)
            }
            timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !finished else { return }
                finished = true
                engine.cancel(id)
                Issue.record("Transfer did not complete within 15 seconds")
                continuation.resume(returning: events)
            }
        }
    }

    private func assertNoStaging(in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasPrefix(".filemanager-transfer-") }, sourceLocation: sourceLocation)
    }

    @Test
    func testCopyFolderPreservesContentsHiddenFilesEmptyFoldersAndMetadata() async throws {
        let source = try directory("source/Project")
        let text = try file("source/Project/notes.txt", "These are the notes.\n")
        try file("source/Project/.hidden", "hidden content")
        try file("source/Project/Nested/data.txt", "nested")
        try directory("source/Project/Empty")
        let destination = try directory("destination")
        let modification = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.setAttributes([.modificationDate: modification, .posixPermissions: 0o640], ofItemAtPath: text.path)
        let attribute = Data("preserved attribute".utf8)
        let xattrResult = attribute.withUnsafeBytes { bytes in
            setxattr(text.path, "com.example.filemanager-test", bytes.baseAddress, bytes.count, 0, 0)
        }
        #expect((xattrResult) == (0))
        let events = await run(sources: [source], destination: destination)
        let result = try #require(events.last)
        #expect((result.phase) == (.completed), Comment(rawValue: result.message ?? ""))
        #expect((result.completedBytes) == (result.totalBytes))
        #expect((result.completedFiles) == (3))
        let copied = destination.appendingPathComponent("Project/notes.txt")
        #expect((try contents(copied)) == ("These are the notes.\n"))
        #expect((try contents(destination.appendingPathComponent("Project/.hidden"))) == ("hidden content"))
        #expect((try contents(destination.appendingPathComponent("Project/Nested/data.txt"))) == ("nested"))
        var isDirectory: ObjCBool = false
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("Project/Empty").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try manager.attributesOfItem(atPath: copied.path)
        #expect((attributes[.modificationDate] as? Date) == (modification))
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue) == (0o640))
        var copiedAttribute = [UInt8](repeating: 0, count: 100)
        let attributeSize = getxattr(copied.path, "com.example.filemanager-test", &copiedAttribute, copiedAttribute.count, 0, 0)
        #expect((attributeSize) == (attribute.count))
        #expect((Data(copiedAttribute.prefix(max(0, attributeSize)))) == (attribute))
        #expect(manager.fileExists(atPath: source.path))
        try assertNoStaging(in: destination)
    }

    @Test
    func testMovePublishesCompleteDirectoryAndRemovesSource() async throws {
        let source = try directory("source/Folder")
        try file("source/Folder/one.txt", "one")
        try file("source/Folder/Nested/two.txt", "two")
        let destination = try directory("destination")
        let result = try #require(await run(.move, sources: [source], destination: destination).last)
        #expect((result.phase) == (.completed), Comment(rawValue: result.message ?? ""))
        #expect((try contents(destination.appendingPathComponent("Folder/Nested/two.txt"))) == ("two"))
        #expect(!(manager.fileExists(atPath: source.path)))
        try assertNoStaging(in: destination)
    }

    @Test
    func testKeepBothRechecksNamesAndPreservesBothFiles() async throws {
        let source = try file("source/report.txt", "new report")
        let destination = try directory("destination")
        try file("destination/report.txt", "old report")
        try file("destination/report (2).txt", "already here")
        var conflictCount = 0
        let result = try #require(await run(sources: [source], destination: destination) { request in
            conflictCount += 1
            #expect(request.canReplace)
            #expect((request.suggestedName) == ("report (3).txt"))
            // Another actor claims the proposed name while this conflict is displayed.
            try? Data("claimed during conflict".utf8).write(to: destination.appendingPathComponent(request.suggestedName))
            return ConflictResolution(choice: .keepBoth)
        }.last)
        #expect((result.phase) == (.completed), Comment(rawValue: result.message ?? ""))
        #expect((conflictCount) == (1))
        #expect((try contents(destination.appendingPathComponent("report.txt"))) == ("old report"))
        #expect((try contents(destination.appendingPathComponent("report (3).txt"))) == ("claimed during conflict"))
        #expect((try contents(destination.appendingPathComponent("report (4).txt"))) == ("new report"))
        try assertNoStaging(in: destination)
    }

    @Test
    func testReplaceFileAtomicallyAndSkipMovePreservesSource() async throws {
        let source = try file("source/report.txt", "replacement")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", "original")
        let replace = try #require(await run(sources: [source], destination: destination) { _ in
            ConflictResolution(choice: .replace)
        }.last)
        #expect((replace.phase) == (.completed), Comment(rawValue: replace.message ?? ""))
        #expect((try contents(existing)) == ("replacement"))
        try Data("do not move me".utf8).write(to: source)
        let skip = try #require(await run(.move, sources: [source], destination: destination) { _ in
            ConflictResolution(choice: .skip)
        }.last)
        #expect((skip.phase) == (.completed))
        #expect((skip.completedFiles) == (0))
        #expect((skip.totalFiles) == (0))
        #expect((try contents(source)) == ("do not move me"))
        #expect((try contents(existing)) == ("replacement"))
        try assertNoStaging(in: destination)
    }

    @Test
    func testApplyToRemainingIsLimitedToCompatibleFilesInOneJob() async throws {
        let first = try file("source/a.txt", "new a")
        let second = try file("source/b.txt", "new b")
        let folder = try directory("source/Folder")
        try file("source/Folder/new.txt", "new")
        let destination = try directory("destination")
        try file("destination/a.txt", "old a")
        try file("destination/b.txt", "old b")
        try file("destination/Folder/existing.txt", "keep")
        var requested: [String] = []
        let result = try #require(await run(sources: [first, second, folder], destination: destination) { request in
            requested.append(request.source.lastPathComponent)
            if request.isDirectory {
                #expect(!(request.canReplace))
                return ConflictResolution(choice: .skip)
            }
            return ConflictResolution(choice: .replace, applyToRemaining: true)
        }.last)
        #expect((result.phase) == (.completed), Comment(rawValue: result.message ?? ""))
        #expect((requested) == (["a.txt", "Folder"]))
        #expect((try contents(destination.appendingPathComponent("b.txt"))) == ("new b"))
        #expect((try contents(destination.appendingPathComponent("Folder/existing.txt"))) == ("keep"))
        #expect(!(manager.fileExists(atPath: destination.appendingPathComponent("Folder/new.txt").path)))
        var nextJobConflicts = 0
        _ = await run(sources: [first], destination: destination) { _ in
            nextJobConflicts += 1
            return ConflictResolution(choice: .skip)
        }
        #expect((nextJobConflicts) == (1))
    }

    @Test
    func testFolderReplacementIsRejectedWithoutModifyingEitherFolder() async throws {
        let source = try directory("source/Folder")
        try file("source/Folder/new.txt", "new")
        let destination = try directory("destination")
        try file("destination/Folder/existing.txt", "keep")
        let result = try #require(await run(sources: [source], destination: destination) { request in
            #expect(!(request.canReplace))
            return ConflictResolution(choice: .replace)
        }.last)
        #expect((result.phase) == (.failed))
        #expect((try contents(destination.appendingPathComponent("Folder/existing.txt"))) == ("keep"))
        #expect((try contents(source.appendingPathComponent("new.txt"))) == ("new"))
        try assertNoStaging(in: destination)
    }

    @Test
    func testSameFolderCopyCreatesDuplicateButSameLocationMoveFails() async throws {
        let parent = try directory("source")
        let source = try file("source/report.txt", "original")
        let copied = try #require(await run(sources: [source], destination: parent).last)
        #expect((copied.phase) == (.completed), Comment(rawValue: copied.message ?? ""))
        #expect((try contents(parent.appendingPathComponent("report (2).txt"))) == ("original"))
        let moved = try #require(await run(.move, sources: [source], destination: parent).last)
        #expect((moved.phase) == (.failed))
        #expect((try contents(source)) == ("original"))
        try assertNoStaging(in: parent)
    }

    @Test
    func testDescendantDestinationIncludingSymlinkAliasAndOverlappingSourcesAreRejected() async throws {
        let source = try directory("source/Folder")
        let child = try directory("source/Folder/Child")
        try file("source/Folder/file.txt", "keep")
        let alias = fixture.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: child)
        for destination in [source, child, alias] {
            let result = try #require(await run(sources: [source], destination: destination).last)
            #expect((result.phase) == (.failed))
            #expect((try contents(source.appendingPathComponent("file.txt"))) == ("keep"))
            try assertNoStaging(in: child)
        }
        let destination = try directory("destination")
        let overlap = try #require(await run(sources: [source, child], destination: destination).last)
        #expect((overlap.phase) == (.failed))
        #expect((try manager.contentsOfDirectory(atPath: destination.path)) == ([]))
    }

    @Test
    func testSymbolicLinksAreCopiedWithoutTraversingTargetsIncludingBrokenLinks() async throws {
        let source = try directory("source/Folder")
        let outside = try directory("outside")
        try file("outside/private.txt", "outside content")
        try manager.createSymbolicLink(at: source.appendingPathComponent("external"), withDestinationURL: outside)
        try manager.createSymbolicLink(atPath: source.appendingPathComponent("loop").path, withDestinationPath: ".")
        try manager.createSymbolicLink(atPath: source.appendingPathComponent("broken").path, withDestinationPath: "missing-target")
        let destination = try directory("destination")
        let result = try #require(await run(sources: [source], destination: destination).last)
        #expect((result.phase) == (.completed), Comment(rawValue: result.message ?? ""))
        #expect((result.totalFiles) == (3))
        #expect((result.totalBytes) == (0))
        let copied = destination.appendingPathComponent("Folder")
        #expect((try manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("external").path)) == (outside.path))
        #expect((try manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("loop").path)) == ("."))
        #expect((try manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("broken").path)) == ("missing-target"))
        #expect((try contents(outside.appendingPathComponent("private.txt"))) == ("outside content"))
        try assertNoStaging(in: destination)
    }

    @Test
    func testCancellingWhileWaitingUnblocksJobAndIgnoresLateResolution() async throws {
        let source = try file("source/report.txt", "source remains")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", "existing remains")
        var lateResolution: ((ConflictResolution) -> Void)?
        let events = await observe(.move, sources: [source], destination: destination) { request, resolve, engine in
            lateResolution = resolve
            engine.cancel(request.jobID)
        }
        #expect(events.last?.phase == .cancelled)
        lateResolution?(ConflictResolution(choice: .replace))
        #expect(try contents(source) == "source remains")
        #expect(try contents(existing) == "existing remains")
        try assertNoStaging(in: destination)
    }

    @Test
    func testSourceChangesAfterConflictFailWithoutReplacingDestinationOrDeletingSource() async throws {
        let source = try file("source/report.txt", "initial source")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", "existing must survive")
        let result = try #require(await run(.move, sources: [source], destination: destination) { _ in
            try? Data("source changed while dialog was open".utf8).write(to: source)
            return ConflictResolution(choice: .replace)
        }.last)
        #expect((result.phase) == (.failed))
        #expect((try contents(existing)) == ("existing must survive"))
        #expect((try contents(source)) == ("source changed while dialog was open"))
        try assertNoStaging(in: destination)
    }

    @Test
    func testChangedDestinationRequiresFreshConflictDecision() async throws {
        let source = try file("source/report.txt", "new source")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", "original destination")
        var conflicts = 0
        let result = try #require(await run(sources: [source], destination: destination) { _ in
            conflicts += 1
            if conflicts == 1 {
                try? Data("external edit after first prompt".utf8).write(to: existing)
                return ConflictResolution(choice: .replace, applyToRemaining: true)
            }
            return ConflictResolution(choice: .skip)
        }.last)
        #expect((result.phase) == (.completed), Comment(rawValue: result.message ?? ""))
        #expect((conflicts) == (2))
        #expect((try contents(existing)) == ("external edit after first prompt"))
        try assertNoStaging(in: destination)
    }

    @Test
    func testCancellingActiveReplacementDiscardsPartialStagingAndPreservesOriginal() async throws {
        let sourceFolder = try directory("source")
        let source = sourceFolder.appendingPathComponent("large.bin")
        #expect(manager.createFile(atPath: source.path, contents: Data("start".utf8)))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        let destination = try directory("destination")
        let existing = try file("destination/large.bin", "existing destination must survive cancellation")
        var sawByteProgress = false
        let events = await observe(.move, sources: [source], destination: destination, progressHandler: { progress, engine in
            if progress.phase == .transferring && progress.completedBytes > 0 && progress.completedBytes < progress.totalBytes && !sawByteProgress {
                sawByteProgress = true
                engine.cancel(progress.id)
            }
        }, conflictHandler: { _, resolve, _ in resolve(ConflictResolution(choice: .replace)) })
        #expect(sawByteProgress, "A large transfer must report real intermediate byte progress.")
        #expect(events.last?.phase == .cancelled)
        #expect(try contents(existing) == "existing destination must survive cancellation")
        #expect(manager.fileExists(atPath: source.path))
        try assertNoStaging(in: destination)
    }

    @Test
    func testConcurrentKeepBothJobsCannotOverwriteOneAnother() async throws {
        let first = try file("first/report.txt", "first source")
        let second = try file("second/report.txt", "second source")
        let destination = try directory("destination")
        try file("destination/report.txt", "original")
        async let firstEvents = run(sources: [first], destination: destination) { _ in ConflictResolution(choice: .keepBoth) }
        async let secondEvents = run(sources: [second], destination: destination) { _ in ConflictResolution(choice: .keepBoth) }
        let results = await [firstEvents, secondEvents]
        for events in results { #expect(events.last?.phase == .completed) }
        let contentSet = Set(try manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).map(contents))
        #expect(contentSet == Set(["original", "first source", "second source"]))
        try assertNoStaging(in: destination)
    }

    @Test
    func testKeepBothUsesSourceTypeForFileFolderNameCollisions() async throws {
        let sourceFile = try file("source/report.pdf", "source PDF contents")
        let destination = try directory("destination")
        try file("destination/report.pdf/inside.txt", "existing folder contents")
        let copied = try #require(await run(sources: [sourceFile], destination: destination) { request in
            #expect(!request.canReplace)
            #expect(request.suggestedName == "report (2).pdf")
            return ConflictResolution(choice: .keepBoth)
        }.last)
        #expect(copied.phase == .completed)
        #expect(try contents(destination.appendingPathComponent("report (2).pdf")) == "source PDF contents")
        #expect(try contents(destination.appendingPathComponent("report.pdf/inside.txt")) == "existing folder contents")

        let sourceFolder = try directory("source/Archive.v1")
        try file("source/Archive.v1/inside.txt", "new folder contents")
        try file("destination/Archive.v1", "existing regular file")
        let folderCopy = try #require(await run(sources: [sourceFolder], destination: destination) { request in
            #expect(request.suggestedName == "Archive.v1 (2)")
            return ConflictResolution(choice: .keepBoth)
        }.last)
        #expect(folderCopy.phase == .completed)
        #expect(try contents(destination.appendingPathComponent("Archive.v1 (2)/inside.txt")) == "new folder contents")
        #expect(try contents(destination.appendingPathComponent("Archive.v1")) == "existing regular file")
        try assertNoStaging(in: destination)
    }

    @Test
    func testKeepBothFitsTheFilesystemNameLimitWithoutLosingNormalExtension() async throws {
        let parent = try directory("source")
        let filename = String(repeating: "a", count: 251) + ".txt"
        let source = try file("source/" + filename, "long filename contents")
        let result = try #require(await run(sources: [source], destination: parent).last)
        #expect(result.phase == .completed, Comment(rawValue: result.message ?? ""))
        let copied = try #require(result.committedDestinations.first)
        #expect(copied.lastPathComponent.utf8.count <= 255)
        #expect(copied.lastPathComponent.hasSuffix(" (2).txt"))
        #expect(try contents(copied) == "long filename contents")
        #expect(try contents(source) == "long filename contents")
        try assertNoStaging(in: parent)
    }

    @Test
    func testDirectoryMoveRetainsSourceKindAndCommittedKeepBothLocation() async throws {
        let source = try directory("source/Installers")
        try file("source/Installers/notes.txt", "moving folder")
        let destination = try directory("destination")
        try file("destination/Installers/old.txt", "existing folder")
        let events = await run(.move, sources: [source], destination: destination) { _ in
            ConflictResolution(choice: .keepBoth)
        }
        let result = try #require(events.last)
        #expect(result.phase == .completed, Comment(rawValue: result.message ?? ""))
        #expect(result.sourceDirectoryFlags == [true])
        #expect(events.filter { $0.phase == .transferring }.allSatisfy { $0.sourceDirectoryFlags == [true] })
        let expectedDestination = destination.appendingPathComponent("Installers (2)").standardizedFileURL
        #expect(result.committedDestinations.map(\.standardizedFileURL) == [expectedDestination])
        #expect(!manager.fileExists(atPath: source.path))
        #expect(try contents(destination.appendingPathComponent("Installers (2)/notes.txt")) == "moving folder")
        #expect(try contents(destination.appendingPathComponent("Installers/old.txt")) == "existing folder")
    }

    @Test
    func testDestinationDirectorySubstitutionDuringConflictCannotRedirectMove() async throws {
        let source = try file("source/report.txt", "source must remain")
        let destination = try directory("destination")
        try file("destination/report.txt", "original destination")
        let movedDestination = fixture.appendingPathComponent("original-destination")
        let unrelated = try directory("unrelated")
        let result = try #require(await run(.move, sources: [source], destination: destination) { _ in
            do {
                try self.manager.moveItem(at: destination, to: movedDestination)
                try self.manager.createSymbolicLink(at: destination, withDestinationURL: unrelated)
            } catch { Issue.record(error) }
            return ConflictResolution(choice: .keepBoth)
        }.last)
        #expect(result.phase == .failed)
        #expect(result.committedDestinations.isEmpty)
        #expect(try contents(source) == "source must remain")
        #expect(try contents(movedDestination.appendingPathComponent("report.txt")) == "original destination")
        #expect(try manager.contentsOfDirectory(atPath: unrelated.path).isEmpty)
        try assertNoStaging(in: movedDestination)
    }

    @Test
    func testDestinationSubstitutionAfterStagingCleansOnlyTheOriginalStagingFolder() async throws {
        let source = try file("source/report.txt", "source must remain")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", "original destination")
        let movedDestination = fixture.appendingPathComponent("original-destination")
        let unrelated = try directory("unrelated")
        var conflicts = 0
        let result = try #require(await run(.move, sources: [source], destination: destination) { _ in
            conflicts += 1
            do {
                if conflicts == 1 {
                    try Data("external destination edit".utf8).write(to: existing)
                    return ConflictResolution(choice: .replace)
                }
                try self.manager.moveItem(at: destination, to: movedDestination)
                try self.manager.createSymbolicLink(at: destination, withDestinationURL: unrelated)
            } catch { Issue.record(error) }
            return ConflictResolution(choice: .keepBoth)
        }.last)
        #expect(conflicts == 2)
        #expect(result.phase == .failed)
        #expect(try contents(source) == "source must remain")
        #expect(try contents(movedDestination.appendingPathComponent("report.txt")) == "external destination edit")
        #expect(try manager.contentsOfDirectory(atPath: unrelated.path).isEmpty)
        try assertNoStaging(in: movedDestination)
    }

    @Test
    func testSourceChangedDuringSecondConflictCannotPublishStaleReplacement() async throws {
        let source = try file("source/report.txt", "initial source")
        let destination = try directory("destination")
        let existing = try file("destination/report.txt", "original destination")
        var conflicts = 0
        let result = try #require(await run(.move, sources: [source], destination: destination) { _ in
            conflicts += 1
            do {
                if conflicts == 1 { try Data("new external destination".utf8).write(to: existing) }
                else { try Data("source edited after staging".utf8).write(to: source) }
            } catch { Issue.record(error) }
            return ConflictResolution(choice: .replace)
        }.last)
        #expect(conflicts == 2)
        #expect(result.phase == .failed)
        #expect(result.committedDestinations.isEmpty)
        #expect(try contents(existing) == "new external destination")
        #expect(try contents(source) == "source edited after staging")
        try assertNoStaging(in: destination)
    }

    @Test
    func testDescendantProtectionUsesFilesystemIdentityAcrossCaseVariations() async throws {
        let source = try directory("source/Folder")
        let destination = try directory("source/Folder/Child")
        try file("source/Folder/notes.txt", "keep")
        let alternateSpelling = source.deletingLastPathComponent().appendingPathComponent("fOlDeR")
        // This case applies to macOS volumes with case-insensitive names.
        guard manager.fileExists(atPath: alternateSpelling.path) else { return }
        let result = try #require(await run(sources: [alternateSpelling], destination: destination).last)
        #expect(result.phase == .failed)
        #expect(result.message?.contains("descendants") == true)
        #expect(try manager.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try contents(source.appendingPathComponent("notes.txt")) == "keep")
    }
}
