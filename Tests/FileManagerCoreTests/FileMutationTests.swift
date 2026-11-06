import Testing
import Foundation
@testable import FileManagerCore

@Suite(.serialized)
struct FileMutationTests {
    private func withFixture(_ run: (URL) throws -> Void) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = project.appendingPathComponent(".build/test-fixtures/rename-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try run(folder)
    }

    @Test func caseOnlyRenameUpdatesActualSpellingAndPreservesContents() throws {
        try withFixture { folder in
            let original = folder.appendingPathComponent("report.txt"), renamed = folder.appendingPathComponent("REPORT.txt")
            try Data("original contents".utf8).write(to: original)
            try FileMutation.renameWithoutReplacing(from: original, to: renamed)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["REPORT.txt"])
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "original contents")
            try FileMutation.renameWithoutReplacing(from: renamed, to: original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.txt"])
        }
    }

    @Test func renameRefusesExistingFileWithoutChangingEitherItem() throws {
        try withFixture { folder in
            let source = folder.appendingPathComponent("source.txt"), target = folder.appendingPathComponent("target.txt")
            try Data("source".utf8).write(to: source); try Data("existing".utf8).write(to: target)
            #expect(throws: (any Error).self) { try FileMutation.renameWithoutReplacing(from: source, to: target) }
            #expect(try String(contentsOf: source, encoding: .utf8) == "source")
            #expect(try String(contentsOf: target, encoding: .utf8) == "existing")
        }
    }

    @Test func renameRefusesDanglingSymlinkWithoutReplacingIt() throws {
        try withFixture { folder in
            let source = folder.appendingPathComponent("source.txt"), link = folder.appendingPathComponent("target.txt")
            try Data("source".utf8).write(to: source)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
            #expect(throws: (any Error).self) { try FileMutation.renameWithoutReplacing(from: source, to: link) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "missing-target")
            #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        }
    }

    @Test func renameRefusesExistingHardLinkAlias() throws {
        try withFixture { folder in
            let source = folder.appendingPathComponent("original.txt"), link = folder.appendingPathComponent("alias.txt")
            try Data("source".utf8).write(to: source)
            try FileManager.default.linkItem(at: source, to: link)
            #expect(throws: (any Error).self) { try FileMutation.renameWithoutReplacing(from: source, to: link) }
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: link, encoding: .utf8) == "source")
        }
    }
}
