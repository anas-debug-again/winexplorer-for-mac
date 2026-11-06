// Pure path-resolution checks; never reads or writes actual browsing data.
import AppKit

@main struct AppStorageRegression {
    static func main() throws {
        let home = URL(fileURLWithPath: "/test/home", isDirectory: true)
        let checkout = URL(fileURLWithPath: "/test/source", isDirectory: true)
        let app = URL(fileURLWithPath: "/Applications/WinExplorer for Mac.app", isDirectory: true)
        let expected = home.appendingPathComponent("Library/Application Support/File Manager", isDirectory: true)
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() {
                throw NSError(domain: "AppStorageRegression", code: checks,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func resolve(bundle: URL = app, workspace: String? = nil, override: String? = nil,
                     cwd: URL = checkout) -> URL {
            AppStorage.stateDirectory(bundleURL: bundle, projectWorkspace: workspace, override: override,
                                      homeDirectory: home, currentDirectory: cwd)
        }

        try require(resolve().path == expected.path, "Packaged apps must keep browsing data in Application Support")
        try require(resolve(bundle: URL(fileURLWithPath: "/test/Downloads/WinExplorer for Mac.app")).path == expected.path,
                    "Moving an app must not change or embed its browsing-data location")
        try require(resolve(cwd: URL(fileURLWithPath: "/")).path == expected.path,
                    "Finder and Dock launches must not depend on the process working directory")
        try require(resolve(bundle: checkout).path == checkout.appendingPathComponent("state").path,
                    "Plain development and test executables must retain isolated working-directory state")
        try require(resolve(override: "/test/private/../isolated state").path == "/test/isolated state",
                    "An explicit absolute state directory must support isolated packaged-app tests")
        try require(resolve(workspace: "/test/legacy", override: "/test/override").path == "/test/override",
                    "Explicit test state must take precedence over legacy bundle metadata")
        for invalid in ["", "relative", "~/state", "/test/bad\0path"] {
            try require(resolve(workspace: invalid, override: invalid).path == expected.path,
                        "Invalid relative or malformed overrides must not redirect packaged-app storage")
        }
        let legacy = resolve(workspace: "/test/legacy/../workspace")
        try require(legacy.path == "/test/workspace/state", "Existing development bundles must retain their state location")
        let dockDefault = FileManagerDockPlugin.historyURL(projectWorkspace: nil, homeDirectory: home)
        try require(dockDefault.path == expected.appendingPathComponent("recent-folders.json").path,
                    "The offline Dock menu must read the packaged app's per-user history")
        let dockLegacy = FileManagerDockPlugin.historyURL(projectWorkspace: "/test/legacy/../workspace", homeDirectory: home)
        try require(dockLegacy.path == legacy.appendingPathComponent("recent-folders.json").path,
                    "The offline Dock menu must preserve legacy development history")
        try require(FileManagerDockPlugin.historyURL(projectWorkspace: "relative", homeDirectory: home) == dockDefault,
                    "Invalid Dock workspace metadata must fall back to per-user storage")
        print("PASS: \(checks) app and Dock storage portability checks")
    }
}
