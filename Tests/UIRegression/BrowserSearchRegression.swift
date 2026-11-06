// Hidden browser search integration. Compile with AppSupport, BrowserSearchSupport,
// BrowserPaneViewController, ThisMacViewController, ShortcutSupport, AppShortcutDocument,
// FileManagerCore objects and -I .build/debug/Modules -lsqlite3 -framework CoreServices.
// Mutates only .build/test-fixtures and never displays a window or posts system input.
import AppKit
@_spi(Testing) import FileManagerCore

private struct BrowserSearchFailure: Error, CustomStringConvertible { let description: String }

@main struct BrowserSearchRegression {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    private static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent(".build/test-fixtures/browser-search-\(UUID().uuidString)", isDirectory: true)
        let scope = fixture.appendingPathComponent("scope", isDirectory: true)
        let nested = scope.appendingPathComponent("nested", isDirectory: true)
        let other = fixture.appendingPathComponent("other", isDirectory: true)
        for url in [nested, other] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? manager.removeItem(at: fixture) }
        for i in 0..<1_205 {
            try Data("x".utf8).write(to: nested.appendingPathComponent(String(format: "match-%04d.txt", i)))
        }
        let largest = nested.appendingPathComponent("zzzz-match-latest.txt")
        try Data(repeating: 0x41, count: 8_192).write(to: largest)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: largest.path)
        let hidden = scope.appendingPathComponent(".hidden", isDirectory: true)
        try manager.createDirectory(at: hidden, withIntermediateDirectories: true)
        let hiddenFile = hidden.appendingPathComponent("match-hidden.txt")
        try Data("hidden".utf8).write(to: hiddenFile)
        let otherFile = other.appendingPathComponent("other-only.txt")
        try Data("other".utf8).write(to: otherFile)
        let shortcut = scope.appendingPathComponent("Report - Shortcut.fmlink")
        try AppShortcutDocument.data(for: otherFile).write(to: shortcut)
        let projectA = nested.appendingPathComponent("Project A", isDirectory: true)
        let projectB = nested.appendingPathComponent("Project B", isDirectory: true)
        let exactA = projectA.appendingPathComponent("DEMO", isDirectory: true)
        let exactB = projectB.appendingPathComponent("DEMO", isDirectory: true)
        let generated = nested.appendingPathComponent("node_modules", isDirectory: true)
        for url in [exactA, exactB, generated] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        for i in 0..<1_005 {
            try Data().write(to: generated.appendingPathComponent(String(format: "a-demo-%04d.txt", i)))
        }
        let prefixMatch = nested.appendingPathComponent("DEMO-notes.txt")
        let containsMatch = nested.appendingPathComponent("original-demo.log")
        for url in [prefixMatch, containsMatch] { try Data().write(to: url) }
        let generatedRecords = nested.appendingPathComponent(".claude/projects", isDirectory: true)
        try manager.createDirectory(at: generatedRecords, withIntermediateDirectories: true)
        let encodedName = generatedRecords.appendingPathComponent("-Users-test-DEMO", isDirectory: true)
        try manager.createDirectory(at: encodedName, withIntermediateDirectories: true)
        let index = FilenameSearchIndex(databaseURL: fixture.appendingPathComponent("search.sqlite"), scanBatchSize: 24, scanBatchDelay: 0.002)
        defer { index.close() }
        let pane = BrowserPaneViewController(url: scope, searchIndex: index)
        var status = "", statuses: [String] = []
        pane.onStatusChange = { status = $0; statuses.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.view; window.setContentSize(NSSize(width: 1_000, height: 750)); window.orderOut(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func find<T: NSView>(_ id: String, type: T.Type) throws -> T {
            guard let result = descendants(pane.view).first(where: { $0.identifier?.rawValue == id || $0.accessibilityIdentifier() == id }) as? T else {
                throw BrowserSearchFailure(description: "Missing browser control \(id)")
            }
            return result
        }
        let table = try find("browser.files", type: NSTableView.self)
        let search = try find("browser.search", type: NSSearchField.self)
        let canonicalColumnOrder = table.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "location" }
        var checks = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw BrowserSearchFailure(description: message) }
        }
        func wait(_ label: String, timeout: TimeInterval = 20, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            try require(condition(), "Timed out: \(label); status=\(status)")
        }
        func pump(_ duration: TimeInterval) {
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func rows() -> [URL] { (0..<table.numberOfRows).compactMap { pane.tableView(table, pasteboardWriterForRow: $0) as? URL } }
        func complete() -> Bool { !status.contains("Indexing") && !status.contains("Searching") && !status.contains("Loading") && !status.contains("Updating") }
        func diagnostic() throws -> FilenameSearchDiagnostics {
            var result: FilenameSearchDiagnostics?
            index.diagnostics { result = $0 }
            try wait("index diagnostics") { result != nil }
            return result!
        }
        try wait("initial direct listing") { pane.canReceiveFiles && rows().contains(shortcut) && complete() }
        try require(pane.displaySettings[0].includesSubfolders, "A new tab must include subfolders before the user changes search scope")
        try require(search.toolTip?.contains("and subfolders") == true, "The initial search tooltip must advertise the default recursive scope")
        guard let searchAction = search.action else { throw BrowserSearchFailure(description: "Search field has no action") }
        search.stringValue = "match"
        try require(app.sendAction(searchAction, to: search.target, from: search), "Typing into a fresh search field must route without explicitly choosing a scope")
        try wait("indexing status") { statuses.contains { $0.contains("Indexing") } }
        try wait("first complete capped result") { complete() && rows().count == 1_000 && status.contains("1,206") }
        try require(pane.isSearching && pane.currentSortKey == "bestMatch", "A new search must default to Best match")
        try require(statuses.contains { $0.contains("found so far") }, "Incomplete search counts must be labeled found so far")
        try require(status.contains("1,000") && status.contains("1,206"), "Capped results must disclose displayed and total counts")
        let showMore = try find("browser.search.showMore", type: NSButton.self)
        try require(!showMore.isHidden && showMore.isEnabled, "A truncated result needs a working Show More control")
        let firstScanCount = try diagnostic().scanCount
        let retainedSelection = rows()[0]
        pane.selectFiles([retainedSelection])
        showMore.performClick(nil)
        try wait("expanded search results") { complete() && rows().count == 1_206 }
        try require(Set(rows()).count == 1_206, "Show More must add results without duplicating rows")
        try require(pane.selectedURLs == [retainedSelection], "Expanding results must preserve the selected file")
        pane.setViewMode("mediumIcons")
        try require(pane.selectedURLs == [retainedSelection], "Switching indexed results to icons must preserve selection")
        pane.setViewMode("details")
        try require(pane.selectedURLs == [retainedSelection], "Returning indexed results to Details must preserve selection")
        try require(try diagnostic().scanCount == firstScanCount, "Show More must query the existing index without rescanning")

        // A fresh search resets the cap. Sort must consider all matches, not just the first page.
        pane.searchFiles("match", recursively: true)
        pane.setSort(key: "name", ascending: false)
        try wait("global descending name sort") { complete() && rows().first == largest }
        pane.setSort(key: "size", ascending: false)
        try wait("global descending size sort") { complete() && rows().first == largest }
        pane.setSort(key: "date", ascending: false)
        try wait("global descending date sort") { complete() && rows().first == largest }
        try require(try diagnostic().scanCount == firstScanCount, "Changing sort must not repeat the recursive filesystem scan")

        pane.setSort(key: "name", ascending: true)
        pane.searchFiles("match-hidden", recursively: true)
        try wait("hidden ancestor excluded") { complete() && rows().isEmpty }
        pane.setHiddenFiles(true)
        try wait("hidden ancestor included") { complete() && rows() == [hiddenFile] }
        pane.setHiddenFiles(false)
        try wait("hidden preference restored") { complete() && rows().isEmpty }

        // Send the real NSSearchField action to include the debounce and main-thread delivery in timing.
        let warmStart = ContinuousClock.now
        search.stringValue = "match-1204"
        try require(app.sendAction(searchAction, to: search.target, from: search), "Search field action must route")
        let selected = nested.appendingPathComponent("match-1204.txt")
        try wait("warm typed query becomes visible") { complete() && rows() == [selected] }
        let elapsed = warmStart.duration(to: ContinuousClock.now).components
        let inputVisibleMS = (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 1_000
        pane.selectFiles([selected])
        pane.searchFiles("match-000", recursively: true)
        pane.searchFiles("match-1204", recursively: true)
        try wait("latest rapidly changed query") { complete() && rows() == [selected] }
        pump(0.2)
        try require(rows() == [selected], "An old query must not replace the current visible results")

        pane.searchFiles("match", recursively: true)
        pane.navigate(to: other)
        try wait("navigation wins over pending search") { pane.currentURL == other && complete() && rows() == [otherFile] }
        pump(0.2)
        try require(rows() == [otherFile], "Late search callbacks must not populate a different folder")
        pane.navigate(to: scope)
        pane.searchFiles("Shortcut", recursively: true)
        try wait("shortcut document search") { complete() && rows() == [shortcut] }
        let nameColumn = table.tableColumns.first { $0.identifier.rawValue == "name" }!
        let shortcutCell = pane.tableView(table, viewFor: nameColumn, row: 0) as? NSTableCellView
        try require(shortcutCell?.textField?.stringValue == "Report - Shortcut", "Indexed shortcut results must retain the app's hidden extension display")
        pane.searchFiles("  \t  ", recursively: true)
        try wait("cleared search restores direct folder") { complete() && Set(rows()) == [nested, shortcut] }
        try require(!rows().contains(selected), "A whitespace-only recursive search must restore the direct folder without descendants")

        // Search-specific presentation must not rewrite normal-folder choices.
        pane.setSort(key: "size", ascending: false)
        var savedColumns = pane.displaySettings
        savedColumns[0].columnsCustomized = true
        savedColumns[0].visibleColumns = ["name", "size"]
        pane.restoreDisplaySettings(savedColumns)
        let normalSettings = pane.displaySettings[0]
        pane.searchFiles("demo", recursively: true)
        pane.setSort(key: "bestMatch", ascending: true)
        try wait("global relevance before pagination") { complete() && rows().count == 1_000 && Set(rows().prefix(2)) == [exactA, exactB] }
        try require(rows()[2] == prefixMatch, "Prefix matches must precede contains matches even when contains names sort earlier")
        try require(pane.displaySettings[0] == normalSettings, "Search sorting and Location must not alter normal-folder settings")
        guard let locationColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location")) else {
            throw BrowserSearchFailure(description: "Missing search Location column")
        }
        try require(!locationColumn.isHidden, "Recursive search must show Location even with customized columns")
        let locations = rows().prefix(2).enumerated().compactMap { offset, _ in
            (pane.tableView(table, viewFor: locationColumn, row: offset) as? NSTableCellView)?.textField?.stringValue
        }
        try require(Set(locations) == ["nested / Project A", "nested / Project B"], "Same-name results need distinct parent locations")
        let locationCell = pane.tableView(table, viewFor: locationColumn, row: 0) as? NSTableCellView
        try require(locationCell?.textField?.toolTip == rows()[0].deletingLastPathComponent().path, "Location tooltip must retain the full parent path")
        let scopeLabel = try find("browser.search.scope", type: NSTextField.self)
        try require(scopeLabel.stringValue.contains("Subfolders included") && scopeLabel.toolTip?.contains(scope.path) == true, "Search scope must be visible and identify its root")
        window.setContentSize(NSSize(width: 560, height: 750)); pane.view.layoutSubtreeIfNeeded()
        let locationIndex = table.tableColumns.firstIndex(of: locationColumn)!
        try require(table.rect(ofColumn: locationIndex).maxX <= (table.enclosingScrollView?.contentView.bounds.width ?? 0) + 1, "Location must remain visible in a narrow pane")
        window.setContentSize(NSSize(width: 1_000, height: 750)); pane.view.layoutSubtreeIfNeeded()
        pane.setViewMode("list")
        let collection = try find("browser.icons", type: NSCollectionView.self)
        let collectionItem = pane.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        try require(descendants(collectionItem.view).contains { $0.identifier?.rawValue == "browser.result.location" && !($0 as! NSTextField).stringValue.isEmpty }, "List results must show a secondary location label")
        pane.setViewMode("details")

        let scansBeforeFilter = try diagnostic().scanCount
        pane.setExcludeGeneratedSearchResults(true)
        try wait("generated folders excluded") { complete() && Set(rows()) == [exactA, exactB, prefixMatch, containsMatch] }
        try require(scopeLabel.stringValue.contains("Caches excluded"), "The active exclusion must remain visible")
        try require(try diagnostic().scanCount == scansBeforeFilter, "Exclusions must filter the catalog rather than rescan")

        // Exercise the real wide-to-split transition with adaptive defaults. The
        // customized-columns check above intentionally keeps its own explicit set.
        let customizedColumns = pane.displaySettings
        var adaptiveColumns = customizedColumns
        adaptiveColumns[0].columnsCustomized = false
        pane.restoreDisplaySettings(adaptiveColumns)
        func visibleColumns() -> [String] { table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } }
        for pass in 0..<2 {
            pane.setPresentationMode(split: false)
            window.setContentSize(NSSize(width: 1_160, height: 750)); pane.view.layoutSubtreeIfNeeded()
            try wait("wide search columns pass \(pass)") { visibleColumns() == ["name", "location", "modified", "kind", "size"] }
            try require(search.toolTip?.contains("Caches and generated folders excluded") == true, "Wide header rebuild must preserve the exclusion tooltip")
            pane.setPresentationMode(split: true)
            window.setContentSize(NSSize(width: 580, height: 750)); pane.view.layoutSubtreeIfNeeded()
            try wait("split search columns pass \(pass)") { visibleColumns() == ["name", "location", "size"] }
            let viewport = table.enclosingScrollView?.contentView.bounds.width ?? 0
            let shown = table.tableColumns.filter { !$0.isHidden }
            let totalWidth = shown.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(shown.count) * table.intercellSpacing.width
            try require(totalWidth <= viewport + 1 && table.frame.width <= viewport + 1, "Split search columns must fit the actual viewport without horizontal overflow")
            try require(search.toolTip?.contains("Caches and generated folders excluded") == true, "Split header rebuild must preserve the exclusion tooltip")
        }
        pane.restoreDisplaySettings(customizedColumns)
        window.setContentSize(NSSize(width: 1_000, height: 750)); pane.view.layoutSubtreeIfNeeded()
        pane.setExcludeGeneratedSearchResults(false)
        try wait("generated exclusion reversed") { complete() && rows().count == 1_000 && status.contains("1,009") }
        pane.setHiddenFiles(true)
        pane.searchFiles("-Users-test-DEMO", recursively: true)
        try wait("encoded basename shown literally") { complete() && rows() == [encodedName] }
        let encodedCell = pane.tableView(table, viewFor: nameColumn, row: 0) as? NSTableCellView
        try require(encodedCell?.textField?.stringValue == "-Users-test-DEMO", "Search must display real basenames without inventing or decoding path text")
        pane.setExcludeGeneratedSearchResults(true)
        try wait("hidden generated record excluded") { complete() && rows().isEmpty }
        try require(!status.contains("Searching") && !status.contains("found so far"), "A settled empty query must not retain a progress message")
        pane.setHiddenFiles(false)

        pane.navigate(to: generated)
        pane.searchFiles("a-demo-0000", recursively: false)
        try wait("explicit generated-root search") { complete() && rows().count == 1 }
        try require(pane.excludesGeneratedSearchResults, "The reversible exclusion preference must remain per tab")
        pane.navigate(to: nested)
        pane.searchFiles("demo", recursively: false)
        pane.setSort(key: "bestMatch", ascending: true)
        try wait("direct-folder relevance") { complete() && rows() == [prefixMatch, containsMatch] }
        try require(locationColumn.isHidden && scopeLabel.stringValue.contains("This folder"), "Direct-folder search must show its limited scope without a redundant Location column")
        pane.searchFiles("node_modules", recursively: false)
        try wait("direct generated filtering") { complete() && rows().isEmpty }
        pane.setExcludeGeneratedSearchResults(false)
        try wait("direct generated filtering reversed") { complete() && rows() == [generated] }

        pane.navigate(to: scope)
        pane.searchFiles("demo", recursively: true)
        pane.setExcludeGeneratedSearchResults(true)
        try wait("ready for background update") { complete() && rows().count == 4 }
        statuses.removeAll()
        let updatedFile = nested.appendingPathComponent("DEMO-update.txt")
        try Data().write(to: updatedFile)
        index.invalidate(in: nested)
        try wait("background updating label") { statuses.contains { $0.contains("Updating results") } }
        try wait("background updated results") { complete() && rows().count == 5 && rows().contains(updatedFile) }
        try require(!statuses.contains { $0.contains("Indexing folders") }, "A known catalog update must not be labeled initial indexing")
        pane.setSort(key: "date", ascending: false)
        pane.addTab(url: scope)
        pane.searchFiles("demo", recursively: true)
        try wait("new tab defaults") { complete() && rows().count == 1_000 }
        try require(pane.currentSortKey == "bestMatch" && !pane.excludesGeneratedSearchResults, "Search sort and exclusions must be independent per tab")
        pane.closeCurrentTab()
        try wait("restored search tab") { complete() && rows().count == 5 }
        try require(pane.currentSortKey == "date" && pane.excludesGeneratedSearchResults, "Returning to a tab must retain its own search options")
        if let sizeIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "size" }) { table.moveColumn(sizeIndex, toColumn: 0) }
        pane.searchFiles("", recursively: true)
        try wait("normal-folder options restored") { complete() && !pane.isSearching }
        try require(pane.currentSortKey == "size" && !pane.currentSortAscending && locationColumn.isHidden, "Clearing search must restore normal sort and hide Location")
        try require(pane.displaySettings[0] == normalSettings, "Search presentation must leave saved columns, order and sort unchanged")
        try require(table.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "location" } == canonicalColumnOrder, "Clearing search must restore canonical column order when no custom order was saved")
        var customOrderSettings = pane.displaySettings
        customOrderSettings[0].columnOrder = ["size"] + canonicalColumnOrder.filter { $0 != "size" }
        pane.restoreDisplaySettings(customOrderSettings)
        pane.searchFiles("demo", recursively: true)
        try wait("custom-order search") { complete() && rows().count == 5 }
        try require(table.tableColumns.prefix(2).map { $0.identifier.rawValue } == ["name", "location"], "Search must keep Name and Location visible regardless of normal custom order")
        pane.searchFiles("", recursively: true)
        try wait("custom-order normal view restored") { complete() && !pane.isSearching }
        try require(table.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "location" } == customOrderSettings[0].columnOrder, "Clearing search must preserve the user's custom normal column order")
        pane.addTab(url: scope)
        try wait("new tab canonical columns") { complete() && !pane.isSearching }
        try require(table.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "location" } == canonicalColumnOrder, "A new tab with default columns must not inherit another tab's custom order")
        pane.closeCurrentTab()
        try wait("custom tab restored") { complete() && !pane.isSearching }
        try require(table.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "location" } == customOrderSettings[0].columnOrder, "Returning to a customized tab must restore its column order")

        // The menu is the user's scope preference, so it must survive clearing,
        // navigation and session restoration rather than resetting on each query.
        var presentationChanges = 0
        pane.onPresentationChange = { presentationChanges += 1 }
        func chooseScope(_ recursively: Bool) throws {
            let item = NSMenuItem(title: recursively ? "Include subfolders" : "This folder", action: nil, keyEquivalent: "")
            item.tag = recursively ? 1 : 0
            let before = presentationChanges
            try require(app.sendAction(NSSelectorFromString("searchScopeSelected:"), to: pane, from: item), "The real search-scope menu action must route")
            try require(presentationChanges > before, "A user scope change must notify the window to persist it")
        }
        func typeQuery(_ query: String) throws {
            search.stringValue = query
            try require(app.sendAction(searchAction, to: search.target, from: search), "Search input must retain the selected scope")
        }
        try chooseScope(false)
        try typeQuery("match-1204")
        try wait("disabled subfolder scope excludes nested result") { complete() && rows().isEmpty }
        try require(!pane.displaySettings[0].includesSubfolders && scopeLabel.stringValue.contains("This folder"), "Disabling subfolders must update both the saved preference and visible scope")
        try typeQuery("")
        try wait("direct listing after clearing disabled scope") { complete() && !pane.isSearching && rows().contains(nested) }
        pane.navigate(to: other)
        try wait("navigate with disabled scope") { complete() && rows() == [otherFile] }
        pane.navigate(to: scope)
        try typeQuery("match-1204")
        try wait("disabled scope retained after navigation") { complete() && rows().isEmpty }
        try require(!pane.displaySettings[0].includesSubfolders, "Navigation must preserve an explicit This folder choice")
        pane.addTab(url: scope)
        try typeQuery("match-1204")
        try wait("new tab inherits disabled scope") { complete() && rows().isEmpty }
        try require(!pane.displaySettings[1].includesSubfolders, "New tabs must inherit the current tab's scope choice")
        try chooseScope(true)
        try wait("reenabled subfolders reveal nested result") { complete() && rows() == [selected] }
        try require(!pane.displaySettings[0].includesSubfolders && pane.displaySettings[1].includesSubfolders, "Changing one tab's scope must retain another tab's explicit choice")

        var savedSession = SavedSettings()
        savedSession.leftTabs = pane.openDirectories.map(\.path)
        savedSession.leftDisplay = pane.displaySettings
        let restoredSession = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(savedSession))
        pane.restoreTabs(restoredSession.leftTabs.map { URL(fileURLWithPath: $0) }, selectedIndex: 0)
        pane.restoreDisplaySettings(restoredSession.leftDisplay)
        try typeQuery("match-1204")
        try wait("disabled scope restored from saved session") { complete() && rows().isEmpty }
        try require(!pane.displaySettings[0].includesSubfolders && pane.displaySettings[1].includesSubfolders, "Session restoration must retain independent enabled and disabled scopes")
        try chooseScope(true)
        try wait("restored tab can enable subfolders again") { complete() && rows() == [selected] }
        print(String(format: "MEASURED: warm search input-to-visible %.2f ms (1,206 matching files; includes 75 ms debounce, no visible window)", inputVisibleMS))
        print("PASS: \(checks) indexed browser search checks for relevance, locations, scopes, generated-folder exclusions, progress stages, paging, sorting, hidden files, selection and tab restoration")
    }
}
