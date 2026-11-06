import AppKit
import Darwin

func shortcutKey(for event: NSEvent) -> String {
    // Match macOS command-key translation so Control shortcuts also work with
    // layouts whose ordinary character output is non-Latin, such as Arabic.
    (event.characters(byApplyingModifiers: .command) ?? event.charactersIgnoringModifiers ?? "").lowercased()
}

/// Hover follows pointer intent, not rows moving underneath a stationary pointer.
final class PointerHoverCoordinator {
    static let shared = PointerHoverCoordinator()
    private final class WindowState: NSObject {
        var suppressed = false
        var gestureActive = false
        var momentumActive = false
        var selectionDragActive = false
        var anchor: NSPoint?
        var lastScrollActivity: TimeInterval?
        var pendingMovement: NSPoint?
        var recovery: DispatchWorkItem?
        var recoveryGeneration = 0
    }
    private let states = NSMapTable<NSWindow, WindowState>.weakToStrongObjects()
    private let participants = NSHashTable<PointerHoverState>.weakObjects()
    private let clipOrigins = NSMapTable<NSClipView, NSValue>.weakToStrongObjects()
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    // Scroll terminal events may be interrupted by native event tracking. A
    // genuine pointer move can recover after activity stops, even without one.
    private let recoveryInterval: TimeInterval = 0.15

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self, let window = event.window ?? NSApp.keyWindow else { return event }
            if event.type == .scrollWheel {
                self.scroll(in: window, at: event.locationInWindow, phase: event.phase, momentumPhase: event.momentumPhase)
            } else {
                self.pointerMoved(in: window, at: event.locationInWindow)
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let clip = notification.object as? NSClipView else { return }
            self?.clipBoundsChanged(clip)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            if let window = notification.object as? NSWindow { self?.deactivate(window) }
        })
    }
    private func state(for window: NSWindow) -> WindowState {
        if let state = states.object(forKey: window) { return state }
        let state = WindowState(); states.setObject(state, forKey: window); return state
    }
    fileprivate func register(_ participant: PointerHoverState) { participants.add(participant) }
    fileprivate func registerViewport(_ clip: NSClipView) {
        if clipOrigins.object(forKey: clip) == nil {
            clipOrigins.setObject(NSValue(point: clip.bounds.origin), forKey: clip)
        }
        clip.postsBoundsChangedNotifications = true
    }
    private func clipBoundsChanged(_ clip: NSClipView) {
        guard let previous = clipOrigins.object(forKey: clip)?.pointValue else { return }
        let origin = clip.bounds.origin
        clipOrigins.setObject(NSValue(point: origin), forKey: clip)
        // Resizing a preview or laying out another pane is not pointer scrolling.
        guard hypot(previous.x - origin.x, previous.y - origin.y) > 0.01,
              let window = clip.window else { return }
        for participant in participants.allObjects where participant.view?.isDescendant(of: clip) == true {
            participant.reset()
        }
        let point = window.mouseLocationOutsideOfEventStream
        if !clip.isHiddenOrHasHiddenAncestor,
           clip.visibleRect.contains(clip.convert(point, from: nil)),
           let hit = hitView(in: window, at: point),
           hit === clip || hit.isDescendant(of: clip) {
            viewportChanged(in: window, at: point)
        }
    }
    private func clear(in window: NSWindow) {
        for participant in participants.allObjects where participant.view?.window === window { participant.reset() }
    }
    private func cancelRecovery(_ state: WindowState) {
        state.recovery?.cancel(); state.recovery = nil
        state.pendingMovement = nil
        state.recoveryGeneration &+= 1
    }
    private func recoverAfterQuiet(in window: NSWindow, state: WindowState, point: NSPoint, delay: TimeInterval) {
        cancelRecovery(state)
        state.pendingMovement = point
        let generation = state.recoveryGeneration
        let recovery = DispatchWorkItem { [weak self, weak window, weak state] in
            guard let self, let window, let state,
                  generation == state.recoveryGeneration,
                  let movedPoint = state.pendingMovement else { return }
            let physicalPoint = window.mouseLocationOutsideOfEventStream
            // A later scroll invalidates this intent. Leaving the window or
            // moving elsewhere without an app event must not light an old item.
            guard window.isKeyWindow,
                  hypot(physicalPoint.x - movedPoint.x, physicalPoint.y - movedPoint.y) < 0.5 else {
                self.cancelRecovery(state); return
            }
            self.pointerMoved(in: window, at: physicalPoint)
        }
        state.recovery = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: recovery)
    }
    func scroll(in window: NSWindow, at point: NSPoint, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let state = state(for: window)
        cancelRecovery(state)
        state.lastScrollActivity = now
        state.suppressed = true; state.anchor = point
        if !phase.intersection([.mayBegin, .began]).isEmpty { state.momentumActive = false }
        if !phase.intersection([.mayBegin, .began, .changed, .stationary]).isEmpty { state.gestureActive = true }
        if !phase.intersection([.ended, .cancelled]).isEmpty { state.gestureActive = false }
        if !momentumPhase.intersection([.began, .changed, .stationary]).isEmpty {
            state.gestureActive = false; state.momentumActive = true
        }
        if !momentumPhase.intersection([.ended, .cancelled]).isEmpty { state.momentumActive = false }
        if phase.isEmpty && momentumPhase.isEmpty { state.gestureActive = false; state.momentumActive = false }
        clear(in: window)
    }
    func viewportChanged(in window: NSWindow, at point: NSPoint,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let state = state(for: window)
        cancelRecovery(state)
        if state.gestureActive || state.momentumActive { state.lastScrollActivity = now }
        state.suppressed = true; state.anchor = point
        clear(in: window)
    }
    func deactivate(_ window: NSWindow) {
        let state = state(for: window)
        state.gestureActive = false; state.momentumActive = false
        viewportChanged(in: window, at: window.mouseLocationOutsideOfEventStream)
    }
    func selectionDrag(in window: NSWindow, active: Bool, at point: NSPoint) {
        state(for: window).selectionDragActive = active
        viewportChanged(in: window, at: point)
    }
    func pointerMoved(in window: NSWindow, at point: NSPoint,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let state = state(for: window)
        if state.selectionDragActive { state.anchor = point; clear(in: window); return }
        if state.suppressed {
            if let anchor = state.anchor, hypot(point.x - anchor.x, point.y - anchor.y) < 0.5 { return }
            if state.gestureActive || state.momentumActive {
                let remaining = recoveryInterval - (now - (state.lastScrollActivity ?? now))
                if remaining > 0 {
                    recoverAfterQuiet(in: window, state: state, point: point, delay: remaining)
                    return
                }
                state.gestureActive = false; state.momentumActive = false
            }
            cancelRecovery(state)
            state.suppressed = false
        }
        // Re-evaluate all participants: the pointer can still be inside a tracking
        // area which entered while suppressed, so a fresh enter is not guaranteed.
        let hit = hitView(in: window, at: point)
        for participant in participants.allObjects where participant.view?.window === window {
            participant.update(at: point, hit: hit)
        }
    }
    fileprivate func hitView(in window: NSWindow, at point: NSPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }
    fileprivate func canHover(in window: NSWindow) -> Bool { !state(for: window).suppressed && !state(for: window).selectionDragActive }
}

