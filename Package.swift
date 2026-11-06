// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacFileManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacFileManager", targets: ["MacFileManager"]), .library(name: "FileManagerCore", targets: ["FileManagerCore"])],
    targets: [
        .target(name: "FileManagerCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("CoreServices")]),
        .executableTarget(name: "MacFileManager", dependencies: ["FileManagerCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Quartz")]),
        .testTarget(name: "FileManagerCoreTests", dependencies: ["FileManagerCore"])
    ],
    swiftLanguageModes: [.v5]
)
