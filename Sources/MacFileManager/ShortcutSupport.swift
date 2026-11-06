import AppKit

/// Shortcuts keep their own filesystem identity. Resolve them only for opening or drawing
/// their target icon; file operations must continue using the shortcut document or alias URL.
enum ShortcutSupport {
    struct ResolutionError: LocalizedError {
        let shortcut: URL
        let reason: String
        var errorDescription: String? {
            let name = AppShortcutDocument.isShortcut(shortcut) ? shortcut.deletingPathExtension().lastPathComponent : shortcut.lastPathComponent
            return "The shortcut “\(name)” could not be opened. Its target may have moved, been deleted, or be on an unavailable drive.\n\n\(reason)"
        }
    }

    private static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 384
        return cache
    }()

    static func isAlias(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return values?.isAliasFile == true && values?.isSymbolicLink != true
    }

    static func isShortcut(_ url: URL) -> Bool { AppShortcutDocument.isShortcut(url) || isAlias(url) }

    /// Never mounts a volume or lets Foundation present a resolution dialog.
    static func resolve(_ url: URL) throws -> URL {
        guard isShortcut(url) else { return url.standardizedFileURL }
        do {
            var target = url.standardizedFileURL
            var visited = Set<URL>()
            for _ in 0..<16 {
                guard visited.insert(target).inserted else { throw CocoaError(.fileReadCorruptFile) }
                target = try (AppShortcutDocument.isShortcut(target)
                    ? AppShortcutDocument.resolve(target)
                    : URL(resolvingAliasFileAt: target, options: [.withoutUI, .withoutMounting])).standardizedFileURL
                guard target.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                if !isShortcut(target) {
                    guard try target.checkResourceIsReachable() else { throw CocoaError(.fileNoSuchFile) }
                    return target
                }
            }
            throw CocoaError(.fileReadCorruptFile)
        } catch {
            throw ResolutionError(shortcut: url, reason: error.localizedDescription)
        }
    }

    static func isBrowsableFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    static func folderIcon(size: NSSize = NSSize(width: 28, height: 24)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(scaleByX: rect.width / 28, byY: rect.height / 24)
            (transform as NSAffineTransform).concat()
            let tab = NSBezierPath(roundedRect: NSRect(x: 2, y: 12, width: 12, height: 10), xRadius: 2, yRadius: 2)
            NSColor(calibratedRed: 0.31, green: 0.67, blue: 1, alpha: 1).setFill(); tab.fill()
            let body = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 24, height: 16), xRadius: 2, yRadius: 2)
            NSColor(calibratedRed: 0.45, green: 0.74, blue: 1, alpha: 1).setFill(); body.fill()
            NSColor(calibratedRed: 0.06, green: 0.52, blue: 0.96, alpha: 1).setStroke()
            body.lineWidth = 1; body.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Uses a clear lower-left arrow badge rather than relying on the system's subtle alias mark.
    static func icon(for url: URL, size: CGFloat = 32) -> NSImage {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        let shortcut = AppShortcutDocument.isShortcut(url) || (values?.isAliasFile == true && values?.isSymbolicLink != true)
        guard shortcut else {
            let image = isBrowsableFolder(url) ? folderIcon() : NSWorkspace.shared.icon(forFile: url.path)
            let result = image.copy() as! NSImage
            result.size = NSSize(width: size, height: size)
            return result
        }
        let cacheKey = "\(url.path)|\(values?.fileResourceIdentifier.map { String(describing: $0) } ?? "")|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values?.fileSize ?? 0)|\(size)" as NSString
        if let cached = icons.object(forKey: cacheKey) { return cached }
        let target = try? resolve(url)
        let base: NSImage
        if let target {
            base = isBrowsableFolder(target) ? folderIcon() : NSWorkspace.shared.icon(forFile: target.path)
        } else {
            base = NSWorkspace.shared.icon(for: .data)
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            let side = min(rect.width, max(9, min(34, rect.width * 0.42)))
            let badge = NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)
            let outline = NSBezierPath(roundedRect: badge, xRadius: max(1, side * 0.10), yRadius: max(1, side * 0.10))
            NSColor.white.setFill(); outline.fill()
            NSColor(calibratedWhite: 0.42, alpha: 1).setStroke(); outline.lineWidth = max(0.7, side * 0.035); outline.stroke()
            let points: [(CGFloat, CGFloat)] = [(0.16, 0.28), (0.29, 0.15), (0.65, 0.51), (0.65, 0.29),
                (0.83, 0.29), (0.83, 0.80), (0.32, 0.80), (0.32, 0.62), (0.54, 0.62)]
            let arrow = NSBezierPath()
            for (index, point) in points.enumerated() {
                let position = NSPoint(x: badge.minX + point.0 * badge.width, y: badge.minY + point.1 * badge.height)
                if index == 0 { arrow.move(to: position) } else { arrow.line(to: position) }
            }
            arrow.close()
            NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.67, alpha: 1).setFill(); arrow.fill()
            return true
        }
        // Retry unavailable targets after the drive returns rather than caching a fallback forever.
        if target != nil { icons.setObject(image, forKey: cacheKey) }
        return image
    }
}