final class PointerHoverState: NSObject {
    fileprivate weak var view: NSView?
    private let activeAlways: Bool
    private let onChange: (Bool) -> Void
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false

    init(view: NSView, activeAlways: Bool = false, onChange: @escaping (Bool) -> Void) {
        self.view = view; self.activeAlways = activeAlways; self.onChange = onChange
        super.init()
        PointerHoverCoordinator.shared.register(self)
    }
    func updateTrackingAreas() {
        guard let view else { return }
        let wasHovered = isHovered
        if let tracking { view.removeTrackingArea(tracking) }
        let activity: NSTrackingArea.Options = activeAlways ? .activeAlways : .activeInKeyWindow
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, activity], owner: self)
        view.addTrackingArea(area); tracking = area
        if let clip = view.enclosingScrollView?.contentView {
            PointerHoverCoordinator.shared.registerViewport(clip)
        }
        view.window?.acceptsMouseMovedEvents = true
        // AppKit also refreshes tracking after ordinary layout. Keep an existing
        // hover only while the physical pointer still hits an eligible view;
        // rebuilding tracking must never create hover without pointer intent.
        if wasHovered, let window = view.window {
            let point = window.mouseLocationOutsideOfEventStream
            update(at: point, hit: PointerHoverCoordinator.shared.hitView(in: window, at: point))
        } else {
            reset()
        }
    }
    func reset() { setHovered(false) }
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered; onChange(hovered)
    }
    fileprivate func update(at point: NSPoint, hit: NSView?) {
        guard let view, let window = view.window, (activeAlways || window.isKeyWindow),
              !view.isHiddenOrHasHiddenAncestor, (view as? NSControl)?.isEnabled != false,
              PointerHoverCoordinator.shared.canHover(in: window),
              view.visibleRect.contains(view.convert(point, from: nil)),
              let hit,
              acceptsHit(hit, in: view, at: point) else { reset(); return }
        setHovered(true)
    }
    private func acceptsHit(_ hit: NSView, in view: NSView, at point: NSPoint) -> Bool {
        if hit === view || hit.isDescendant(of: view) { return true }
        // View-based tables handle pointer events themselves instead of returning
        // their row/cell from hitTest. Match the actual row, including its buttons.
        guard let table = hit as? NSTableView else { return false }
        var ancestor: NSView? = view
        while let current = ancestor, current !== table {
            if let row = current as? NSTableRowView, row.isDescendant(of: table) {
                let index = table.row(for: row)
                return index >= 0 && table.row(at: table.convert(point, from: nil)) == index
            }
            ancestor = current.superview
        }
        return false
    }
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard let window = view?.window else { reset(); return }
        PointerHoverCoordinator.shared.pointerMoved(in: window, at: event.locationInWindow)
    }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { reset() }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        if let window = view?.window { PointerHoverCoordinator.shared.pointerMoved(in: window, at: event.locationInWindow) }
    }
}

struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev; inode = info.st_ino
    }
}

struct ExplorerPreferences: Codable, Equatable {
    static let viewModes = [("details", "Details"), ("list", "List"), ("smallIcons", "Small icons"),
                            ("mediumIcons", "Medium icons"), ("largeIcons", "Large icons"), ("tiles", "Tiles")]
    static let startupLocations = [("restore", "Restore previous tabs"), ("thisMac", "This Mac"),
                                   ("home", "Home folder"), ("custom", "Choose a folder…")]
    var startupLocation = "restore"
    var startupPath = FileManager.default.homeDirectoryForCurrentUser.path
    var showFileExtensions = true
    var showHiddenFiles = false
    var defaultViewMode = "details"
    var compactView = false
    init() {}
    private enum CodingKeys: String, CodingKey {
        case startupLocation, startupPath, showFileExtensions, showHiddenFiles, defaultViewMode, compactView
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startupLocation = try values.decodeIfPresent(String.self, forKey: .startupLocation) ?? "restore"
        startupPath = try values.decodeIfPresent(String.self, forKey: .startupPath) ?? FileManager.default.homeDirectoryForCurrentUser.path
        showFileExtensions = try values.decodeIfPresent(Bool.self, forKey: .showFileExtensions) ?? true
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        defaultViewMode = try values.decodeIfPresent(String.self, forKey: .defaultViewMode) ?? "details"
        compactView = try values.decodeIfPresent(Bool.self, forKey: .compactView) ?? false
        self = normalized()
    }
    func normalized() -> Self {
        var result = self
        if !Self.startupLocations.contains(where: { $0.0 == result.startupLocation }) { result.startupLocation = "restore" }
        if result.defaultViewMode == "icons" { result.defaultViewMode = "mediumIcons" }
        if !Self.viewModes.contains(where: { $0.0 == result.defaultViewMode }) { result.defaultViewMode = "details" }
        if result.startupPath.isEmpty { result.startupPath = FileManager.default.homeDirectoryForCurrentUser.path }
        return result
    }
}

struct BrowserTabDisplaySettings: Codable, Equatable {
    var viewMode = "details"
    var sortKey = "name"
    var ascending = true
    var groupBy = "none"
    var visibleColumns = ["name", "modified", "kind", "size"]
    var columnWidths: [String: Double] = [:]
    var columnOrder: [String] = []
    var columnsCustomized = false
    var includesSubfolders = true
    init() {}
    private enum CodingKeys: String, CodingKey {
        case viewMode, sortKey, ascending, groupBy, visibleColumns, columnWidths, columnOrder, columnsCustomized, includesSubfolders
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        viewMode = try values.decodeIfPresent(String.self, forKey: .viewMode) ?? "details"
        sortKey = try values.decodeIfPresent(String.self, forKey: .sortKey) ?? "name"
        ascending = try values.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        groupBy = try values.decodeIfPresent(String.self, forKey: .groupBy) ?? "none"
        visibleColumns = try values.decodeIfPresent([String].self, forKey: .visibleColumns) ?? ["name", "modified", "kind", "size"]
        columnWidths = try values.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? [:]
        columnOrder = try values.decodeIfPresent([String].self, forKey: .columnOrder) ?? []
        columnsCustomized = try values.decodeIfPresent(Bool.self, forKey: .columnsCustomized) ?? false
        includesSubfolders = try values.decodeIfPresent(Bool.self, forKey: .includesSubfolders) ?? true
    }
}

