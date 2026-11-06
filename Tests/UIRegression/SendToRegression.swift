// Run from the project directory:
// xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
//   Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/SendToService.swift Tests/UIRegression/SendToRegression.swift \
//   -o .build/qa/send-to-regression
// .build/qa/send-to-regression
// All writes use generated project fixtures. The volume-root case reads only root metadata.
// No Finder automation or user-file contents.
import Foundation
import Darwin

private struct SendToRegressionFailure: Error, CustomStringConvertible { let description: String }

@main struct SendToRegression {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw SendToRegressionFailure(description: message) }
    }
    static func verifyAlias(_ shortcut: URL, pointsTo source: URL) throws {
        let properties = try shortcut.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey, .isRegularFileKey, .hasHiddenExtensionKey])
        try require(AppShortcutDocument.isShortcut(shortcut), "Created document must use the registered shortcut extension")
        try require(properties.isAliasFile != true && properties.isSymbolicLink != true && properties.isRegularFile == true,
                    "Shortcut must be an app-owned regular document, not a Finder alias or symlink")
        try require(properties.hasHiddenExtension == true, "The internal document extension must be hidden in Finder")
        let resolved = try AppShortcutDocument.resolve(shortcut)
        try require(resolved.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path,
                    "Shortcut bookmark must resolve to the selected source")
    }
    static func main() throws {
        let manager = FileManager.default
        let project = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
        let fixture = project.appendingPathComponent(".build/qa/send-to-fixtures-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        func directory(_ name: String) throws -> URL {
            let url = fixture.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        let source = fixture.appendingPathComponent("Report.txt")
        try Data("selected content".utf8).write(to: source)
        let destination = try directory("Aliases")
        let occupied = destination.appendingPathComponent("Report.txt - Shortcut.fmlink")
        let broken = destination.appendingPathComponent("Report.txt - Shortcut (2).fmlink")
        try Data("existing destination".utf8).write(to: occupied)
        try manager.createSymbolicLink(atPath: broken.path, withDestinationPath: "missing-target")
        let aliases = try SendToService.createAliases(for: [source], in: destination)
        try require(aliases.count == 1 && aliases[0].lastPathComponent == "Report.txt - Shortcut (3).fmlink", "Names must skip existing files and dangling links")
        try verifyAlias(aliases[0], pointsTo: source)
        try require(try String(contentsOf: occupied, encoding: .utf8) == "existing destination", "Existing collision contents must remain intact")
        try require(try manager.destinationOfSymbolicLink(atPath: broken.path) == "missing-target", "Existing dangling link must remain intact")
        try require(try String(contentsOf: source, encoding: .utf8) == "selected content", "Alias creation must preserve source contents")
        try require(try manager.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasPrefix(".filemanager-alias-") }, "Successful staging must be cleaned")

        let sourceFolder = try directory("Project")
        try Data(repeating: 0x5A, count: 1024 * 1024).write(to: sourceFolder.appendingPathComponent("payload.bin"))
        let folderAlias = try SendToService.createAliases(for: [sourceFolder], in: destination)[0]
        try verifyAlias(folderAlias, pointsTo: sourceFolder)
        try require(try manager.contentsOfDirectory(atPath: sourceFolder.path) == ["payload.bin"], "Folder alias creation must preserve its contents")

        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let volumeDestination = try directory("Volume aliases")
        let rootAliases = try SendToService.createAliases(for: [root], in: volumeDestination)
        try require(rootAliases.count == 1, "A volume-root URL must produce one alias")
        let rootAlias = rootAliases[0]
        try require(rootAlias.deletingLastPathComponent().standardizedFileURL == volumeDestination.standardizedFileURL,
                    "Volume-root aliases must stay inside the requested destination")
        let rootDisplayName = manager.displayName(atPath: root.path)
        let expectedVolumeName = rootDisplayName.isEmpty || rootDisplayName.contains("/") || rootDisplayName.contains("\0") ? "Volume" : rootDisplayName
        try require(rootAlias.lastPathComponent == expectedVolumeName + " - Shortcut.fmlink",
                    "Volume-root aliases must use a safe display name instead of the slash basename")
        try verifyAlias(rootAlias, pointsTo: root)
        let secondRootAlias = try SendToService.createAliases(for: [root], in: volumeDestination)[0]
        try require(secondRootAlias.lastPathComponent == expectedVolumeName + " - Shortcut (2).fmlink",
                    "Repeated volume-root shortcuts must use unique names in the destination")
        try verifyAlias(secondRootAlias, pointsTo: root)
        try require(try manager.contentsOfDirectory(atPath: volumeDestination.path).count == 2,
                    "Volume-root alias creation must leave only the completed shortcuts")

        let renamed = fixture.appendingPathComponent("Renamed report.txt")
        try manager.moveItem(at: source, to: renamed)
        try verifyAlias(aliases[0], pointsTo: renamed)

        let longSource = fixture.appendingPathComponent(String(repeating: "é", count: 125) + ".txt")
        try Data("long name".utf8).write(to: longSource)
        let longAlias = try SendToService.createAliases(for: [longSource], in: destination)[0]
        try require(longAlias.lastPathComponent.utf8.count <= 255 && longAlias.lastPathComponent.hasSuffix(" - Shortcut.fmlink"), "Long shortcut names must fit the filesystem limit")
        try verifyAlias(longAlias, pointsTo: longSource)
        let repeatedLongAlias = try SendToService.createAliases(for: [longSource], in: destination)[0]
        try require(repeatedLongAlias != longAlias && repeatedLongAlias.lastPathComponent.utf8.count <= 255
                    && repeatedLongAlias.lastPathComponent.hasSuffix(" - Shortcut (2).fmlink"),
                    "Numbered long shortcut names must reserve bytes for the full suffix and internal extension")
        try verifyAlias(repeatedLongAlias, pointsTo: longSource)

        let invalidDocuments = try directory("Invalid documents")
        func rejectsDocument(_ data: Data, name: String, reason: String) throws {
            let document = invalidDocuments.appendingPathComponent(name + ".fmlink")
            try data.write(to: document)
            try require(AppShortcutDocument.isShortcut(document), "A broken document must retain shortcut classification")
            var rejected = false
            do { _ = try AppShortcutDocument.resolve(document) } catch { rejected = true }
            try require(rejected, reason)
        }
        try rejectsDocument(Data("not a shortcut document".utf8), name: "Malformed",
                            reason: "Malformed shortcut contents must be rejected")
        let validData = try AppShortcutDocument.data(for: renamed)
        var envelope = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        envelope["version"] = 999
        try rejectsDocument(JSONSerialization.data(withJSONObject: envelope), name: "Unknown version",
                            reason: "Unknown shortcut versions must not be interpreted")
        envelope["version"] = 1; envelope["format"] = "unrelated.document"
        try rejectsDocument(JSONSerialization.data(withJSONObject: envelope), name: "Wrong format",
                            reason: "Unrelated document formats must be rejected")
        envelope["format"] = AppShortcutDocument.typeIdentifier; envelope["bookmark"] = ""
        try rejectsDocument(JSONSerialization.data(withJSONObject: envelope), name: "Empty bookmark",
                            reason: "Empty bookmark data must be rejected")
        try rejectsDocument(Data(repeating: 0x20, count: 1_048_577), name: "Oversized",
                            reason: "Shortcut reads must reject oversized files")
        let removedTarget = fixture.appendingPathComponent("Removed target.txt")
        try Data("temporary target".utf8).write(to: removedTarget)
        let brokenTargetDocument = try AppShortcutDocument.data(for: removedTarget)
        try manager.removeItem(at: removedTarget)
        try rejectsDocument(brokenTargetDocument, name: "Missing target",
                            reason: "A valid shortcut with a deleted target must report resolution failure")
        let upperCase = invalidDocuments.appendingPathComponent("Uppercase.FMLINK")
        try validData.write(to: upperCase)
        try require(AppShortcutDocument.isShortcut(upperCase), "Shortcut extension recognition must be case-insensitive")
        let upperCaseTarget = try AppShortcutDocument.resolve(upperCase)
        try require(upperCaseTarget.standardizedFileURL == renamed.standardizedFileURL,
                    "Case-insensitive shortcut recognition must resolve a valid document")

        let partialDestination = try directory("Partial")
        let missing = fixture.appendingPathComponent("missing.txt")
        do {
            _ = try SendToService.createAliases(for: [renamed, missing], in: partialDestination)
            throw SendToRegressionFailure(description: "Missing source must fail")
        } catch let failure as SendToService.Failure {
            try require(failure.createdURLs.count == 1 && failure.failedSource == missing, "Batch failure must report completed aliases and failed source")
            try verifyAlias(failure.createdURLs[0], pointsTo: renamed)
            try require(try manager.contentsOfDirectory(atPath: partialDestination.path).count == 1, "Failure must clean only unpublished staging")
        }

        let cancellation = SendToService.Cancellation(); cancellation.cancel()
        let cancelledDestination = try directory("Cancelled")
        do {
            _ = try SendToService.createAliases(for: [renamed], in: cancelledDestination, isCancelled: { cancellation.isCancelled })
            throw SendToRegressionFailure(description: "Pre-cancelled job must fail")
        } catch let failure as SendToService.Failure {
            try require((failure.underlyingError as NSError).code == NSUserCancelledError && failure.createdURLs.isEmpty, "Cancellation must preserve its typed reason")
            try require(try manager.contentsOfDirectory(atPath: cancelledDestination.path).isEmpty, "Pre-cancellation must not create staging")
        }
        var cancellationChecks = 0
        do {
            _ = try SendToService.createAliases(for: [renamed], in: cancelledDestination) {
                cancellationChecks += 1; return cancellationChecks >= 5
            }
            throw SendToRegressionFailure(description: "Cancellation immediately before publication must fail")
        } catch let failure as SendToService.Failure {
            try require((failure.underlyingError as NSError).code == NSUserCancelledError && failure.createdURLs.isEmpty, "Pre-publication cancellation must keep destinations unpublished")
            try require(try manager.contentsOfDirectory(atPath: cancelledDestination.path).isEmpty, "Pre-publication cancellation must remove its alias and private stage")
        }
        do {
            _ = try SendToService.createAliases(for: [renamed, longSource], in: cancelledDestination) {
                ((try? manager.contentsOfDirectory(atPath: cancelledDestination.path)) ?? []).contains { !$0.hasPrefix(".") }
            }
            throw SendToRegressionFailure(description: "Cancellation after one publication must fail the remaining batch")
        } catch let failure as SendToService.Failure {
            try require(failure.createdURLs.count == 1, "Cancellation must preserve an already completed alias")
            try verifyAlias(failure.createdURLs[0], pointsTo: renamed)
            try require(try manager.contentsOfDirectory(atPath: cancelledDestination.path).count == 1, "Only the completed alias may remain")
        }

        let concurrentDestination = try directory("Concurrent")
        let lock = NSLock()
        var successes: [URL] = [], errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let urls = try SendToService.createAliases(for: [renamed], in: concurrentDestination)
                lock.lock(); successes += urls; lock.unlock()
            } catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        try require(errors.isEmpty && successes.count == 8 && Set(successes).count == 8, "Concurrent jobs must publish eight different aliases without overwriting")
        for alias in successes { try verifyAlias(alias, pointsTo: renamed) }
        try require(try manager.contentsOfDirectory(atPath: concurrentDestination.path).count == 8, "Concurrent jobs must remove their own staging folders")

        do {
            _ = try SendToService.createAliases(for: [renamed], in: occupied)
            throw SendToRegressionFailure(description: "A regular-file destination must fail")
        } catch let failure as SendToService.Failure {
            try require(failure.createdURLs.isEmpty, "Invalid destination must not publish aliases")
            try require(try String(contentsOf: occupied, encoding: .utf8) == "existing destination", "Invalid destination must remain unchanged")
        }
        print("PASS: \(checks) Send to checks covering registered shortcut documents, malformed and broken document rejection, renamed targets, folder/volume targets, unique UTF8 names, concurrent publication, partial failure, and cancellation")
    }
}
