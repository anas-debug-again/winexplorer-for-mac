// Hidden native overview/sidebar regression. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift \
//   Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/SidebarViewController.swift \
//   Tests/UIRegression/ThisMacRegression.swift -o .build/qa/this-mac-regression
// .build/qa/this-mac-regression
// Add --render to save wide/narrow fixture renders. No window is displayed,
// no system mount state is changed, and no input events are posted.
import AppKit

private struct ThisMacRegressionFailure: Error, CustomStringConvertible { let description: String }
private final class ThisMacFixtureSource: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ThisMacVolumeSnapshot, Error>
    private var calls = 0
    init(_ snapshot: ThisMacVolumeSnapshot) { stored = .success(snapshot) }
    func set(_ result: Result<ThisMacVolumeSnapshot, Error>) { lock.lock(); stored = result; lock.unlock() }
    func read() throws -> ThisMacVolumeSnapshot { lock.lock(); calls += 1; let result = stored; lock.unlock(); return try result.get() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
private final class ThisMacDelayedSource: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let release = DispatchSemaphore(value: 0)
    let stale: ThisMacVolumeSnapshot
    let fresh: ThisMacVolumeSnapshot
    init(stale: ThisMacVolumeSnapshot, fresh: ThisMacVolumeSnapshot) { self.stale = stale; self.fresh = fresh }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func read() -> ThisMacVolumeSnapshot {
        lock.lock(); calls += 1; let call = calls; lock.unlock()
        if call == 1 { _ = release.wait(timeout: .now() + 5); return stale }
        return fresh
    }
}