struct SavedSettings: Codable {
    var leftTabs: [String] = []
    var rightTabs: [String] = []
    var leftSelectedTab = 0
    var rightSelectedTab = 0
    var activeRightPane = false
    var split = false
    var preview = true
    var singlePreview = true
    var showHidden = false
    var explorer = ExplorerPreferences()
    var leftDisplay: [BrowserTabDisplaySettings] = []
    var rightDisplay: [BrowserTabDisplaySettings] = []
    init() {}
    private enum CodingKeys: String, CodingKey {
        case leftTabs, rightTabs, leftSelectedTab, rightSelectedTab, activeRightPane, split, preview, singlePreview, showHidden, explorer, leftDisplay, rightDisplay
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        leftTabs = try values.decodeIfPresent([String].self, forKey: .leftTabs) ?? []
        rightTabs = try values.decodeIfPresent([String].self, forKey: .rightTabs) ?? []
        leftSelectedTab = try values.decodeIfPresent(Int.self, forKey: .leftSelectedTab) ?? 0
        rightSelectedTab = try values.decodeIfPresent(Int.self, forKey: .rightSelectedTab) ?? 0
        activeRightPane = try values.decodeIfPresent(Bool.self, forKey: .activeRightPane) ?? false
        split = try values.decodeIfPresent(Bool.self, forKey: .split) ?? false
        preview = try values.decodeIfPresent(Bool.self, forKey: .preview) ?? true
        singlePreview = try values.decodeIfPresent(Bool.self, forKey: .singlePreview) ?? preview
        showHidden = try values.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        explorer = try values.decodeIfPresent(ExplorerPreferences.self, forKey: .explorer) ?? ExplorerPreferences()
        if !values.contains(.explorer) { explorer.showHiddenFiles = showHidden }
        showHidden = explorer.showHiddenFiles
        leftDisplay = try values.decodeIfPresent([BrowserTabDisplaySettings].self, forKey: .leftDisplay) ?? []
        rightDisplay = try values.decodeIfPresent([BrowserTabDisplaySettings].self, forKey: .rightDisplay) ?? []
    }
}

enum AppStorage {
    static var stateDirectory: URL {
        stateDirectory(bundleURL: Bundle.main.bundleURL,
                       projectWorkspace: Bundle.main.object(forInfoDictionaryKey: "ProjectWorkspace") as? String,
                       override: ProcessInfo.processInfo.environment["FILE_MANAGER_STATE_DIR"],
                       homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                       currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }

    /// Packaged apps keep private browsing data outside the source checkout. Plain
    /// development/test executables retain their isolated working-directory state.
    static func stateDirectory(bundleURL: URL, projectWorkspace: String?, override: String?,
                               homeDirectory: URL, currentDirectory: URL) -> URL {
        if let path = override, path.hasPrefix("/"), !path.contains("\0") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        // Compatibility for existing local development bundles and QA fixtures.
        if let path = projectWorkspace, path.hasPrefix("/"), !path.contains("\0") {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("state").standardizedFileURL
        }
        if bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return homeDirectory.appendingPathComponent("Library/Application Support/File Manager", isDirectory: true)
        }
        return currentDirectory.appendingPathComponent("state", isDirectory: true)
    }

