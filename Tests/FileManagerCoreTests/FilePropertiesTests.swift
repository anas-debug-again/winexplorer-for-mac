import Testing
import Foundation
import Darwin
@testable import FileManagerCore

@Suite(.serialized)
struct FilePropertiesTests {
    private func withFixture(_ run: (URL) throws -> Void) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = project.appendingPathComponent(".build/test-fixtures/properties-" + UUID().uuidString,
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try run(folder)
    }

    private func put(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test func regularFileReportsNameLocationIdentityPermissionsAndDates() throws {
        try withFixture { folder in
            let file = folder.appendingPathComponent("Quarterly report.txt")
            try put("report data", at: file)
            #expect(chmod(file.path, 0o640) == 0)
            var times = [timeval(tv_sec: 1_700_000_000, tv_usec: 123_000),
                         timeval(tv_sec: 1_700_100_000, tv_usec: 456_000)]
            #expect(utimes(file.path, &times) == 0)
            var raw = stat()
            #expect(lstat(file.path, &raw) == 0)
            let info = try FileProperties.snapshot(for: file)
            #expect(info.url == file)
            #expect(info.name == "Quarterly report.txt")
            #expect(info.path == file.path)
            #expect(info.locationURL.path == folder.path)
            #expect(info.pathExtension == "txt")
            #expect(info.kind == .regularFile)
            #expect(info.logicalSize == 11)
            #expect(info.allocatedSize == Int64(raw.st_blocks) * 512)
            #expect(info.inode == raw.st_ino)
            #expect(info.device == UInt64(UInt32(bitPattern: raw.st_dev)))
            #expect(info.ownerID == raw.st_uid && info.groupID == raw.st_gid)
            #expect(info.mode & 0o777 == 0o640)
            #expect(info.permissions == "rw-r-----")
            #expect(abs(info.accessed.timeIntervalSince1970 - 1_700_000_000.123) < 0.001)
            #expect(abs(info.modified.timeIntervalSince1970 - 1_700_100_000.456) < 0.001)
            #expect(info.created.timeIntervalSince1970 > 0)
            #expect(info.metadataChanged >= info.created)
            #expect(!info.isHidden && !info.isLocked)
            #expect(info.symbolicLinkTarget == nil)
            #expect(try String(contentsOf: file, encoding: .utf8) == "report data")
        }
    }

    @Test func sparseFileDistinguishesLogicalAndAllocatedBytes() throws {
        try withFixture { folder in
            let file = folder.appendingPathComponent("sparse.bin")
            let descriptor = open(file.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            #expect(ftruncate(descriptor, 8 * 1024 * 1024) == 0)
            close(descriptor)
            let info = try FileProperties.snapshot(for: file)
            #expect(info.logicalSize == 8 * 1024 * 1024)
            #expect(info.allocatedSize < info.logicalSize)
            let total = FileProperties.aggregate(urls: [file])
            #expect(total.logicalSize == info.logicalSize)
            #expect(total.allocatedSize == info.allocatedSize)
            #expect(total.fileCount == 1 && total.folderCount == 0)
            #expect(!total.isPartial)
        }
    }

    @Test func hiddenAndImmutableFlagsDescribeTheEntry() throws {
        try withFixture { folder in
            let dotFile = folder.appendingPathComponent(".settings")
            let flagged = folder.appendingPathComponent("visible-name.txt")
            try put("dot", at: dotFile)
            try put("flagged", at: flagged)
            #expect(chflags(flagged.path, UInt32(UF_HIDDEN | UF_IMMUTABLE)) == 0)
            defer { chflags(flagged.path, 0) }
            #expect(try FileProperties.snapshot(for: dotFile).isHidden)
            let info = try FileProperties.snapshot(for: flagged)
            #expect(info.isHidden && info.isLocked)
            #expect(info.flags & UInt32(UF_HIDDEN | UF_IMMUTABLE) == UInt32(UF_HIDDEN | UF_IMMUTABLE))
        }
    }

    @Test func directoryTotalsIncludeHiddenContentsAndExcludeRootDirectoryStorage() throws {
        try withFixture { folder in
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            let hidden = folder.appendingPathComponent(".hidden", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            let one = folder.appendingPathComponent("one.txt")
            let two = folder.appendingPathComponent(".two")
            let three = nested.appendingPathComponent("three.txt")
            try put("one", at: one); try put("12345", at: two); try put("1234567", at: three)
            let allocated = try [one, two, three].reduce(Int64(0)) {
                $0 + (try FileProperties.snapshot(for: $1).allocatedSize)
            }
            #expect(try FileProperties.snapshot(for: folder).kind == .directory)
            let total = FileProperties.aggregate(urls: [folder])
            #expect(total.logicalSize == 15)
            #expect(total.allocatedSize == allocated)
            #expect(total.fileCount == 3 && total.folderCount == 2)
            #expect(total.symbolicLinkCount == 0)
            #expect(!total.isPartial)
        }
    }

    @Test func brokenAndDirectoryLinksReportTheirOwnMetadataWithoutTraversal() throws {
        try withFixture { folder in
            let selected = folder.appendingPathComponent("selected", isDirectory: true)
            let outside = folder.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try put(String(repeating: "secret", count: 2000), at: outside.appendingPathComponent("large.txt"))
            let directoryLink = selected.appendingPathComponent("external-folder")
            let broken = selected.appendingPathComponent("broken.txt")
            try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: "../outside")
            try FileManager.default.createSymbolicLink(atPath: broken.path, withDestinationPath: "missing-file")
            let linkInfo = try FileProperties.snapshot(for: directoryLink)
            let brokenInfo = try FileProperties.snapshot(for: broken)
            #expect(linkInfo.kind == .symbolicLink && linkInfo.symbolicLinkTarget == "../outside")
            #expect(brokenInfo.kind == .symbolicLink && brokenInfo.symbolicLinkTarget == "missing-file")
            #expect(linkInfo.logicalSize == Int64("../outside".utf8.count))
            #expect(brokenInfo.logicalSize == Int64("missing-file".utf8.count))
            let total = FileProperties.aggregate(urls: [selected])
            #expect(total.logicalSize == linkInfo.logicalSize + brokenInfo.logicalSize)
            #expect(total.fileCount == 2 && total.symbolicLinkCount == 2 && total.folderCount == 0)
            #expect(!total.isPartial)
            let selectedLink = FileProperties.aggregate(urls: [directoryLink])
            #expect(selectedLink.fileCount == 1 && selectedLink.folderCount == 0)
            #expect(selectedLink.logicalSize == linkInfo.logicalSize)
        }
    }

    @Test func overlappingSelectionsAndRepeatedRootsCountEntriesOnce() throws {
        try withFixture { folder in
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let file = nested.appendingPathComponent("item.txt")
            try put("contents", at: file)
            let total = FileProperties.aggregate(urls: [file, nested, folder, folder, file])
            #expect(total.fileCount == 1 && total.folderCount == 1)
            #expect(total.logicalSize == 8)
            #expect(!total.isPartial)
        }
    }

    @Test func hardLinksCountNamesSeparatelyAndStorageOnce() throws {
        try withFixture { folder in
            let first = folder.appendingPathComponent("first.txt")
            let second = folder.appendingPathComponent("second.txt")
            try put("shared data", at: first)
            try FileManager.default.linkItem(at: first, to: second)
            let info = try FileProperties.snapshot(for: first)
            for roots in [[folder], [first, second]] {
                let total = FileProperties.aggregate(urls: roots)
                #expect(total.fileCount == 2 && total.folderCount == 0)
                #expect(total.logicalSize == 11 && total.allocatedSize == info.allocatedSize)
                #expect(!total.isPartial)
            }
        }
    }

    @Test func cancellationBeforeAndDuringEnumerationReturnsPartialTotals() throws {
        try withFixture { folder in
            for index in 0..<40 { try put("data", at: folder.appendingPathComponent("file-\(index).txt")) }
            let immediate = FileProperties.aggregate(urls: [folder], cancellation: { true })
            #expect(immediate.isCancelled && immediate.isPartial)
            #expect(immediate.fileCount == 0 && immediate.logicalSize == 0)
            var checks = 0
            let partial = FileProperties.aggregate(urls: [folder]) { checks += 1; return checks >= 16 }
            #expect(partial.isCancelled && partial.isPartial)
            #expect(partial.fileCount > 0 && partial.fileCount < 40)
            #expect(partial.logicalSize == Int64(partial.fileCount * 4))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 40)
        }
    }

    @Test func entryLimitStopsEnumerationAndReportsTruncation() throws {
        try withFixture { folder in
            for index in 0..<3 { try put("one", at: folder.appendingPathComponent("file-\(index)")) }
            let limited = FileProperties.aggregate(urls: [folder], maximumEntries: 2)
            #expect(limited.fileCount == 1 && limited.logicalSize == 3)
            #expect(limited.isTruncated && limited.isPartial && !limited.isCancelled)
            #expect(!FileProperties.aggregate(urls: [folder], maximumEntries: 4).isPartial)
            let zero = FileProperties.aggregate(urls: [folder], maximumEntries: 0)
            #expect(zero.isTruncated && zero.fileCount == 0)
            #expect(!FileProperties.aggregate(urls: [], maximumEntries: 0).isPartial)
        }
    }

    @Test func missingEntriesAreReportedWithoutDiscardingReadableTotals() throws {
        try withFixture { folder in
            let present = folder.appendingPathComponent("present.txt")
            let absent = folder.appendingPathComponent("missing.txt")
            try put("known", at: present)
            #expect(throws: (any Error).self) { try FileProperties.snapshot(for: absent) }
            #expect(throws: (any Error).self) {
                try FileProperties.snapshot(for: URL(string: "https://example.invalid/item")!)
            }
            let total = FileProperties.aggregate(urls: [absent, present])
            #expect(total.logicalSize == 5 && total.fileCount == 1)
            #expect(total.inaccessibleCount == 1 && total.isPartial)
            #expect(!total.isCancelled && !total.isTruncated)
            let boundedErrors = FileProperties.aggregate(
                urls: (0..<8).map { folder.appendingPathComponent("absent-\($0)") }, maximumEntries: 2)
            #expect(boundedErrors.inaccessibleCount == 2 && boundedErrors.isTruncated)
        }
    }

    @Test(.enabled(if: geteuid() != 0))
    func unreadableDirectoryProducesPartialTotalsAndIsNotTreatedAsEmpty() throws {
        try withFixture { folder in
            let restricted = folder.appendingPathComponent("restricted", isDirectory: true)
            try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
            try put("unreadable content", at: restricted.appendingPathComponent("secret.txt"))
            try put("public", at: folder.appendingPathComponent("public.txt"))
            #expect(chmod(restricted.path, 0) == 0)
            defer { chmod(restricted.path, 0o700) }
            let total = FileProperties.aggregate(urls: [folder])
            #expect(total.fileCount == 1 && total.folderCount == 1 && total.logicalSize == 6)
            #expect(total.inaccessibleCount == 1 && total.isPartial)
        }
    }

    @Test func depthLimitStopsPathologicalDirectoryTrees() throws {
        try withFixture { folder in
            var deepest = folder
            for _ in 0..<130 {
                deepest.appendPathComponent("d", isDirectory: true)
                try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: false)
            }
            try put("beyond limit", at: deepest.appendingPathComponent("file.txt"))
            let total = FileProperties.aggregate(urls: [folder])
            #expect(total.isTruncated && total.isPartial)
            #expect(total.folderCount == 128 && total.fileCount == 0 && total.logicalSize == 0)
        }
    }
}