@main struct ThisMacRegression {
    private static var checks = 0
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; if !condition() { throw ThisMacRegressionFailure(description: message) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private static func find(_ id: String, in root: NSView) -> NSView? {
        ([root] + descendants(root)).first { $0.accessibilityIdentifier() == id || $0.identifier?.rawValue == id }
    }
    private static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    private static func waitFor(_ condition: () -> Bool) throws {
        let until = Date().addingTimeInterval(5)
        while !condition(), Date() < until { pump(0.02) }
        try require(condition(), "Timed out waiting for overview state")
    }
    private static func cards(in view: NSView) -> [NSView] {
        descendants(view).filter { $0.accessibilityIdentifier().hasPrefix("thisMacVolume-") }
    }
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); NSApp.appearance = NSAppearance(named: .aqua)
        let internalDrive = ThisMacVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", group: .internalStorage,
            totalBytes: 1_000_000_000_000, availableBytes: 650_000_000_000)
        let externalDrive = ThisMacVolume(url: URL(fileURLWithPath: "/Volumes/Work SSD"), name: "Work SSD", group: .removableStorage,
            totalBytes: 500_000_000_000, availableBytes: 120_000_000_000)
        let longDrive = ThisMacVolume(url: URL(fileURLWithPath: "/Volumes/Camera archive"), name: "Camera archive with a longer volume name",
            group: .removableStorage, totalBytes: 256_000_000_000, availableBytes: 5_000_000_000, isReadOnly: true)
        let networkDrive = ThisMacVolume(url: URL(fileURLWithPath: "/Volumes/Team files"), name: "Team files", group: .networkStorage,
            totalBytes: nil, availableBytes: nil, capacityError: "The server did not report capacity.")
        let fixture = ThisMacVolumeSnapshot(volumes: [internalDrive, externalDrive, longDrive, networkDrive])
        try require(ThisMacVolumeGroup.classify(url: internalDrive.url, isLocal: true, isInternal: nil, isRemovable: nil, isEjectable: nil) == .internalStorage,
                    "Startup volume must classify as internal when the optional internal flag is missing")
        try require(ThisMacVolumeGroup.classify(url: externalDrive.url, isLocal: true, isInternal: false, isRemovable: false, isEjectable: false) == .removableStorage,
                    "An external fixed disk must stay in removable/external drives")
        try require(ThisMacVolumeGroup.classify(url: networkDrive.url, isLocal: false, isInternal: false, isRemovable: false, isEjectable: true) == .networkStorage,
                    "Network classification must take precedence over ejectability")
        try require(ThisMacVolumeGroup.classify(url: networkDrive.url, isLocal: nil, isInternal: nil, isRemovable: nil, isEjectable: nil) == .otherStorage,
                    "Unavailable classification must not invent internal/removable/network metadata")
        try require(abs((internalDrive.usedFraction ?? -1) - 0.35) < 0.0001, "Capacity bar must represent used bytes correctly")
        try require(networkDrive.usedFraction == nil, "Unknown capacity must not appear as an empty drive")
        let overreported = ThisMacVolume(url: externalDrive.url, name: "Overreported", group: .removableStorage, totalBytes: 100, availableBytes: 150)
        try require(overreported.usedFraction == 0, "Inconsistent free space must not produce a negative progress bar")
        let invalid = ThisMacVolume(url: externalDrive.url, name: "Invalid", group: .removableStorage, totalBytes: -1, availableBytes: 0)
        try require(invalid.usedFraction == nil, "Invalid capacity must remain unavailable")

        let source = ThisMacFixtureSource(fixture)
        let controller = ThisMacViewController(provider: source.read)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1_000, height: 740),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_000, height: 740))
        defer { window.close() }
        try waitFor { cards(in: controller.view).count == 4 }
        controller.view.layoutSubtreeIfNeeded()
        try require(controller.selectedURLs.isEmpty, "The overview must never expose mutable file selections")
        for group in [0, 1, 2] {
            try require(find("thisMacSection-\(group)", in: controller.view) != nil, "Overview must expose the requested drive sections")
        }
        let first = find("thisMacVolume-" + externalDrive.url.path, in: controller.view)!
        let second = find("thisMacVolume-" + longDrive.url.path, in: controller.view)!
        let firstWide = first.convert(first.bounds, to: controller.view)
        let secondWide = second.convert(second.bounds, to: controller.view)
        try require(abs(firstWide.minY - secondWide.minY) < 1 && abs(firstWide.minX - secondWide.minX) > 300,
                    "Wide layout must place two external cards side by side: \(firstWide), \(secondWide), root \(controller.view.bounds)")
        try require(firstWide.width >= 300, "Wide cards must leave room for names, capacity, and Open")
        let unknown = find("thisMacCapacity-" + networkDrive.url.path, in: controller.view) as! NSTextField
        try require(unknown.stringValue == "Storage information unavailable", "Missing network capacity must show a useful state")
        var opened: [URL] = []; var activations = 0
        controller.onNavigate = { opened.append($0) }; controller.onActivate = { activations += 1 }
        let open = find("thisMacOpen-" + externalDrive.url.path, in: controller.view) as! NSButton
        open.performClick(nil)
        try require(opened == [externalDrive.url] && activations == 1, "Open must activate the pane and navigate to the real mounted URL")
        let point = first.convert(NSPoint(x: 12, y: 12), to: nil)
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        first.mouseDown(with: doubleClick)
        try require(opened.last == externalDrive.url && opened.count == 2, "Double-clicking a card must open that volume")
        controller.focusContents()
        try require(window.firstResponder?.isKind(of: NSView.self) == true, "Overview keyboard focus must land on a visible control")
        let focused = window.firstResponder as! NSView
        try require(focused.isDescendant(of: controller.view), "Overview focus must not remain on a hidden browser table")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        focused.keyDown(with: enter)
        try require(opened.last == internalDrive.url && opened.count == 3, "Enter on the first volume card must open the internal drive")

        if CommandLine.arguments.contains("--render") { try render(controller, window: window, suffix: "wide") }
        window.setContentSize(NSSize(width: 500, height: 740)); controller.view.layoutSubtreeIfNeeded(); pump(0.05)
        controller.view.layoutSubtreeIfNeeded()
        let narrowFirst = find("thisMacVolume-" + externalDrive.url.path, in: controller.view)!
        let narrowSecond = find("thisMacVolume-" + longDrive.url.path, in: controller.view)!
        let a = narrowFirst.convert(narrowFirst.bounds, to: controller.view)
        let b = narrowSecond.convert(narrowSecond.bounds, to: controller.view)
        try require(abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) > 140, "Narrow panes must use one readable card per row")
        try require(a.width > 400, "Narrow cards must fill the pane without horizontal clipping")
        if CommandLine.arguments.contains("--render") { try render(controller, window: window, suffix: "narrow") }

        source.set(.success(ThisMacVolumeSnapshot(volumes: [internalDrive])))
        let beforeMount = source.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        try waitFor { source.count > beforeMount && cards(in: controller.view).count == 1 }
        source.set(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "Fixture read error."])))
        controller.refresh()
        let status = find("thisMacStatus", in: controller.view) as! NSTextField
        try waitFor { status.stringValue.contains("Couldn’t refresh") }
        try require(cards(in: controller.view).count == 1 && status.stringValue.contains("last available"), "Refresh errors must retain and label the last successful snapshot")
        source.set(.success(ThisMacVolumeSnapshot(volumes: [])))
        controller.refresh(); try waitFor { status.stringValue == "0 drives" }
        try require(cards(in: controller.view).isEmpty, "An empty snapshot must not invent drive cards")

        let delayed = ThisMacDelayedSource(stale: fixture, fresh: ThisMacVolumeSnapshot(volumes: [networkDrive]))
        let racing = ThisMacViewController(provider: delayed.read)
        let raceWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        raceWindow.contentViewController = racing
        raceWindow.setContentSize(NSSize(width: 500, height: 500))
        defer { delayed.release.signal(); raceWindow.close() }
        try waitFor { delayed.count == 1 }
        racing.refresh()
        try waitFor { cards(in: racing.view).count == 1 }
        delayed.release.signal(); pump(0.1)
        try require(cards(in: racing.view).count == 1 && find("thisMacOpen-" + networkDrive.url.path, in: racing.view) != nil,
                    "A stale asynchronous response must not overwrite a newer refresh")

        let sidebar = SidebarViewController()
        sidebar.selectThisMac()
        let sidebarWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 260, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        sidebarWindow.contentViewController = sidebar
        sidebarWindow.setContentSize(NSSize(width: 260, height: 700))
        defer { sidebarWindow.close() }
        sidebar.view.layoutSubtreeIfNeeded()
        let thisMac = find("sidebar-this-mac", in: sidebar.view) as! NSButton
        let outline = descendants(sidebar.view).first { $0 is NSOutlineView } as! NSOutlineView
        var thisMacRequests = 0, fileNavigations = 0
        sidebar.onThisMac = { thisMacRequests += 1 }; sidebar.onNavigate = { _ in fileNavigations += 1 }
        try require(thisMac.state == .on && outline.selectedRow == -1, "Pre-load This Mac selection must be restored without selecting a folder")
        thisMac.performClick(nil)
        try require(thisMacRequests == 1 && fileNavigations == 0, "This Mac shortcut must use its virtual-location callback")
        sidebar.selectRecents()
        try require(thisMac.state == .off, "Recents must clear This Mac highlighting")
        sidebar.select(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        try require(thisMac.state == .off, "A real folder must clear This Mac highlighting")
        sidebar.selectThisMac()
        try require(thisMac.state == .on && outline.selectedRow == -1, "This Mac must clear prior folder selection")
        try require(!window.isVisible && !raceWindow.isVisible && !sidebarWindow.isVisible, "Regression windows must remain hidden")
        print("PASS: \(checks) This Mac checks for grouping/capacity, adaptive layout, opening/focus, mount refresh, error/empty/stale states, and sidebar selection")
    }
    private static func render(_ controller: ThisMacViewController, window: NSWindow, suffix: String) throws {
        let root = controller.view
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa/this-mac-\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
    }
}