    static var settingsURL: URL { stateDirectory.appendingPathComponent("settings.json") }
    static func load() -> SavedSettings {
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(SavedSettings.self, from: data) else { return SavedSettings() }
        return settings
    }
    static func save(_ settings: SavedSettings) {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch { NSLog("Could not save settings: %@", error.localizedDescription) }
    }
    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    var flat = false { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var selected = false { didSet { state = selected ? .on : .off; needsDisplay = true } }
    var showsChevron = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var symbolName: String?
    private lazy var hover = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovering: Bool { hover.isHovered }
    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; self.handler = handler; self.symbolName = symbol
        isBordered = false; focusRingType = .none; clipsToBounds = true
        font = .systemFont(ofSize: 17)
        target = self; action = #selector(invoke)
        setAccessibilityLabel(title)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { hover.reset() }; needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hover.reset() }
    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 17)]).width
        return NSSize(width: ceil(textWidth) + (symbolName == nil ? 0 : 28) + (showsChevron ? 20 : 0) + (flat ? 16 : 28), height: 38)
    }
    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        if isEnabled && isHighlighted { NSColor(calibratedWhite: 0.86, alpha: 1).setFill(); shape.fill() }
        else if selected { NSColor(calibratedRed: hovering ? 0.81 : 0.87, green: hovering ? 0.89 : 0.93, blue: 0.99, alpha: 1).setFill(); shape.fill() }
        else if isEnabled && hovering { NSColor(calibratedWhite: 0.91, alpha: 1).setFill(); shape.fill() }
        else if !flat { NSColor.white.setFill(); shape.fill() }
        if !flat { NSColor(calibratedWhite: 0.77, alpha: 1).setStroke(); shape.lineWidth = 1; shape.stroke() }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.8).setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            focus.lineWidth = 2; focus.stroke()
        }
        let ink = isEnabled ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor(calibratedWhite: 0.64, alpha: 1)
        var x: CGFloat = flat ? 8 : 14
        if let symbolName, let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 19, weight: .regular)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in symbol.draw(in: rect); (self.selected && self.title == "Preview" ? NSColor.systemBlue : ink).setFill(); rect.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: x, y: (bounds.height - 21) / 2, width: 21, height: 21)); x += 28
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 17), .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if showsChevron {
            let path = NSBezierPath(); let cx = bounds.maxX - 12; let cy = bounds.midY; let direction: CGFloat = isFlipped ? -1 : 1
            path.move(to: NSPoint(x: cx - 4, y: cy + 2 * direction)); path.line(to: NSPoint(x: cx, y: cy - 2 * direction)); path.line(to: NSPoint(x: cx + 4, y: cy + 2 * direction))
            ink.setStroke(); path.lineWidth = 1.3; path.stroke()
        }
    }
    @objc private func invoke() { if isEnabled { handler?() } }
}

final class HairlineView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ dirtyRect: NSRect) { NSColor(calibratedWhite: 0.84, alpha: 1).setFill(); bounds.fill() }
}

final class WindowTitleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class TrafficLightButton: NSButton {
    private lazy var hover = PointerHoverState(view: self, activeAlways: true) { [weak self] _ in self?.needsDisplay = true }
    private var hovering: Bool { hover.isHovered }
    private let controlLabel: String
    let fillColor: NSColor
    let handler: () -> Void
    init(color: NSColor, label: String, handler: @escaping () -> Void) {
        fillColor = color; self.handler = handler; controlLabel = label; super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(invoke)
        setAccessibilityLabel(label); clipsToBounds = true
        widthAnchor.constraint(equalToConstant: 14).isActive = true; heightAnchor.constraint(equalToConstant: 14).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hover.reset() }
    override func draw(_ dirtyRect: NSRect) {
        let oval = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (isHighlighted ? fillColor.blended(withFraction: 0.18, of: .black)! : fillColor).setFill(); oval.fill()
        fillColor.blended(withFraction: 0.15, of: .black)!.setStroke(); oval.lineWidth = 0.7; oval.stroke()
        guard hovering else { return }
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let mark = NSBezierPath(); mark.lineWidth = 1.2
        if controlLabel.hasPrefix("Close") {
            mark.move(to: NSPoint(x: 4, y: 4)); mark.line(to: NSPoint(x: 10, y: 10))
            mark.move(to: NSPoint(x: 4, y: 10)); mark.line(to: NSPoint(x: 10, y: 4))
        } else if controlLabel.hasPrefix("Minimize") {
            mark.move(to: NSPoint(x: 3.5, y: 7)); mark.line(to: NSPoint(x: 10.5, y: 7))
        } else {
            mark.move(to: NSPoint(x: 4, y: 4)); mark.line(to: NSPoint(x: 10, y: 10))
            mark.move(to: NSPoint(x: 4, y: 7)); mark.line(to: NSPoint(x: 4, y: 4)); mark.line(to: NSPoint(x: 7, y: 4))
            mark.move(to: NSPoint(x: 7, y: 10)); mark.line(to: NSPoint(x: 10, y: 10)); mark.line(to: NSPoint(x: 10, y: 7))
        }
        mark.stroke()
    }
    @objc private func invoke() { handler() }
}

final class ModalScrimView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { }
    override func scrollWheel(with event: NSEvent) { }
}

func makeLabel(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    label.textColor = color
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

func edgePin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

func separator(vertical: Bool = false) -> NSView {
    let line = HairlineView()
    line.translatesAutoresizingMaskIntoConstraints = false
    if vertical { line.widthAnchor.constraint(equalToConstant: 1).isActive = true }
    else { line.heightAnchor.constraint(equalToConstant: 1).isActive = true }
    return line
}

func byteText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
