#!/usr/bin/env swift
// Creates disposable, genuine document/image/archive files for visual QA.
// Run from the project: swift -module-cache-path .build/module-cache scripts/make-design-fixtures.swift
// Add --large-transfers for sparse .bin payloads that exercise real copy/move progress.
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Darwin

let fileManager = FileManager.default
let project = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let fixtureRoot = project.appendingPathComponent(".build/design-demo", isDirectory: true)
let largeTransfers = CommandLine.arguments.contains("--large-transfers")
let validArguments = Set(["--large-transfers"])
if CommandLine.arguments.dropFirst().contains(where: { !validArguments.contains($0) }) {
    fputs("Usage: swift scripts/make-design-fixtures.swift [--large-transfers]\n", stderr)
    exit(2)
}

func rejectSymlink(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
        throw NSError(domain: "DesignFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing symbolic link: \(url.path)"])
    }
}

func fixtureURL(_ relative: String) throws -> URL {
    let url = fixtureRoot.appendingPathComponent(relative).standardizedFileURL
    guard url.path == fixtureRoot.path || url.path.hasPrefix(fixtureRoot.path + "/") else {
        throw NSError(domain: "DesignFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture path escaped the project."])
    }
    var current = project
    for component in url.pathComponents.dropFirst(project.pathComponents.count) {
        current.appendPathComponent(component)
        try rejectSymlink(current)
    }
    return url
}

@discardableResult
func ensureDirectory(_ relative: String) throws -> URL {
    let url = try fixtureURL(relative)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeIfMissing(_ relative: String, data: Data) throws {
    let url = try fixtureURL(relative)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: url.path) { try data.write(to: url, options: .withoutOverwriting) }
}
func writeIfMissing(_ relative: String, text: String) throws { try writeIfMissing(relative, data: Data(text.utf8)) }

func setModified(_ relative: String, _ value: String) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Qatar")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    guard let date = formatter.date(from: value) else { return }
    try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: fixtureURL(relative).path)
}

func drawText(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, color: CGColor, context: CGContext) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}

func noiseImage(width: Int, height: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: width * height * 3)
    var state: UInt64 = 0x4D414346494C4553
    for index in bytes.indices {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func makePDF(_ relative: String, title: String, subtitle: String, textureHeight: Int = 0, invoice: Bool = false) throws {
    let url = try fixtureURL(relative)
    if fileManager.fileExists(atPath: url.path) { return }
    guard let consumer = CGDataConsumer(url: url as CFURL) else { throw CocoaError(.fileWriteUnknown) }
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &media,
        [kCGPDFContextTitle: title, kCGPDFContextAuthor: "WinExplorer for Mac design fixtures"] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
    // A real, lightly textured cover image gives the source and destination PDFs
    // representative 2.4 MB and 1.8 MB sizes without mislabeled or padded files.
    if textureHeight > 0, let image = noiseImage(width: 1000, height: textureHeight) {
        context.saveGState(); context.setAlpha(0.035)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 612, height: 792))
        context.restoreGState()
    }
    let ink = CGColor(red: 0.09, green: 0.13, blue: 0.19, alpha: 1)
    let secondary = CGColor(red: 0.37, green: 0.42, blue: 0.49, alpha: 1)
    let blue = CGColor(red: 0, green: 0.43, blue: 0.97, alpha: 1)
    context.setFillColor(blue); context.fill(CGRect(x: 48, y: 690, width: 46, height: 5))
    drawText(title, x: 48, y: 724, size: 28, bold: true, color: ink, context: context)
    drawText(subtitle, x: 48, y: 664, size: 12, color: secondary, context: context)
    let sections: [(String, [String])] = invoice ? [
        ("SAMPLE INVOICE", ["Reference: DEMO-001", "This is demonstration data, not a real bill."]),
        ("Project services", ["Design review                 4 hours       320.00", "Prototype verification       3 hours       240.00", "Total                                      560.00"])
    ] : [
        ("Project overview", ["A familiar file manager for people moving from Windows to Mac.", "Clear navigation, comfortable shortcuts, and predictable file operations."]),
        ("What we are building", ["An expandable folder tree and editable path navigation.", "Independent tabs, details view, previews, and optional split view.", "Visible copy and move progress with understandable conflict choices."]),
        ("Milestones", ["1. Approve the main window and split-view layouts.", "2. Implement the native macOS browsing experience.", "3. Verify file operations and compare every screen with the designs."]),
        ("Next review", ["Review typography, spacing, file icons, and transfer behavior.", "Confirm that actual file metadata is displayed consistently."])
    ]
    var y: CGFloat = 610
    for (heading, lines) in sections {
        drawText(heading, x: 48, y: y, size: 15, bold: true, color: ink, context: context); y -= 29
        for line in lines { drawText(line, x: 48, y: y, size: 11, color: secondary, context: context); y -= 21 }
        y -= 25
    }
    context.setStrokeColor(CGColor(gray: 0.85, alpha: 1)); context.setLineWidth(0.7)
    context.move(to: CGPoint(x: 48, y: 65)); context.addLine(to: CGPoint(x: 564, y: 65)); context.strokePath()
    drawText("WINEXPLORER FOR MAC  /  DESIGN REVIEW", x: 48, y: 44, size: 9, color: secondary, context: context)
    drawText("01", x: 548, y: 44, size: 9, color: secondary, context: context)
    context.endPDFPage(); context.closePDF()
}

