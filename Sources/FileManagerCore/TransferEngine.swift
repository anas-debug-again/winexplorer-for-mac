import Foundation
import Darwin

public enum TransferKind: String, Sendable { case copy, move }
public enum ConflictChoice: Sendable { case keepBoth, skip, replace, cancel }
public enum TransferPhase: Sendable { case preparing, transferring, waiting, completed, cancelled, failed }

public struct TransferProgress: Sendable {
    public let id: UUID
    public let kind: TransferKind
    public let sources: [URL]
    public let destination: URL
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalFiles: Int
    public let completedFiles: Int
    public let currentFile: String
    public let phase: TransferPhase
    public let message: String?
    public let bytesPerSecond: Double
    public let remainingSeconds: Double?
    /// Captured before transfer, aligned with sources; empty only before inspection.
    public let sourceDirectoryFlags: [Bool]
    /// Actual committed names, including Keep Both renames, retained after moves.
    public let committedDestinations: [URL]

    public init(id: UUID, kind: TransferKind, sources: [URL], destination: URL,
                totalBytes: Int64, completedBytes: Int64, totalFiles: Int, completedFiles: Int,
                currentFile: String, phase: TransferPhase, message: String?,
                bytesPerSecond: Double, remainingSeconds: Double?,
                sourceDirectoryFlags: [Bool] = [], committedDestinations: [URL] = []) {
        self.id = id; self.kind = kind; self.sources = sources; self.destination = destination
        self.totalBytes = totalBytes; self.completedBytes = completedBytes
        self.totalFiles = totalFiles; self.completedFiles = completedFiles
        self.currentFile = currentFile; self.phase = phase; self.message = message
        self.bytesPerSecond = bytesPerSecond; self.remainingSeconds = remainingSeconds
        self.sourceDirectoryFlags = sourceDirectoryFlags; self.committedDestinations = committedDestinations
    }
}

public struct FileConflict: Sendable {
    public let jobID: UUID
    public let source: URL
    public let destination: URL
    public let isDirectory: Bool
    public let canReplace: Bool
    public let suggestedName: String
}

public struct ConflictResolution: Sendable {
    public let choice: ConflictChoice
    public let applyToRemaining: Bool

    public init(choice: ConflictChoice, applyToRemaining: Bool = false) {
        self.choice = choice
        self.applyToRemaining = applyToRemaining
    }
}

/// Performs independent jobs on background queues. Every public callback is delivered
/// asynchronously on the main queue. A conflict completion may be called from any queue.
/// Completed items remain in place when a job is cancelled; incomplete staging is removed.
public final class TransferEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UUID: TransferJob] = [:]

    public init() {}

    @discardableResult
    public func start(
        kind: TransferKind,
        sources: [URL],
        destination: URL,
        onProgress: @escaping (TransferProgress) -> Void,
        onConflict: @escaping (FileConflict, @escaping (ConflictResolution) -> Void) -> Void
    ) -> UUID {
        let job = TransferJob(kind: kind, sources: sources, destination: destination,
                              onProgress: onProgress, onConflict: onConflict)
        lock.lock()
        jobs[job.id] = job
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self, job] in
            job.run()
            lock.lock()
            jobs.removeValue(forKey: job.id)
            lock.unlock()
        }
        return job.id
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        let job = jobs[id]
        lock.unlock()
        job?.cancel()
    }
}

private enum TransferFailure: LocalizedError {
    case cancelled
    case invalid(String)
    case changed(String)
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Transfer cancelled. Completed items were kept."
        case .invalid(let message): return message
        case .changed(let path): return "\(path) changed during the transfer. Its source was preserved."
        case .system(let operation, let code):
            return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

private enum EntryKind { case file, directory, symbolicLink }

private struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }

    var kind: EntryKind? {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): return .file
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symbolicLink
        default: return nil
        }
    }

    func isSameObject(as other: FileStamp) -> Bool {
        device == other.device && inode == other.inode
    }

    // A rename may update ctime. Compare identity and content metadata separately
    // when validating an object that we have just atomically renamed.
    func matchesAfterRename(_ other: FileStamp) -> Bool {
        isSameObject(as: other) && mode == other.mode && size == other.size
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}

