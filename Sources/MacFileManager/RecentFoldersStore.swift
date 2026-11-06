import Foundation

/// A small, app-local history. Virtual locations and missing folders are never published.
final class RecentFoldersStore {
    private let storageURL: URL
    private let persists: Bool
    private var paths: [String]

    init(storageURL: URL = AppStorage.settingsURL.deletingLastPathComponent().appendingPathComponent("recent-folders.json"),
         persists: Bool = !CommandLine.arguments.contains("--temporary-session")) {
        self.storageURL = storageURL
        self.persists = persists
        paths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: storageURL))) ?? []
    }

    var folders: [URL] {
        let valid = normalized(paths)
        if valid.map(\.path) != paths { paths = valid.map(\.path); save() }
        return valid
    }

    func record(_ url: URL) {
        guard let folder = Self.validatedFolder(url) else { return }
        let updated = normalized([folder.path] + paths).map(\.path)
        guard paths != updated else { return }
        paths = updated
        save()
    }

    static func validatedFolder(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return canonical
    }

    private func normalized(_ candidates: [String]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in candidates {
            guard path.hasPrefix("/"), let folder = Self.validatedFolder(URL(fileURLWithPath: path)),
                  seen.insert(folder.path).inserted else { continue }
            result.append(folder)
            if result.count == 3 { break }
        }
        return result
    }

    private func save() {
        guard persists else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(paths).write(to: storageURL, options: .atomic)
        } catch { NSLog("Could not save recent folders: %@", error.localizedDescription) }
    }
}