func makeImage(_ relative: String, jpeg: Bool = false) throws {
    let url = try fixtureURL(relative)
    if fileManager.fileExists(atPath: url.path) { return }
    let width = 1440, height = 960
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(CGColor(red: 0.92, green: 0.95, blue: 0.99, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 110, y: 120, width: 1220, height: 720))
    let ink = CGColor(red: 0.10, green: 0.15, blue: 0.23, alpha: 1)
    drawText(jpeg ? "A brighter workspace" : "Project progress", x: 170, y: 748, size: 42, bold: true, color: ink, context: context)
    drawText("A genuine image fixture for file browsing and Quick Look.", x: 170, y: 695, size: 22, color: CGColor(gray: 0.40, alpha: 1), context: context)
    for index in 0..<7 {
        let x = CGFloat(190 + index * 150)
        let barHeight = CGFloat(130 + (index * 67) % 330)
        context.setFillColor(CGColor(red: 0.08, green: 0.46 + Double(index) * 0.025, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: x, y: 220, width: 85, height: barHeight))
    }
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL,
        (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
    if !CGImageDestinationFinalize(destination) { throw CocoaError(.fileWriteUnknown) }
}

func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func makeArchive(_ relative: String, files: [String: String]) throws {
    let destination = try fixtureURL(relative)
    if fileManager.fileExists(atPath: destination.path) { return }
    let work = try ensureDirectory(".fixture-work-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: work) }
    for (path, contents) in files {
        let file = work.appendingPathComponent(path)
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = work
    process.arguments = ["-q", "-r", destination.path, "."]
    try process.run(); process.waitUntilExit()
    if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
}

func makeWorkbook() throws {
    let header = ["Category", "Description", "Quantity", "Unit cost", "Total"]
    let columns = ["A", "B", "C", "D", "E"]
    var rows = "<row r=\"1\">" + zip(columns, header).map { "<c r=\"\($0)1\" t=\"inlineStr\" s=\"1\"><is><t>\($1)</t></is></c>" }.joined() + "</row>"
    let categories = ["Design", "Engineering", "Research", "Quality assurance", "Content", "Operations"]
    for index in 2...601 {
        let quantity = (index % 8) + 1
        let cost = 45 + (index * 17) % 190
        rows += "<row r=\"\(index)\"><c r=\"A\(index)\" t=\"inlineStr\"><is><t>\(categories[index % categories.count])</t></is></c><c r=\"B\(index)\" t=\"inlineStr\"><is><t>Project work package \(index - 1)</t></is></c><c r=\"C\(index)\"><v>\(quantity)</v></c><c r=\"D\(index)\" s=\"2\"><v>\(cost)</v></c><c r=\"E\(index)\" s=\"2\"><f>C\(index)*D\(index)</f><v>\(quantity * cost)</v></c></row>"
    }
    try makeArchive("Projects/Budget.xlsx", files: [
        "[Content_Types].xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>",
        "_rels/.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
        "xl/workbook.xml": "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Project budget\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>",
        "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols><col min=\"1\" max=\"1\" width=\"24\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"36\" customWidth=\"1\"/><col min=\"3\" max=\"5\" width=\"14\" customWidth=\"1\"/></cols><sheetData>\(rows)</sheetData><autoFilter ref=\"A1:E601\"/></worksheet>",
        "xl/styles.xml": "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/><xf numFmtId=\"4\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    ])
}

func makePresentation() throws {
    let namespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    func shape(_ id: Int, _ name: String, _ text: String, y: Int, size: Int, color: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"600000\" y=\"\(y)\"/><a:ext cx=\"7900000\" cy=\"1600000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\" sz=\"\(size)\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill></a:rPr><a:t>\(xmlEscape(text))</a:t></a:r><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>"
    }
    let colors = "<a:dk1><a:srgbClr val=\"17212F\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"364152\"/></a:dk2><a:lt2><a:srgbClr val=\"F3F6FC\"/></a:lt2>" + ["0078FF", "17A673", "FFAE00", "EF6A57", "6D60CC", "5BA4CF"].enumerated().map { "<a:accent\($0.offset + 1)><a:srgbClr val=\"\($0.element)\"/></a:accent\($0.offset + 1)>" }.joined() + "<a:hlink><a:srgbClr val=\"0078FF\"/></a:hlink><a:folHlink><a:srgbClr val=\"6D60CC\"/></a:folHlink>"
    let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
    let theme = "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Project\"><a:themeElements><a:clrScheme name=\"Project\">\(colors)</a:clrScheme><a:fontScheme name=\"Project\"><a:majorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Project\"><a:fillStyleLst>\(String(repeating: solid, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: "<a:ln w=\"12700\">\(solid)<a:prstDash val=\"solid\"/></a:ln>", count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: solid, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    let mapping = "<p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/>"
    func rels(_ records: [(String, String, String)]) -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + records.map { "<Relationship Id=\"\($0.0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
    }
    let contentTypes = [("presentation.xml", "presentation.main"), ("slides/slide1.xml", "slide"), ("slideMasters/slideMaster1.xml", "slideMaster"), ("slideLayouts/slideLayout1.xml", "slideLayout")].map { "<Override PartName=\"/ppt/\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\($0.1)+xml\"/>" }.joined()
    try makeArchive("Projects/Roadmap.pptx", files: [
        "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(contentTypes)<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/></Types>",
        "_rels/.rels": rels([("rId1", "officeDocument", "ppt/presentation.xml")]),
        "ppt/presentation.xml": "<p:presentation \(namespaces)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"5143500\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>",
        "ppt/_rels/presentation.xml.rels": rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "slide", "slides/slide1.xml")]),
        "ppt/slides/slide1.xml": "<p:sld \(namespaces)><p:cSld><p:spTree>\(group)\(shape(2, "Title", "Project roadmap", y: 600000, size: 3600, color: "17212F"))\(shape(3, "Subtitle", "Design approval  •  Native browsing  •  Reliable file operations", y: 1900000, size: 2200, color: "364152"))\(shape(4, "Next", "Next: compare the running app with the approved screens.", y: 3400000, size: 2000, color: "0078FF"))</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>",
        "ppt/slides/_rels/slide1.xml.rels": rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]),
        "ppt/slideMasters/slideMaster1.xml": "<p:sldMaster \(namespaces)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld>\(mapping)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>",
        "ppt/slideMasters/_rels/slideMaster1.xml.rels": rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]),
        "ppt/slideLayouts/slideLayout1.xml": "<p:sldLayout \(namespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>",
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels": rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]),
        "ppt/theme/theme1.xml": theme
    ])
}

