// Hidden Dock-plugin regression. Compile and run from the project directory:
// xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
//   Sources/FileManagerDockPlugin/FileManagerDockPlugin.swift \
//   Tests/UIRegression/DockPluginRegression.swift -o .build/qa/DockPluginRegression
// .build/qa/DockPluginRegression
// Uses injected launch callbacks only: no Dock interaction, window display, or app launch.
import AppKit

private struct DockPluginFailure: Error, CustomStringConvertible { let description: String }

@main struct DockPluginRegression {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    private static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent(".build/qa/dock-plugin-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let history = fixture.appendingPathComponent("recent-folders.json")
        let folders = ["Alpha/Work", "Beta/Work", "Third", "Fourth"].map {
            fixture.appendingPathComponent($0, isDirectory: true)
        }
        for folder in folders { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let regular = fixture.appendingPathComponent("ordinary.txt")
        try Data("ordinary fixture file".utf8).write(to: regular)
        let linked = fixture.appendingPathComponent("Linked Work")
        try manager.createSymbolicLink(at: linked, withDestinationURL: folders[0])
        let broken = fixture.appendingPathComponent("Broken link")
        try manager.createSymbolicLink(at: broken, withDestinationURL: fixture.appendingPathComponent("missing"))
        var requests: [URL?] = []
        var plugin: FileManagerDockPlugin? = FileManagerDockPlugin(historyURL: history) { requests.append($0) }
        var checks = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw DockPluginFailure(description: message) }
        }
        func save(_ paths: [String]) throws { try JSONEncoder().encode(paths).write(to: history, options: .atomic) }
        func freshMenu() throws -> NSMenu {
            guard let menu = plugin?.dockMenu() else { throw DockPluginFailure(description: "Dock plugin must return a menu") }
            try require(menu.items.first?.title == "New Window" && menu.items.first?.isEnabled == true,
                        "Every menu must begin with an enabled New Window action")
            try require(menu.items.count >= 4 && menu.items[1].isSeparatorItem,
                        "The window action must be separated from recent folders")
            try require(menu.items[2].title == "Recent Folders" && !menu.items[2].isEnabled && menu.items[2].action == nil,
                        "Recent Folders heading must be non-actionable")
            return menu
        }
        func recents(_ menu: NSMenu) -> [NSMenuItem] { menu.items.filter { $0.representedObject is URL } }
        func targets(_ menu: NSMenu) -> [URL] { recents(menu).compactMap { $0.representedObject as? URL } }
        func dispatch(_ item: NSMenuItem, expecting expected: URL?) throws {
            guard let action = item.action, let target = item.target as? NSObject else {
                throw DockPluginFailure(description: "A menu action must retain a target")
            }
            try require(action == NSSelectorFromString("open:") && target.responds(to: action),
                        "Dock actions must expose the real Objective-C open: selector")
            let count = requests.count
            try require(app.sendAction(action, to: target, from: nil), "Dock action must dispatch without a sender")
            try require(requests.count == count + 1 && requests.last!?.standardizedFileURL.path == expected?.standardizedFileURL.path,
                        "Sender-free Dock action must launch its captured folder or New Window")
        }

        let empty = try freshMenu()
        try require(recents(empty).isEmpty && empty.items.last?.title == "No recent folders" && empty.items.last?.isEnabled == false,
                    "Missing history must show a useful disabled empty state")
        try dispatch(empty.items[0], expecting: nil)

        try save(["relative/path", "filemanager://this-mac", "https://example.invalid/folder", regular.path,
                  fixture.appendingPathComponent("missing").path, broken.path, folders[0].path + "\0invalid",
                  linked.path, folders[0].path, folders[0].path + "/../Work", folders[1].path, folders[2].path, folders[3].path])
        let initial = try freshMenu()
        try require(targets(initial).map(\.path) == folders.prefix(3).map(\.path),
                    "History must preserve order, canonicalize and deduplicate directories, filter invalid entries, and cap at three")
        try require(recents(initial).map(\.title) == ["Work — Alpha", "Work — Beta", "Third"],
                    "Repeated folder names must be disambiguated by their parent folder")
        try require(recents(initial).allSatisfy { $0.isEnabled && $0.image?.size == NSSize(width: 16, height: 16) },
                    "Recent folders must have enabled actions and compact folder icons")
        try require(zip(recents(initial), folders).allSatisfy { $0.toolTip == $1.path },
                    "Recent folder tooltips must reveal their full canonical paths")
        for (item, expected) in zip(recents(initial), folders) { try dispatch(item, expecting: expected) }
        let oldFolderItem = recents(initial)[0]
        // Targets must own their folder rather than depending on representedObject or a sender.
        oldFolderItem.representedObject = folders[3]
        try dispatch(oldFolderItem, expecting: folders[0])

        try save([folders[3].path, folders[2].path])
        let refreshed = try freshMenu()
        try require(targets(refreshed) == [folders[3], folders[2]],
                    "A subsequent Dock menu must read fresh history without recreating the plugin")
        try require(requests.count == 5, "Constructing menus must not launch any app or folder")
        try dispatch(oldFolderItem, expecting: folders[0])
        try dispatch(empty.items[0], expecting: nil)
        try dispatch(recents(refreshed)[0], expecting: folders[3])
        plugin?.setDockTile(nil)
        try dispatch(oldFolderItem, expecting: folders[0])
        try dispatch(recents(refreshed)[1], expecting: folders[2])

        try manager.removeItem(at: folders[3])
        let pruned = try freshMenu()
        try require(targets(pruned) == [folders[2]], "A newly missing folder must be removed from subsequent menus")
        try require(try JSONDecoder().decode([String].self, from: Data(contentsOf: history)) == [folders[3].path, folders[2].path],
                    "Reading a Dock menu must not rewrite application history")

        for corrupt in [Data("invalid json".utf8), Data("{\"paths\":[]}".utf8), Data("[1,2]".utf8), Data(repeating: 0x20, count: 65_537)] {
            try corrupt.write(to: history, options: .atomic)
            let menu = try freshMenu()
            try require(recents(menu).isEmpty && menu.items.last?.title == "No recent folders",
                        "Corrupt, wrong-shaped, or oversized history must fall back to an empty menu")
        }
        try manager.removeItem(at: history)
        try manager.createDirectory(at: history, withIntermediateDirectories: true)
        try require(recents(try freshMenu()).isEmpty, "A directory in place of history must be ignored")
        try manager.removeItem(at: history)
        try save([folders[1].path])
        let recovered = try freshMenu()
        try require(targets(recovered) == [folders[1]] && recents(recovered).first?.title == "Work",
                    "A later valid history must recover and remove unnecessary duplicate-name qualifiers")
        plugin = nil
        try dispatch(oldFolderItem, expecting: folders[0])
        try dispatch(recents(recovered)[0], expecting: folders[1])
        print("PASS: \(checks) offline Dock menu checks covering nil-sender selectors, fresh/filtering/canonical history, duplicate names, and retained old actions")
    }
}
