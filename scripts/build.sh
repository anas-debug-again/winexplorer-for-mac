#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_NAME="WinExplorer for Mac"
APP_DIR="${FILE_MANAGER_APP_OUTPUT:-$PROJECT_DIR/build/$APP_NAME.app}"
if [ -f "$APP_DIR/Contents/MacOS/MacFileManager" ] && /usr/sbin/lsof -t "$APP_DIR/Contents/MacOS/MacFileManager" >/dev/null 2>&1; then
  printf 'Close %s before rebuilding its app bundle.\n' "$APP_NAME" >&2
  exit 2
fi
mkdir -p .build/cache .build/config .build/security .build/module-cache build
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
BUILD_FLAGS=(-c "$BUILD_CONFIGURATION")
if [ "$BUILD_CONFIGURATION" = release ]; then
  # Omit release debug info and remap embedded source paths. The debugger uses real paths in debug builds.
  BUILD_FLAGS+=(-debug-info-format none -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=/FileManager")
fi
swift build --package-path "$PROJECT_DIR" --scratch-path "$PROJECT_DIR/.build" --cache-path "$PROJECT_DIR/.build/cache" --config-path "$PROJECT_DIR/.build/config" --security-path "$PROJECT_DIR/.build/security" "${BUILD_FLAGS[@]}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
DOCK_PLUGIN_DIR="$APP_DIR/Contents/PlugIns/FileManagerDock.docktileplugin"
mkdir -p "$DOCK_PLUGIN_DIR/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -file-prefix-map "$PROJECT_DIR=/FileManager" -emit-library -Xlinker -install_name -Xlinker '@rpath/FileManagerDockPlugin' -target "$(uname -m)-apple-macosx14.0" -module-name FileManagerDockPlugin -module-cache-path .build/module-cache Sources/FileManagerDockPlugin/FileManagerDockPlugin.swift -o "$DOCK_PLUGIN_DIR/Contents/MacOS/FileManagerDockPlugin"
cat > "$DOCK_PLUGIN_DIR/Contents/Info.plist" <<'DOCKPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FileManagerDockPlugin</string>
<key>CFBundleIdentifier</key><string>local.filemanager.dock</string>
<key>CFBundleName</key><string>FileManagerDock</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSPrincipalClass</key><string>FileManagerDockPlugin</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
DOCKPLIST
cp "$PROJECT_DIR/.build/$BUILD_CONFIGURATION/MacFileManager" "$APP_DIR/Contents/MacOS/MacFileManager"
if [ "$BUILD_CONFIGURATION" = release ]; then
  # Linker debug-map entries otherwise retain absolute object-file paths.
  strip -S "$APP_DIR/Contents/MacOS/MacFileManager"
  strip -S "$DOCK_PLUGIN_DIR/Contents/MacOS/FileManagerDockPlugin"
fi
codesign --force --sign - "$DOCK_PLUGIN_DIR"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path .build/module-cache scripts/make-app-icon.swift -o .build/make-app-icon
.build/make-app-icon design/assets/app-icon/app-icon.svg .build/FileManager.iconset
iconutil -c icns .build/FileManager.iconset -o "$APP_DIR/Contents/Resources/FileManager.icns"
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/ShortcutSupport.swift scripts/make-shortcut-icon.swift -o .build/make-shortcut-icon
.build/make-shortcut-icon .build/Shortcut.iconset
iconutil -c icns .build/Shortcut.iconset -o "$APP_DIR/Contents/Resources/Shortcut.icns"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacFileManager</string>
<key>CFBundleIdentifier</key><string>local.filemanager.app</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>FileManager.icns</string>
<key>CFBundleShortVersionString</key><string>0.7.3</string>
<key>CFBundleVersion</key><string>19</string>
<key>NSDockTilePlugIn</key><string>FileManagerDock.docktileplugin</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Folders and folder aliases</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.folder</string><string>com.apple.alias-file</string></array>
</dict><dict>
<key>CFBundleTypeName</key><string>$APP_NAME Shortcut</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Owner</string>
<key>CFBundleTypeIconFile</key><string>Shortcut.icns</string>
<key>LSItemContentTypes</key><array><string>local.filemanager.shortcut</string></array>
</dict></array>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.filemanager.shortcut</string>
<key>UTTypeDescription</key><string>$APP_NAME Shortcut</string>
<key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>fmlink</string></array></dict>
<key>UTTypeIconFile</key><string>Shortcut.icns</string>
</dict></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDocumentsFolderUsageDescription</key><string>Browse and organize the documents you choose.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Browse and organize your downloaded files.</string>
<key>NSDesktopFolderUsageDescription</key><string>Browse and organize files on your Desktop.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Browse and transfer files on your connected drives.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Browse mounted network folders you choose.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
