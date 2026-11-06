// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/RecentFoldersStore.swift Tests/UIRegression/RecentFoldersRegression.swift -o .build/qa/RecentFoldersRegression
// .build/qa/RecentFoldersRegression
import AppKit

private struct RecentFailure: Error, CustomStringConvertible { let description: String }

@main struct RecentFoldersRegression {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/qa/recent-folders-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let folders = ["A", "B", "C", "D"].map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in folders { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let state = root.appendingPathComponent("state/recent.json")
        var checks = 0
        func require(_ value: Bool, _ message: String) throws {
            checks += 1
            if !value { throw RecentFailure(description: message) }
        }
        let store = RecentFoldersStore(storageURL: state)
        try require(store.folders.isEmpty, "A new history must be empty")
        for folder in folders { store.record(folder) }
        try require(store.folders == [folders[3], folders[2], folders[1]], "Only the newest three distinct folders must remain")
        store.record(folders[2])
        try require(store.folders == [folders[2], folders[3], folders[1]], "Revisiting a folder must promote rather than duplicate it")
        let link = root.appendingPathComponent("linked-B")
        try manager.createSymbolicLink(at: link, withDestinationURL: folders[1])
        store.record(link)
        try require(store.folders == [folders[1], folders[2], folders[3]], "Symlink spellings must deduplicate their real directory")
        let regular = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: regular)
        let broken = root.appendingPathComponent("broken")
        try manager.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing"))
        for invalid in [regular, broken, root.appendingPathComponent("missing"), URL(string: "filemanager://this-mac")!, URL(string: "https://example.invalid/folder")!] { store.record(invalid) }
        try require(store.folders == [folders[1], folders[2], folders[3]], "Files, broken links, missing directories and virtual URLs must be ignored")
        let reloaded = RecentFoldersStore(storageURL: state)
        try require(reloaded.folders == store.folders, "Order must survive persistent reload")
        try manager.removeItem(at: folders[2])
        try require(reloaded.folders == [folders[1], folders[3]], "Deleted folders must be pruned before Dock publication")
        try require(RecentFoldersStore(storageURL: state).folders == [folders[1], folders[3]], "Pruned history must persist")
        let before = try Data(contentsOf: state)
        let temporary = RecentFoldersStore(storageURL: state, persists: false)
        temporary.record(folders[0])
        try require(temporary.folders.first == folders[0], "Temporary sessions must still track in-memory recents")
        try require(try Data(contentsOf: state) == before, "Temporary sessions must not change persistent history")
        let absentState = root.appendingPathComponent("no-write/recent.json")
        RecentFoldersStore(storageURL: absentState, persists: false).record(folders[0])
        try require(!manager.fileExists(atPath: absentState.deletingLastPathComponent().path), "Temporary sessions must not create state directories")
        try Data("not valid json".utf8).write(to: state)
        let corrupt = RecentFoldersStore(storageURL: state)
        try require(corrupt.folders.isEmpty, "Malformed history must recover without preventing launch")
        corrupt.record(folders[0])
        try require(RecentFoldersStore(storageURL: state).folders == [folders[0]], "A visit must replace malformed persistent history")
        try JSONEncoder().encode(["relative/path", folders[3].path, folders[3].path, regular.path, folders[0].path]).write(to: state)
        try require(RecentFoldersStore(storageURL: state).folders == [folders[3], folders[0]], "Loaded history must validate absolute directory paths and remove duplicates")
        print("PASS: \(checks) recent-folder persistence, ordering, validation and temporary-session checks")
    }
}
