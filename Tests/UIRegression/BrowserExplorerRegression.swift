// Hidden native Explorer display regression. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/ThisMacViewController.swift \
//   Sources/MacFileManager/BrowserPaneViewController.swift Sources/MacFileManager/ShortcutSupport.swift Tests/UIRegression/BrowserExplorerRegression.swift -o .build/qa/browser-explorer-regression
// .build/qa/browser-explorer-regression
import AppKit
private struct ExplorerFailure: Error, CustomStringConvertible { let description: String }
@main struct BrowserExplorerRegression {
 static func main() throws {
  let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.appearance = NSAppearance(named: .aqua)
  var checks = 0
  func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { checks += 1; if !condition() { throw ExplorerFailure(description: message) } }
  func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
  let fm = FileManager.default
  let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/qa/explorer-fixtures-\(UUID().uuidString)", isDirectory: true)
  try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
  let folder = root.appendingPathComponent("Folder.keep", isDirectory: true)
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  let alpha = root.appendingPathComponent("alpha.png"), beta = root.appendingPathComponent("beta.txt"), empty = root.appendingPathComponent("empty.txt"), audio = root.appendingPathComponent("sample.wav"), large = root.appendingPathComponent("large.bin")
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  try bitmap.representation(using: .png, properties: [:])!.write(to: alpha)
  try Data("hello".utf8).write(to: beta); try Data().write(to: empty); try Data().write(to: large)
  let largeHandle = try FileHandle(forWritingTo: large); try largeHandle.truncate(atOffset: 104_857_601); try largeHandle.close()
  var wav = Data()
  func tag(_ string: String) { wav.append(contentsOf: string.utf8) }
  func little<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
  let bytes: UInt32 = 16_000 * 2 * 2
  tag("RIFF"); little(UInt32(36) + bytes); tag("WAVEfmt "); little(UInt32(16)); little(UInt16(1)); little(UInt16(1)); little(UInt32(16_000)); little(UInt32(32_000)); little(UInt16(2)); little(UInt16(16)); tag("data"); little(bytes); wav.append(Data(count: Int(bytes))); try wav.write(to: audio)
  try fm.setAttributes([.modificationDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())!], ofItemAtPath: beta.path)
  let expected = Set([folder, alpha, beta, empty, audio, large])
  let pane = BrowserPaneViewController(url: root)
  var status = "", presentationChanges = 0, actions: [BrowserAction] = []
  pane.onStatusChange = { status = $0 }; pane.onPresentationChange = { presentationChanges += 1 }; pane.onRequestAction = { actions.append($0) }
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = pane.view; window.orderOut(nil); defer { window.close() }
  let table = descendants(pane.view).first { $0 is NSTableView } as! NSTableView
  func wait(_ description: String, _ condition: () -> Bool) throws {
   let deadline = Date().addingTimeInterval(7)
   while (!condition() || status.contains("Loading") || status.contains("Searching")) && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
   try require(condition() && !status.contains("Loading") && !status.contains("Searching"), "Timed out: \(description)")
  }
  try wait("initial files") { table.numberOfRows == expected.count }
  pane.setPresentationMode(split: false); pane.view.layoutSubtreeIfNeeded()
  func url(at row: Int) -> URL? { pane.tableView(table, pasteboardWriterForRow: row) as? URL }
  func row(of url: URL) -> Int { (0..<table.numberOfRows).first { selfURL in (pane.tableView(table, pasteboardWriterForRow: selfURL) as? URL) == url }! }
  let selected = Set([alpha, beta]); pane.selectFiles(Array(selected))
  for group in ["name", "date", "type", "size", "none"] {
   pane.setGroupBy(group)
   try require(Set(pane.selectedURLs) == selected, "Grouping \(group) must preserve actual selected URLs")
   let headers = (0..<table.numberOfRows).filter { pane.tableView(table, isGroupRow: $0) }
   try require(group == "none" ? headers.isEmpty : !headers.isEmpty, "Grouping must produce real table headers")
   for header in headers { try require(!pane.tableView(table, shouldSelectRow: header) && url(at: header) == nil, "Group headers must be nonselectable and nondraggable") }
   try require(Set((0..<table.numberOfRows).compactMap(url)) == expected, "Grouped row mapping must contain every actual file once")
   table.selectAll(nil); try require(Set(pane.selectedURLs) == expected, "Select All must exclude headers")
   pane.selectFiles(Array(selected))
  }
  pane.setGroupBy("type")
  pane.view.layoutSubtreeIfNeeded()
  if let image = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
   pane.view.cacheDisplay(in: pane.view.bounds, to: image)
   try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/qa/explorer-details.png"))
  }
  let contextPoint = table.convert(NSPoint(x: 60, y: table.rect(ofRow: row(of: beta)).midY), to: nil)
  let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: contextPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  let fileMenu = table.menu(for: contextEvent)!; pane.menuNeedsUpdate(fileMenu)
  try require(Set(pane.selectedURLs) == selected, "Grouped right-click must preserve selected file URLs")
  let sendMenu = fileMenu.item(withTitle: "Send to")!.submenu!
  var sentURLs: [URL] = [], sentDestination: URL?
  pane.onSendToFolder = { sentURLs = $0; sentDestination = $1 }
  let documents = sendMenu.item(withTitle: "Documents")!
  app.sendAction(documents.action!, to: documents.target, from: documents)
  try require(Set(sentURLs) == selected && sentDestination == fm.urls(for: .documentDirectory, in: .userDomainMask).first, "Send to Documents must delegate selected files and actual folder destination")
  let shortcut = sendMenu.item(withTitle: "Desktop (create shortcut)")!
  app.sendAction(shortcut.action!, to: shortcut.target, from: shortcut)
  try require(actions.contains { if case .sendToDesktopAlias = $0 { return true }; return false }, "Send to Desktop must request alias creation")
  var modeSizes: [String: NSSize] = [:]
  for mode in ["list", "smallIcons", "mediumIcons", "largeIcons", "tiles"] {
   pane.setViewMode(mode); pane.view.layoutSubtreeIfNeeded()
   let collection = descendants(pane.view).first { $0 is NSCollectionView } as! NSCollectionView
   collection.layoutSubtreeIfNeeded()
   try require(Set(pane.selectedURLs) == selected, "\(mode) must preserve selection across grouped layouts")
   try require(collection.numberOfSections > 1, "\(mode) must use real collection sections")
   var all = Set<URL>()
   for section in 0..<collection.numberOfSections {
    for item in 0..<collection.numberOfItems(inSection: section) {
     let path = IndexPath(item: item, section: section)
     if let value = pane.collectionView(collection, pasteboardWriterForItemAt: path) as? URL { all.insert(value) }
    }
   }
   try require(all == expected, "Collection groups must map each file once in \(mode)")
   modeSizes[mode] = (collection.collectionViewLayout as! NSCollectionViewFlowLayout).itemSize
   if let image = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
    pane.view.cacheDisplay(in: pane.view.bounds, to: image)
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/qa/explorer-\(mode).png"))
   }
   collection.selectAll(nil); try require(Set(pane.selectedURLs) == expected, "Native icon Select All must include every group")
   pane.selectFiles(Array(selected))
  }
  try require(Set(modeSizes.values.map { "\($0.width)x\($0.height)" }).count == 5, "Each view mode must have a genuinely distinct layout")
  let tileCollection = descendants(pane.view).first { $0 is NSCollectionView } as! NSCollectionView
  for compact in [false, true] {
   pane.setDisplayPreferences(showExtensions: true, compact: compact, defaultViewMode: "details")
   for width in [580.0, 960.0, 1180.0, 580.0] {
    window.setContentSize(NSSize(width: width, height: 700))
    pane.view.layoutSubtreeIfNeeded(); pane.viewDidLayout(); tileCollection.layoutSubtreeIfNeeded()
    let layout = tileCollection.collectionViewLayout as! NSCollectionViewFlowLayout
    let viewport = tileCollection.enclosingScrollView!.contentView.bounds.width
    let gap: CGFloat = compact ? 5 : 8
    let available = viewport - 24
    let columns = max(1, floor((available + gap) / (284 + gap)))
    let expectedWidth = (available - gap * (columns - 1)) / columns
    try require(abs(layout.itemSize.width - expectedWidth) < 0.5, "Tiles must fill column slots at width \(width), compact=\(compact)")
    try wait("tile left alignment at \(width)") {
     guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else { return false }
     return abs(frame.minX - 12) < 1 && abs(frame.width - expectedWidth) < 1 && frame.maxX <= viewport - 11
    }
    try require(layout.itemSize.width >= 284 && Set(pane.selectedURLs) == selected, "Resizing tiles must retain readable columns and selected URLs")
   }
  }
  window.setContentSize(NSSize(width: 960, height: 700))
  pane.setDisplayPreferences(showExtensions: true, compact: false, defaultViewMode: "details")
  pane.setViewMode("icons"); try require(pane.currentViewMode == "mediumIcons", "Legacy icons must map to medium icons")
  pane.setViewMode("details"); pane.setGroupBy("none")
  pane.setDisplayPreferences(showExtensions: false, compact: true, defaultViewMode: "details")
  let nameColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
  let alphaCell = table.view(atColumn: nameColumn, row: row(of: alpha), makeIfNecessary: true) as! NSTableCellView
  let folderCell = table.view(atColumn: nameColumn, row: row(of: folder), makeIfNecessary: true) as! NSTableCellView
  try require(alphaCell.textField?.stringValue == "alpha" && folderCell.textField?.stringValue == "Folder.keep", "Hide extensions must affect files only")
  try require(pane.tableView(table, heightOfRow: row(of: alpha)) == 28 && Set(pane.selectedURLs) == selected, "Compact spacing must preserve selection")
  func headerMenu() -> NSMenu {
   let header = table.headerView!
   let event = NSEvent.mouseEvent(with: .rightMouseDown, location: header.convert(NSPoint(x: 20, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
   return header.menu(for: event)!
  }
  var menu = headerMenu()
  try require(menu.item(withTitle: "Name")?.isEnabled == false, "Name must remain mandatory")
  for title in ["Date created", "Dimensions", "Duration"] {
   menu = headerMenu(); let item = menu.item(withTitle: title)!
   app.sendAction(item.action!, to: item.target, from: item)
   try require(Set(pane.selectedURLs) == selected, "Toggling \(title) must preserve selected files")
  }
  func text(_ key: String, _ url: URL) -> String {
   let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(key))
   return (table.view(atColumn: column, row: row(of: url), makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? ""
  }
  try wait("asynchronous image dimensions") { text("dimensions", alpha) == "32 × 24" }
  try wait("asynchronous audio duration") { text("duration", audio) == "0:02" }
  try require(text("dimensions", beta) == "—" && !text("created", alpha).isEmpty, "Unsupported media must show a real unavailable value and Created must load")
  var saved = pane.displaySettings
  saved[0].viewMode = "tiles"; saved[0].groupBy = "size"; saved[0].sortKey = "size"; saved[0].ascending = false
  saved[0].visibleColumns = ["size", "created"]; saved[0].columnsCustomized = true
  saved[0].columnOrder = ["name", "size", "created", "modified", "kind", "dimensions", "duration"]
  saved[0].columnWidths = ["name": 300, "size": 125]
  pane.restoreDisplaySettings(saved)
  try require(pane.currentViewMode == "tiles" && pane.currentGroupBy == "size" && pane.currentSortKey == "size" && !pane.currentSortAscending, "Saved display options must restore")
  pane.setViewMode("details"); pane.view.layoutSubtreeIfNeeded(); pane.viewDidLayout()
  try require(table.tableColumns[1].identifier.rawValue == "size" && table.tableColumns[1].width == 125 && !table.tableColumns[0].isHidden, "Saved column order/width must restore and Name stay visible")
  pane.setDisplayPreferences(showExtensions: true, compact: false, defaultViewMode: "largeIcons")
  try require(pane.currentViewMode == "largeIcons" && Set(pane.selectedURLs) == selected, "Changing default view must apply it while preserving selection")
  pane.setViewMode("details")
  pane.setDisplayPreferences(showExtensions: false, compact: false, defaultViewMode: "largeIcons")
  try require(pane.currentViewMode == "details", "Unchanged default must not overwrite a manually chosen mode")
  pane.addTab(url: root); try require(pane.currentViewMode == "largeIcons", "New tabs must use the chosen default mode")
  let legacyColumns = try JSONDecoder().decode(BrowserTabDisplaySettings.self, from: Data("{}".utf8))
  try require(!legacyColumns.columnsCustomized, "Legacy display settings must keep responsive columns")
  pane.setViewMode("details"); pane.setPresentationMode(split: true)
  let adaptive = pane.displaySettings
  try require(!adaptive.last!.columnsCustomized && table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("kind"))!.isHidden, "Default split columns must hide Type without becoming customized")
  pane.restoreDisplaySettings(adaptive); pane.setPresentationMode(split: false); pane.view.layoutSubtreeIfNeeded()
  try require(!table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("kind"))!.isHidden, "Restored default columns must show Type again in single view")
  pane.showThisMac()
  try require(pane.isShowingThisMac && pane.currentURL == BrowserPaneViewController.thisMacURL && pane.selectedURLs.isEmpty, "This Mac must be a virtual empty-selection location")
  let original = pane.currentURL; pane.goUp(); try require(pane.currentURL == original, "This Mac Up must not navigate a sentinel path")
  pane.showRecents(); try require(pane.isShowingRecents && !pane.isShowingThisMac, "Recents must remain distinct when entered from This Mac")
  pane.goBack(); try require(pane.isShowingThisMac, "Back must restore This Mac")
  pane.goBack(); try require(pane.currentURL == root, "Back from This Mac must restore the previous real folder")
  pane.goForward(); try require(pane.isShowingThisMac, "Forward must restore This Mac")
  pane.restoreTabs([root, BrowserPaneViewController.thisMacURL], selectedIndex: 1)
  try require(pane.isShowingThisMac && pane.openDirectories[1] == BrowserPaneViewController.thisMacURL, "Persisted sentinel tabs must restore without becoming file URLs")
  try require(presentationChanges > 10, "Presentation changes must notify persistence")
  print("PASS: \(checks) Explorer browser checks for groups, mappings, modes, spacing/extensions, columns, image/audio metadata, defaults and This Mac history")
 }
}
