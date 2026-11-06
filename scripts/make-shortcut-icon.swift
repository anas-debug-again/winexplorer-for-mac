import AppKit

@main struct MakeShortcutIcon {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Render the same shortcut artwork used in the app for Finder's document icon.
        let fixture = folder.appendingPathComponent("icon.fmlink")
        try AppShortcutDocument.data(for: folder).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                ShortcutSupport.icon(for: fixture, size: 64).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                let output = folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            }
        }
    }
}