private struct PlannedEntry {
    let source: URL
    let stamp: FileStamp
    let kind: EntryKind
    let children: [PlannedEntry]
    let bytes: Int64
    let fileCount: Int
}

private struct DestinationDecision {
    let url: URL
    let replaceStamp: FileStamp?
    let keepBoth: Bool
}

private final class CopyContext {
    unowned let job: TransferJob
    let baseBytes: Int64
    let fileBytes: Int64

    init(job: TransferJob, baseBytes: Int64, fileBytes: Int64) {
        self.job = job
        self.baseBytes = baseBytes
        self.fileBytes = fileBytes
    }
}

private let transferCopyCallback: copyfile_callback_t = { what, stage, state, _, _, pointer in
    guard let pointer else { return COPYFILE_QUIT }
    let context = Unmanaged<CopyContext>.fromOpaque(pointer).takeUnretainedValue()
    if context.job.isCancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS || stage == COPYFILE_FINISH {
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
            context.job.recordCopyBytes(context.baseBytes + min(Int64(copied), context.fileBytes))
        }
    }
    return COPYFILE_CONTINUE
}

private final class TransferJob: @unchecked Sendable {
    let id = UUID()
    let kind: TransferKind
    let sources: [URL]
    let destination: URL
    let onProgress: (TransferProgress) -> Void
    let onConflict: (FileConflict, @escaping (ConflictResolution) -> Void) -> Void

    private let condition = NSCondition()
    private var cancelled = false
    private var conflictToken: UUID?
    private var conflictResolution: ConflictResolution?
    private var rememberedFileChoice: ConflictChoice?
    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var totalFiles = 0
    private var completedFiles = 0
    private var committedBytes: Int64 = 0
    private var committedFiles = 0
    private var currentFile = ""
    private var phase: TransferPhase = .preparing
    private var lastEmission: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var waitingTime: TimeInterval = 0
    private var skipped = 0
    private var warnings: [String] = []
    private var sourceDirectoryFlags: [Bool] = []
    private var committedDestinations: [URL] = []
    private var destinationIdentity: FileStamp?
    private var destinationDescriptor: Int32 = -1
    private let manager = FileManager.default

    init(kind: TransferKind, sources: [URL], destination: URL,
         onProgress: @escaping (TransferProgress) -> Void,
         onConflict: @escaping (FileConflict, @escaping (ConflictResolution) -> Void) -> Void) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.onProgress = onProgress
        self.onConflict = onConflict
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    private func checkCancellation() throws {
        if isCancelled { throw TransferFailure.cancelled }
    }

