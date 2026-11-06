import Foundation
import CoreServices
import Darwin

/// Notifications describe invalidated paths, not authoritative file operations.
struct FilenameSearchChange {
    let path: String
    let eventID: UInt64
    let requiresFullRescan: Bool
    let historyDone: Bool
    var flags: FSEventStreamEventFlags = 0
    var isDirectory: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 }
    var isStructural: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
    }
    var contentsChanged: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 }
    var mayHaveNewSubtree: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0 }
    var directoryMetadataChanged: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemFinderInfoMod) != 0 }
}

/// The callback context is retained by FSEvents separately from this owner so a queued
/// callback cannot outlive its context when a catalog or window is released.
final class FilenameSearchWatcher {
    private final class Callback {
        let handler: ([FilenameSearchChange]) -> Void
        init(_ handler: @escaping ([FilenameSearchChange]) -> Void) { self.handler = handler }
    }
    private var stream: FSEventStreamRef?
    private let callbackQueue: DispatchQueue
    private let lifecycleQueue = DispatchQueue(label: "FileManager.search.events.flush", qos: .utility)

    static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    static func eventStoreIdentifier(for root: URL) -> String? {
        var info = stat()
        guard stat(root.path, &info) == 0,
              let identifier = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, identifier) as String
    }

    init(root: URL, since: UInt64, queue: DispatchQueue,
         onEvents: @escaping ([FilenameSearchChange]) -> Void) throws {
        callbackQueue = queue
        let callback = Callback(onEvents)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<Callback>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: NSArray.self)
            let recoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            var changes: [FilenameSearchChange] = []
            changes.reserveCapacity(count)
            for i in 0..<count {
                let historyDone = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
                guard historyDone || (i < pathArray.count && pathArray[i] is String) else { continue }
                changes.append(FilenameSearchChange(path: historyDone ? "" : pathArray[i] as! String,
                    eventID: ids[i], requiresFullRescan: flags[i] & recoveryFlags != 0,
                    historyDone: historyDone, flags: flags[i]))
            }
            if !changes.isEmpty { callback.handler(changes) }
        }, &context, [root.path] as CFArray,
            since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since, 0.15, flags) else {
            throw NSError(domain: "FilenameSearchWatcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "macOS could not watch this folder for changes."])
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            close()
            throw NSError(domain: "FilenameSearchWatcher", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Live folder updates are unavailable for this location."])
        }
    }

    /// HistoryDone alone does not flush live changes still buffered by fseventsd.
    /// Never invoke FlushSync on the callback queue: it waits for those callbacks.
    /// The completion is ordered after their delivery on the catalog's state queue.
    func flush(completion: @escaping () -> Void) {
        let callbackQueue = callbackQueue
        guard let stream else { callbackQueue.async(execute: completion); return }
        lifecycleQueue.async {
            FSEventStreamFlushSync(stream)
            callbackQueue.async(execute: completion)
        }
    }

    /// Teardown follows outstanding flush work without blocking its callback queue.
    func close() {
        guard let stream else { return }
        self.stream = nil
        lifecycleQueue.async {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    deinit { close() }
}
