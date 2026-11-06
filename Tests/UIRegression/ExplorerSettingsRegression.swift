// Pure preference migration/round-trip checks. No windows or filesystem mutations.
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift \
//   Tests/UIRegression/ExplorerSettingsRegression.swift -o .build/qa/explorer-settings-regression
import AppKit

@main struct ExplorerSettingsRegression {
    static func main() throws {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw NSError(domain: "ExplorerSettingsRegression", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func decode(_ text: String) throws -> SavedSettings { try JSONDecoder().decode(SavedSettings.self, from: Data(text.utf8)) }
        let legacy = try decode(#"{"leftTabs":["/legacy"],"showHidden":true,"preview":false}"#)
        try require(legacy.leftTabs == ["/legacy"] && legacy.explorer.showHiddenFiles && legacy.showHidden, "Existing folder tabs and hidden-file preference must migrate")
        try require(!legacy.singlePreview && legacy.leftDisplay.isEmpty, "Existing preview settings must survive a display-settings upgrade")
        let partial = try decode(#"{"explorer":{"compactView":true},"showHidden":true}"#)
        try require(partial.explorer.compactView && partial.explorer.showFileExtensions, "Partial preferences must use safe defaults")
        try require(!partial.showHidden && !partial.explorer.showHiddenFiles, "The new hidden preference must be the single source of truth")
        let unknown = try decode(#"{"explorer":{"startupLocation":"unknown","defaultViewMode":"unknown","startupPath":""}}"#)
        try require(unknown.explorer.startupLocation == "restore" && unknown.explorer.defaultViewMode == "details", "Unknown mode names must recover to supported choices")
        try require(!unknown.explorer.startupPath.isEmpty, "An empty startup path must not replace the home default")
        let icons = try decode(#"{"explorer":{"defaultViewMode":"icons"}}"#)
        try require(icons.explorer.defaultViewMode == "mediumIcons", "The legacy icons name must migrate")
        let stateDefaults = try JSONDecoder().decode(BrowserTabDisplaySettings.self, from: Data(#"{"groupBy":"type"}"#.utf8))
        try require(stateDefaults.visibleColumns.contains("name") && stateDefaults.groupBy == "type" && stateDefaults.ascending, "Partial tab display settings must retain defaults")
        try require(BrowserTabDisplaySettings().includesSubfolders && stateDefaults.includesSubfolders, "New and legacy tab settings must include subfolders by default")
        let legacySearch = try decode(#"{"leftTabs":["/legacy"],"leftDisplay":[{"viewMode":"details"}]}"#)
        try require(legacySearch.leftDisplay[0].includesSubfolders, "Existing saved sessions without a scope preference must receive the recursive default")
        let disabledSearch = try JSONDecoder().decode(BrowserTabDisplaySettings.self, from: Data(#"{"includesSubfolders":false}"#.utf8))
        try require(!disabledSearch.includesSubfolders, "An explicit disabled scope must not be mistaken for a missing preference")

        var settings = SavedSettings()
        settings.explorer.startupLocation = "custom"
        settings.explorer.startupPath = "/Users/example/Folder with spaces"
        settings.explorer.showFileExtensions = false
        settings.explorer.showHiddenFiles = true
        settings.explorer.defaultViewMode = "tiles"
        settings.explorer.compactView = true
        settings.showHidden = true
        settings.leftTabs = ["filemanager://this-mac", "/Users/example/Documents"]
        settings.leftSelectedTab = 1
        var display = BrowserTabDisplaySettings()
        display.includesSubfolders = false
        display.viewMode = "largeIcons"; display.groupBy = "date"; display.sortKey = "created"; display.ascending = false
        display.visibleColumns = ["name", "created", "dimensions", "duration"]
        display.columnOrder = ["name", "dimensions", "created", "duration"]
        display.columnWidths = ["name": 312, "dimensions": 160]
        settings.leftDisplay = [BrowserTabDisplaySettings(), display]
        settings.rightDisplay = [display]
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(settings))
        try require(restored.explorer == settings.explorer, "Every Options choice must round-trip")
        try require(restored.leftTabs == settings.leftTabs && restored.leftSelectedTab == 1, "Virtual and real tabs must retain order and selection")
        try require(restored.leftDisplay == settings.leftDisplay && restored.rightDisplay == settings.rightDisplay, "Grouping, columns, sizes and layout must round-trip independently per tab and pane")
        try require(restored.leftDisplay[0].includesSubfolders && !restored.leftDisplay[1].includesSubfolders && !restored.rightDisplay[0].includesSubfolders, "Enabled and explicitly disabled search scopes must survive saving independently per tab and pane")
        print("PASS: \(checks) Explorer preference migration and persistence checks")
    }
}
