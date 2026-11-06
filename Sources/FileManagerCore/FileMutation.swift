import Foundation
import Darwin

/// Renames an item without replacing any existing directory entry, including dangling links.
/// RENAME_EXCL also permits a case-only rename on case-insensitive macOS volumes.
public enum FileMutation {
    public static func renameWithoutReplacing(from source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                              userInfo: [NSLocalizedDescriptionKey: "An item named “\(destination.lastPathComponent)” already exists. Nothing was replaced.", NSFilePathErrorKey: destination.path])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: source.path,
                                     NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }
}