try rejectSymlink(project.appendingPathComponent(".build"))
try rejectSymlink(fixtureRoot)
for path in ["Projects", "Projects/Brand assets", "Projects/Invoices", "Projects/Website", "Downloads", "Downloads/Installers", "Work SSD/Project backup", "Work SSD/Installers"] {
    try ensureDirectory(path)
}
try makePDF("Projects/Project brief.pdf", title: "Project brief", subtitle: "WinExplorer for Mac  •  Current version  •  6 November 2026", textureHeight: 800)
try makePDF("Downloads/Project brief.pdf", title: "Project brief", subtitle: "WinExplorer for Mac  •  Earlier version  •  4 November 2026", textureHeight: 600)
try makePDF("Downloads/Invoice.pdf", title: "Invoice", subtitle: "Demonstration document", invoice: true)
try makeWorkbook()
try makePresentation()
try makeImage("Projects/Screenshot.png")
try makeImage("Downloads/Photo.jpg", jpeg: true)
try makeImage("Projects/Brand assets/Brand overview.png")
try writeIfMissing("Projects/Tasks.csv", text: "Task,Owner,Status,Due date\nNavigation,Design,Approved,2026-11-06\nFile operations,Engineering,In progress,2026-11-09\nVisual review,QA,Ready,2026-11-10\n")
try writeIfMissing("Downloads/Notes.txt", text: "Design review notes\n\nCompare typography, spacing, icons, selections, and every file operation with the approved mockups.\nThese are disposable project fixtures.\n")
try writeIfMissing("Projects/Website/index.html", text: "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Project website</title><style>body{font:20px system-ui;margin:80px;color:#17212f}h1{color:#0078ff}</style><h1>A familiar place for your files.</h1><p>Native Mac browsing with Windows-friendly navigation.</p></html>")
try writeIfMissing("Projects/Invoices/README.txt", text: "Demonstration invoices belong here. No real financial information is included.\n")
try writeIfMissing("Downloads/Installers/README.txt", text: "This test directory contains no executable installers. Large transfer payloads use an honest .bin extension.\n")
try makeArchive("Downloads/Archive.zip", files: ["README.txt": "A genuine ZIP archive for file-manager QA.\n", "Project/plan.txt": "Browse, organize, and transfer files with clear feedback.\n"])
if largeTransfers {
    for relative in ["Projects/Brand assets/Transfer sample.bin", "Downloads/Installers/Move sample.bin"] {
        let url = try fixtureURL(relative)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data("Disposable binary transfer fixture.\n".utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 2 * 1024 * 1024 * 1024)
            try handle.close()
        }
    }
}
for relative in ["Projects/Brand assets", "Projects/Budget.xlsx", "Projects/Screenshot.png", "Downloads/Archive.zip", "Downloads/Photo.jpg"] { try setModified(relative, "2026-11-05 10:00") }
for relative in ["Projects/Invoices", "Projects/Roadmap.pptx"] { try setModified(relative, "2026-11-04 11:30") }
for relative in ["Projects/Website", "Projects/Tasks.csv", "Downloads/Invoice.pdf", "Downloads/Notes.txt"] { try setModified(relative, "2026-11-06 08:15") }
try setModified("Projects/Project brief.pdf", "2026-11-06 09:42")
try setModified("Downloads/Project brief.pdf", "2026-11-04 16:20")
try setModified("Downloads/Installers", "2026-11-03 12:00")
print("Genuine design fixtures ready at \(fixtureRoot.path)")
print("Projects: 8 top-level items. Downloads: 7 top-level items, including the duplicate PDF.")
print("Existing files were preserved. --large-transfers adds optional 2 GiB sparse .bin payloads.")
