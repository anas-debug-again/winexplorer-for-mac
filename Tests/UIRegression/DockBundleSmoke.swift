// Load the actual built bundle, not a test-linked copy of its source:
// xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path .build/module-cache \
//   Tests/UIRegression/DockBundleSmoke.swift -o .build/qa/DockBundleSmoke
// .build/qa/DockBundleSmoke 'build/WinExplorer for Mac.app'
// Reads bundle metadata and recent history only; never invokes menu actions, posts input,
// displays a window, changes Dock preferences, or launches/stops any process.
import AppKit

private struct DockBundleFailure: Error, CustomStringConvertible { let description: String }

@main struct DockBundleSmoke {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    private static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw DockBundleFailure(description: message) }
        }
        let appURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/WinExplorer for Mac.app", isDirectory: true)
        guard let appBundle = Bundle(url: appURL),
              let pluginName = appBundle.object(forInfoDictionaryKey: "NSDockTilePlugIn") as? String else {
            throw DockBundleFailure(description: "Built app is missing NSDockTilePlugIn metadata")
        }
        try require(pluginName.hasSuffix(".docktileplugin") && !pluginName.contains("/"), "Plug-in key must contain the bundle filename")
        let pluginURL = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true).appendingPathComponent(pluginName, isDirectory: true)
        guard let bundle = Bundle(url: pluginURL), let executable = bundle.executableURL else {
            throw DockBundleFailure(description: "Built plug-in bundle or executable is missing")
        }
        try require(bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "BNDL", "Built plug-in must declare BNDL")
        try require(FileManager.default.isReadableFile(atPath: executable.path), "Plug-in executable must exist")
        try require(NSClassFromString("FileManagerDockPlugin") == nil, "Smoke executable must not already link the plug-in implementation")
        try bundle.loadAndReturnError()
        try require(bundle.isLoaded, "NSBundle must load the actual plug-in binary")
        guard let type = bundle.principalClass as? NSObject.Type else {
            throw DockBundleFailure(description: "Built bundle has no Objective-C principal class")
        }
        let object = type.init()
        guard let plugin = object as? NSDockTilePlugIn else {
            throw DockBundleFailure(description: "Principal object does not conform to NSDockTilePlugIn")
        }
        try require(NSStringFromClass(type) == "FileManagerDockPlugin", "Principal class runtime name must match Info.plist")
        try require(Bundle(for: type).bundleURL.standardizedFileURL == pluginURL.standardizedFileURL,
                    "bundleForClass must locate the nested plug-in rather than the smoke host")
        try require(object.responds(to: NSSelectorFromString("setDockTile:")) && object.responds(to: NSSelectorFromString("dockMenu")),
                    "The loaded class must expose the exact Dock selectors")
        weak var retainedMenu: NSMenu?
        autoreleasepool { retainedMenu = plugin.dockMenu?() }
        guard let menu = retainedMenu else { throw DockBundleFailure(description: "Plug-in must strongly retain its menu after the autorelease pool drains") }
        try require(menu.items.first?.title == "New Window" && menu.items.first?.isEnabled == true,
                    "Built plug-in must supply New Window")
        try require(menu.items.contains { $0.title == "Recent Folders" && !$0.isEnabled }, "Built plug-in must supply a Recent Folders heading")
        let recentItems = menu.items.filter { $0.representedObject is URL }
        try require(recentItems.count <= 3, "Built plug-in must cap recents at three")
        for item in menu.items where item.isEnabled && item.action != nil {
            try require(item.target?.responds(to: item.action!) == true, "Every built menu action must retain a valid Objective-C target")
        }
        // This only releases our local test instance's state, not the Dock's plug-in instance.
        plugin.setDockTile(nil)
        let version = appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        print("PASS: \(checks) actual-bundle loading checks; app \(version); class \(NSStringFromClass(type)); recents \(recentItems.count)")
        print("Loaded: \(executable.path)")
        print("Menu: \(menu.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: " | "))")
    }
}
