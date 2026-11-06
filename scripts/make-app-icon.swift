import AppKit

@main struct MakeAppIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
              artwork.size.width > 0, artwork.size.height > 0 else {
            throw NSError(domain: "MakeAppIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected a readable icon source and output iconset path."])
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.imageInterpolation = .high
                // Keep the original artwork's aspect ratio and a small transparent Dock margin.
                let ratio = Double(pixels) * 0.9 / max(artwork.size.width, artwork.size.height)
                let size = NSSize(width: artwork.size.width * ratio, height: artwork.size.height * ratio)
                artwork.draw(in: NSRect(x: (Double(pixels) - size.width) / 2,
                                        y: (Double(pixels) - size.height) / 2,
                                        width: size.width, height: size.height))
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                let output = folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            }
        }
    }
}
