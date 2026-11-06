import AppKit

private final class RecentFolderDockMenu: NSMenu {
    var retainedActions: [RecentFolderDockAction] = []
}

private final class RecentFolderDockAction: NSObject {
    private let folder: URL?
    private let launch: (URL?) -> Void
    init(folder: URL?, launch: @escaping (URL?) -> Void) {
        self.folder = folder; self.launch = launch
    }
    // Dock actions have no menu-item sender, so keep the destination on the target.
    @objc func open(_ sender: Any?) { launch(folder) }
}

/// Loaded by macOS independently of the app to supply the menu after WinExplorer for Mac quits.
@objc(FileManagerDockPlugin)
public final class FileManagerDockPlugin: NSObject, NSDockTilePlugIn {
    private let historyURL: URL?
    private let launch: (URL?) -> Void
    private var retainedMenu: RecentFolderDockMenu?

    public override init() {
        let plugin = Bundle(for: FileManagerDockPlugin.self)
        let appURL = plugin.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appBundle = Bundle(url: appURL)
        historyURL = Self.historyURL(projectWorkspace: appBundle?.object(forInfoDictionaryKey: "ProjectWorkspace") as? String,
                                     homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        launch = { folder in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if let folder {
                // Explicitly choose this app: the default folder handler may still be Finder.
                NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration)
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            }
        }
        super.init()
    }

    /// The Dock runs in a different process; resolve the same per-user location
    /// as the packaged app without relying on its launch environment or cwd.
    static func historyURL(projectWorkspace: String?, homeDirectory: URL) -> URL {
        if let path = projectWorkspace, path.hasPrefix("/"), !path.contains("\0") {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("state/recent-folders.json").standardizedFileURL
        }
        return homeDirectory.appendingPathComponent("Library/Application Support/File Manager/recent-folders.json")
    }

    init(historyURL: URL, launch: @escaping (URL?) -> Void) {
        self.historyURL = historyURL; self.launch = launch
        super.init()
    }

    public func setDockTile(_ dockTile: NSDockTile?) {
        if dockTile == nil { retainedMenu = nil }
    }

    public func dockMenu() -> NSMenu? {
        let menu = RecentFolderDockMenu(title: "WinExplorer for Mac")
        menu.autoenablesItems = false
        func append(_ title: String, folder: URL?) {
            let target = RecentFolderDockAction(folder: folder, launch: launch)
            menu.retainedActions.append(target)
            let item = menu.addItem(withTitle: title, action: #selector(RecentFolderDockAction.open(_:)), keyEquivalent: "")
            item.target = target
            item.toolTip = folder?.path
            item.representedObject = folder
            if folder != nil {
                let icon = NSWorkspace.shared.icon(for: .folder).copy() as! NSImage
                icon.size = NSSize(width: 16, height: 16); item.image = icon
            }
        }
        append("New Window", folder: nil)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Recent Folders", action: nil, keyEquivalent: "").isEnabled = false
        let folders = readRecentFolders()
        for folder in folders {
            var title = FileManager.default.displayName(atPath: folder.path)
            if folders.filter({ FileManager.default.displayName(atPath: $0.path) == title }).count > 1 {
                title += " — " + FileManager.default.displayName(atPath: folder.deletingLastPathComponent().path)
            }
            append(title, folder: folder)
        }
        if folders.isEmpty {
            menu.addItem(withTitle: "No recent folders", action: nil, keyEquivalent: "").isEnabled = false
        }
        retainedMenu = menu
        return menu
    }

    private func readRecentFolders() -> [URL] {
        guard let historyURL,
              let values = try? historyURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= 65_536,
              let data = try? Data(contentsOf: historyURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        var folders: [URL] = []
        for path in paths where path.hasPrefix("/") && !path.contains("\0") {
            let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  seen.insert(folder.path).inserted else { continue }
            folders.append(folder)
            if folders.count == 3 { break }
        }
        return folders
    }
}