    func run() {
        defer { if destinationDescriptor >= 0 { close(destinationDescriptor) } }
        startedAt = ProcessInfo.processInfo.systemUptime
        emit(force: true)
        do {
            try checkCancellation()
            guard !sources.isEmpty else { throw TransferFailure.invalid("Choose at least one item to transfer.") }
            guard destination.isFileURL, sources.allSatisfy(\.isFileURL) else {
                throw TransferFailure.invalid("Transfers require local file URLs.")
            }
            let targetFolder = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard let targetStamp = try stamp(at: targetFolder), targetStamp.kind == .directory else {
                throw TransferFailure.invalid("The destination must be an existing folder.")
            }
            destinationDescriptor = open(targetFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard destinationDescriptor >= 0 else {
                throw TransferFailure.system("Cannot open the destination folder", errno)
            }
            var openedTarget = stat()
            guard fstat(destinationDescriptor, &openedTarget) == 0,
                  targetStamp.isSameObject(as: FileStamp(openedTarget)) else {
                throw TransferFailure.invalid("The destination folder changed. Transfer stopped to protect your files.")
            }
            destinationIdentity = targetStamp
            let canonicalSources = sources.map(canonicalEntryURL)
            for (index, source) in canonicalSources.enumerated() {
                guard let sourceStamp = try stamp(at: source), let sourceKind = sourceStamp.kind else {
                    throw TransferFailure.invalid("\(source.lastPathComponent) is missing or is not a supported file type.")
                }
                if source.path == "/" {
                    throw TransferFailure.invalid("The filesystem root cannot be transferred.")
                }
                if sourceKind == .directory {
                    let identicalAncestor = try hasAncestor(targetFolder, identity: sourceStamp)
                    if isWithin(targetFolder, source) || identicalAncestor {
                        throw TransferFailure.invalid("A folder cannot be copied or moved into itself or one of its descendants.")
                    }
                }
                let proposed = targetFolder.appendingPathComponent(source.lastPathComponent)
                if kind == .move, let existing = try stamp(at: proposed), sourceStamp.isSameObject(as: existing) {
                    throw TransferFailure.invalid("\(source.lastPathComponent) is already in that location.")
                }
                for other in canonicalSources.prefix(index) {
                    if isWithin(source, other) || isWithin(other, source) {
                        throw TransferFailure.invalid("Choose each item only once; a folder and its contents cannot both be selected.")
                    }
                }
                sourceDirectoryFlags.append(sourceKind == .directory)
            }
            emit(force: true)
            let entries = try canonicalSources.map(plan)
            totalBytes = entries.reduce(0) { $0 + $1.bytes }
            totalFiles = entries.reduce(0) { $0 + $1.fileCount }
            phase = .transferring
            emit(force: true)
            for entry in entries {
                try checkCancellation()
                try transfer(entry, to: targetFolder)
            }
            try checkCancellation()
            phase = .completed
            currentFile = ""
            var notes = warnings
            if skipped > 0 { notes.insert("Skipped \(skipped) \(skipped == 1 ? "item" : "items").", at: 0) }
            emit(force: true, message: notes.isEmpty ? nil : notes.joined(separator: " "))
        } catch {
            completedBytes = committedBytes
            completedFiles = committedFiles
            phase = isCancelled || (error as? TransferFailure).map(isCancellationError) == true ? .cancelled : .failed
            emit(force: true, message: ([error.localizedDescription] + warnings).joined(separator: " "))
        }
    }

    private func isCancellationError(_ error: TransferFailure) -> Bool {
        if case .cancelled = error { return true }
        return false
    }

    private func canonicalEntryURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.path == "/" { return standardized }
        return standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent)
    }

    private func isWithin(_ candidate: URL, _ parent: URL) -> Bool {
        candidate.path == parent.path || candidate.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }

    private func hasAncestor(_ folder: URL, identity: FileStamp) throws -> Bool {
        var current = folder
        while true {
            if let info = try stamp(at: current), info.isSameObject(as: identity) { return true }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
    }

    private func validateDestination(_ folder: URL) throws {
        guard let expected = destinationIdentity, let current = try stamp(at: folder),
              current.kind == .directory, current.isSameObject(as: expected) else {
            throw TransferFailure.invalid("The destination folder changed. Transfer stopped to protect your files.")
        }
    }

    private func descriptorURL(_ descriptor: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        return result == 0 ? URL(fileURLWithPath: String(cString: buffer)) : nil
    }

    private func stamp(at url: URL) throws -> FileStamp? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return FileStamp(info) }
        let code = errno
        if code == ENOENT { return nil }
        throw TransferFailure.system("Cannot inspect \(url.lastPathComponent)", code)
    }

    private func plan(_ source: URL) throws -> PlannedEntry {
        try checkCancellation()
        guard let info = try stamp(at: source), let entryKind = info.kind else {
            throw TransferFailure.invalid("\(source.lastPathComponent) is missing or is not a supported file type.")
        }
        var children: [PlannedEntry] = []
        if entryKind == .directory {
            let urls = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            children = try urls.map(plan)
            guard try stamp(at: source) == info else { throw TransferFailure.changed(source.path) }
        }
        let bytes = entryKind == .file ? max(0, info.size) : children.reduce(0) { $0 + $1.bytes }
        let files = entryKind == .directory ? children.reduce(0) { $0 + $1.fileCount } : 1
        return PlannedEntry(source: source, stamp: info, kind: entryKind, children: children, bytes: bytes, fileCount: files)
    }

    private func validate(_ entry: PlannedEntry, recursively: Bool = false) throws {
        guard try stamp(at: entry.source) == entry.stamp else { throw TransferFailure.changed(entry.source.path) }
        if recursively && entry.kind == .directory {
            let names = try manager.contentsOfDirectory(atPath: entry.source.path).sorted()
            guard names == entry.children.map({ $0.source.lastPathComponent }).sorted() else {
                throw TransferFailure.changed(entry.source.path)
            }
            for child in entry.children { try validate(child, recursively: true) }
        }
    }

    private func transfer(_ entry: PlannedEntry, to folder: URL) throws {
        try validateDestination(folder)
        currentFile = entry.source.lastPathComponent
        let original = folder.appendingPathComponent(entry.source.lastPathComponent)
        guard var decision = try chooseDestination(for: entry, original: original) else {
            skip(entry)
            return
        }
        try validateDestination(folder)
        let stagingFolder = folder.appendingPathComponent(".filemanager-transfer-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stagingFolder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let stagingDescriptor = open(stagingFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingDescriptor >= 0 else {
            let code = errno
            try? manager.removeItem(at: stagingFolder)
            throw TransferFailure.system("Cannot prepare the destination", code)
        }
        var stagingInfo = stat()
        guard fstat(stagingDescriptor, &stagingInfo) == 0 else {
            let code = errno; close(stagingDescriptor)
            try? manager.removeItem(at: stagingFolder)
            throw TransferFailure.system("Cannot inspect the transfer staging folder", code)
        }
        let stagingIdentity = FileStamp(stagingInfo)
        var preserveStaging = false
        defer {
            if !preserveStaging {
                let cleanupURL = descriptorURL(stagingDescriptor) ?? stagingFolder
                do {
                    guard let current = try stamp(at: cleanupURL), current.isSameObject(as: stagingIdentity), current.kind == .directory else {
                        throw TransferFailure.changed(cleanupURL.path)
                    }
                    try manager.removeItem(at: cleanupURL)
                } catch { warnings.append("Temporary files could not be removed at \(cleanupURL.path).") }
            }
            close(stagingDescriptor)
        }
        try validateDestination(folder)
        let staged = stagingFolder.appendingPathComponent("item")
        try copy(entry, to: staged)
        try checkCancellation()
        try validate(entry, recursively: true)
        while true {
            try checkCancellation()
            try validateDestination(folder)
            // A second conflict can wait after staging completed. Revalidate again
            // so a later source edit never publishes a stale replacement.
            try validate(entry, recursively: true)
            if decision.keepBoth {
                let fresh = try uniqueURL(for: original, isDirectory: entry.kind == .directory)
                decision = DestinationDecision(url: fresh, replaceStamp: nil, keepBoth: true)
            }
            if let expected = decision.replaceStamp {
                let actual = try stamp(at: decision.url)
                if actual != expected {
                    guard let updated = try chooseDestination(for: entry, original: original, forcePrompt: true) else {
                        completedBytes = committedBytes
                        completedFiles = committedFiles
                        skip(entry)
                        return
                    }
                    decision = updated
                    continue
                }
                // RENAME_SWAP leaves the original destination in staging atomically.
                // Unsupported filesystems fail safely; there is no delete-then-rename fallback.
                if renameatx_np(stagingDescriptor, "item", destinationDescriptor, decision.url.lastPathComponent, UInt32(RENAME_SWAP)) == 0 {
                    // A destination can change between inspection and the swap. Never
                    // discard a displaced object that the user did not approve replacing.
                    preserveStaging = true
                    committedBytes = completedBytes
                    committedFiles = completedFiles
                    let displacedURL = (descriptorURL(stagingDescriptor) ?? stagingFolder).appendingPathComponent("item")
                    guard let displaced = try? stamp(at: displacedURL), expected.matchesAfterRename(displaced) else {
                        committedDestinations.append((descriptorURL(destinationDescriptor) ?? folder).appendingPathComponent(decision.url.lastPathComponent))
                        throw TransferFailure.invalid("The destination changed during replacement. The displaced item was preserved at \(displacedURL.path); the source was kept.")
                    }
                    preserveStaging = false
                    break
                }
                let code = errno
                if code == ENOENT { continue }
                throw TransferFailure.system("Cannot replace \(decision.url.lastPathComponent)", code)
            } else {
                if renameatx_np(stagingDescriptor, "item", destinationDescriptor, decision.url.lastPathComponent, UInt32(RENAME_EXCL)) == 0 { break }
                let code = errno
                if code == EEXIST {
                    if decision.keepBoth { continue }
                    guard let updated = try chooseDestination(for: entry, original: original) else {
                        completedBytes = committedBytes
                        completedFiles = committedFiles
                        skip(entry)
                        return
                    }
                    decision = updated
                    continue
                }
                throw TransferFailure.system("Cannot finish copying \(decision.url.lastPathComponent)", code)
            }
        }
        committedBytes = completedBytes
        committedFiles = completedFiles
        committedDestinations.append((descriptorURL(destinationDescriptor) ?? folder).appendingPathComponent(decision.url.lastPathComponent))
        if kind == .move {
            try checkCancellation()
            try validateDestination(folder)
            try validate(entry, recursively: true)
            do { try removeMovedSource(entry) }
            catch {
                throw TransferFailure.invalid("Copied \(entry.source.lastPathComponent) to \(decision.url.path), but could not finish removing its source: \(error.localizedDescription)")
            }
        }
        emit(force: true)
    }

    private func chooseDestination(for entry: PlannedEntry, original: URL, forcePrompt: Bool = false) throws -> DestinationDecision? {
        try checkCancellation()
        guard let existing = try stamp(at: original) else {
            return DestinationDecision(url: original, replaceStamp: nil, keepBoth: false)
        }
        if entry.stamp.isSameObject(as: existing) {
            if kind == .move { throw TransferFailure.invalid("\(entry.source.lastPathComponent) is already in that location.") }
            return DestinationDecision(url: try uniqueURL(for: original, isDirectory: entry.kind == .directory), replaceStamp: nil, keepBoth: true)
        }
        let compatible = entry.kind == .file && existing.kind == .file
        let suggested = try uniqueURL(for: original, isDirectory: entry.kind == .directory)
        let conflict = FileConflict(jobID: id, source: entry.source, destination: original,
                                    isDirectory: entry.kind == .directory || existing.kind == .directory,
                                    canReplace: compatible, suggestedName: suggested.lastPathComponent)
        let resolution: ConflictResolution
        if compatible, !forcePrompt, let rememberedFileChoice {
            resolution = ConflictResolution(choice: rememberedFileChoice)
        } else {
            resolution = try awaitResolution(conflict)
        }
        if compatible && resolution.applyToRemaining && resolution.choice != .cancel {
            rememberedFileChoice = resolution.choice
        }
        switch resolution.choice {
        case .cancel: throw TransferFailure.cancelled
        case .skip: return nil
        case .keepBoth: return DestinationDecision(url: suggested, replaceStamp: nil, keepBoth: true)
        case .replace:
            guard compatible else {
                throw TransferFailure.invalid("Folders and symbolic links cannot be replaced. Choose Keep Both or Skip.")
            }
            return DestinationDecision(url: original, replaceStamp: existing, keepBoth: false)
        }
    }

    private func awaitResolution(_ conflict: FileConflict) throws -> ConflictResolution {
        let token = UUID()
        condition.lock()
        if cancelled { condition.unlock(); throw TransferFailure.cancelled }
        conflictToken = token
        conflictResolution = nil
        condition.unlock()
        phase = .waiting
        emit(force: true, message: "Waiting for your choice.")
        let waitStart = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [self] in
            guard !isCancelled else { return }
            onConflict(conflict) { [weak self] resolution in
                guard let self else { return }
                condition.lock()
                if conflictToken == token && conflictResolution == nil && !cancelled {
                    conflictResolution = resolution
                    condition.broadcast()
                }
                condition.unlock()
            }
        }
        condition.lock()
        while conflictResolution == nil && !cancelled { condition.wait() }
        let answer = conflictResolution
        let wasCancelled = cancelled
        conflictToken = nil
        conflictResolution = nil
        condition.unlock()
        waitingTime += ProcessInfo.processInfo.systemUptime - waitStart
        if wasCancelled { throw TransferFailure.cancelled }
        guard let answer else { throw TransferFailure.cancelled }
        if answer.choice == .cancel { throw TransferFailure.cancelled }
        phase = .transferring
        emit(force: true)
        return answer
    }

    private func uniqueURL(for original: URL, isDirectory: Bool) throws -> URL {
        let parent = original.deletingLastPathComponent()
        let ext = isDirectory ? "" : original.pathExtension
        let stem = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        let reportedLimit = pathconf(parent.path, _PC_NAME_MAX)
        let nameLimit = reportedLimit > 0 ? Int(reportedLimit) : 255
        for number in 2...100_000 {
            try checkCancellation()
            let suffix = " (\(number))"
            var extensionText = ext.isEmpty ? "" : ".\(ext)"
            var prefix = stem
            if extensionText.utf8.count + suffix.utf8.count >= nameLimit {
                prefix = original.lastPathComponent
                extensionText = ""
            }
            let available = nameLimit - suffix.utf8.count - extensionText.utf8.count
            while prefix.utf8.count > available { prefix.removeLast() }
            let name = prefix + suffix + extensionText
            let candidate = parent.appendingPathComponent(name)
            if try stamp(at: candidate) == nil { return candidate }
        }
        throw TransferFailure.invalid("Cannot find an available name for \(original.lastPathComponent).")
    }

    private func skip(_ entry: PlannedEntry) {
        totalBytes -= entry.bytes
        totalFiles -= entry.fileCount
        skipped += 1
        emit(force: true)
    }

    private func copy(_ entry: PlannedEntry, to target: URL) throws {
        try checkCancellation()
        try validate(entry)
        currentFile = entry.source.lastPathComponent
        emit(force: true)
        switch entry.kind {
        case .directory:
            try manager.createDirectory(at: target, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
            for child in entry.children {
                try copy(child, to: target.appendingPathComponent(child.source.lastPathComponent))
            }
            try validate(entry, recursively: true)
            if copyfile(entry.source.path, target.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 {
                throw TransferFailure.system("Cannot preserve folder metadata for \(entry.source.lastPathComponent)", errno)
            }
        case .symbolicLink:
            if copyfile(entry.source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)) != 0 {
                throw TransferFailure.system("Cannot copy symbolic link \(entry.source.lastPathComponent)", errno)
            }
            try validate(entry)
            completedFiles += 1
        case .file:
            try copyRegularFile(entry, to: target)
            completedFiles += 1
        }
        try checkCancellation()
        emit(force: true)
    }

    private func copyRegularFile(_ entry: PlannedEntry, to target: URL) throws {
        let input = open(entry.source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw TransferFailure.system("Cannot read \(entry.source.lastPathComponent)", errno) }
        defer { close(input) }
        var inputInfo = stat()
        guard fstat(input, &inputInfo) == 0, FileStamp(inputInfo) == entry.stamp else {
            throw TransferFailure.changed(entry.source.path)
        }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw TransferFailure.system("Cannot create \(target.lastPathComponent)", errno) }
        defer { close(output) }
        guard let state = copyfile_state_alloc() else { throw TransferFailure.system("Cannot prepare copying", ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(job: self, baseBytes: completedBytes, fileBytes: entry.bytes)
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        let callbackPointer = unsafeBitCast(transferCopyCallback, to: UnsafeRawPointer.self)
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPointer) == 0 else {
            throw TransferFailure.system("Cannot prepare copy progress", errno)
        }
        let result = withExtendedLifetime(context) {
            fcopyfile(input, output, state, copyfile_flags_t(COPYFILE_ALL))
        }
        let resultCode = errno
        try checkCancellation()
        if result != 0 { throw TransferFailure.system("Cannot copy \(entry.source.lastPathComponent)", resultCode) }
        guard fstat(input, &inputInfo) == 0, FileStamp(inputInfo) == entry.stamp else {
            throw TransferFailure.changed(entry.source.path)
        }
        try validate(entry)
        // Flush before publishing the staged file or removing a moved source.
        if fsync(output) != 0 { throw TransferFailure.system("Cannot finish writing \(entry.source.lastPathComponent)", errno) }
        completedBytes = context.baseBytes + entry.bytes
    }

    private func removeMovedSource(_ entry: PlannedEntry) throws {
        try checkCancellation()
        if entry.kind == .directory {
            // Never recursively remove an original directory: rmdir refuses to remove
            // newly created, unplanned children, preserving concurrent additions.
            for child in entry.children { try removeMovedSource(child) }
            try removeParkedSource(entry, directory: true)
        } else {
            try validate(entry)
            try removeParkedSource(entry, directory: false)
        }
    }

    private func removeParkedSource(_ entry: PlannedEntry, directory: Bool) throws {
        try checkCancellation()
        let parked = entry.source.deletingLastPathComponent()
            .appendingPathComponent(".filemanager-moving-\(UUID().uuidString)")
        // Move the actual object out of its public name before deciding to delete it.
        // This closes the validate(path)/unlink(path) race with concurrent replacement.
        if renamex_np(entry.source.path, parked.path, UInt32(RENAME_EXCL)) != 0 {
            throw TransferFailure.system("Cannot finish moving \(entry.source.lastPathComponent)", errno)
        }
        do {
            guard let actual = try stamp(at: parked) else { throw TransferFailure.changed(entry.source.path) }
            let matches = directory
                ? actual.isSameObject(as: entry.stamp) && actual.kind == .directory
                : entry.stamp.matchesAfterRename(actual)
            guard matches else { throw TransferFailure.changed(entry.source.path) }
            // Do not interrupt the tiny parking/removal transaction. On cancellation,
            // the successfully committed destination remains available to the user.
            let result = directory ? rmdir(parked.path) : unlink(parked.path)
            if result != 0 { throw TransferFailure.system("Cannot remove source \(entry.source.lastPathComponent)", errno) }
        } catch {
            // Never overwrite a new item another process created at the original name.
            if renamex_np(parked.path, entry.source.path, UInt32(RENAME_EXCL)) != 0 {
                throw TransferFailure.invalid("The source could not be restored to its original name. It was preserved at \(parked.path). \(error.localizedDescription)")
            }
            throw error
        }
    }

    func recordCopyBytes(_ value: Int64) {
        completedBytes = value
        emit()
    }

    private func emit(force: Bool = false, message: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEmission >= 0.05 else { return }
        lastEmission = now
        let elapsed = max(now - startedAt - waitingTime, 0.001)
        let speed = phase == .transferring ? Double(completedBytes) / elapsed : 0
        let remaining = speed > 0 ? Double(max(0, totalBytes - completedBytes)) / speed : nil
        let progress = TransferProgress(id: id, kind: kind, sources: sources, destination: destination,
                                        totalBytes: totalBytes, completedBytes: completedBytes,
                                        totalFiles: totalFiles, completedFiles: completedFiles,
                                        currentFile: currentFile, phase: phase, message: message,
                                        bytesPerSecond: speed, remainingSeconds: remaining,
                                        sourceDirectoryFlags: sourceDirectoryFlags,
                                        committedDestinations: committedDestinations)
        DispatchQueue.main.async { [onProgress] in onProgress(progress) }
    }
}
