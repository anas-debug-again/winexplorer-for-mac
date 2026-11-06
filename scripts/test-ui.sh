#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/qa .build/module-cache
if [ "$#" -eq 0 ]; then
  set -- MultiWindow AppDelegate DockPlugin RecentFolders BrowserShortcut PasteShortcut MarqueeSelection ExplorerSettings ExplorerOptions SendTo ThisMac BrowserExplorer BrowserSearch ExplorerIntegration \
    BrowserPane BrowserProperties BrowserHover PropertiesWindow KeyboardShortcut \
    ActionHover ScrollHover ViewportHover SearchFieldAlignment AppStorage
fi
needs_core=false
for suite in "$@"; do
  case "$suite" in MultiWindow|AppDelegate|PasteShortcut|ExplorerIntegration|PropertiesWindow|BrowserShortcut|MarqueeSelection|BrowserExplorer|BrowserPane|BrowserProperties|BrowserHover|BrowserSearch) needs_core=true ;; esac
done
if "$needs_core"; then
  swift build --scratch-path "$PROJECT_DIR/.build"
fi
for suite in "$@"; do
  sources=(Sources/MacFileManager/AppSupport.swift)
  flags=(-swift-version 5 -module-cache-path .build/module-cache)
  case "$suite" in
    ExplorerSettings|KeyboardShortcut|ActionHover|ScrollHover|ViewportHover) ;;
    SearchFieldAlignment) sources=(Sources/MacFileManager/VerticallyCenteredSearchField.swift) ;;
    AppStorage) sources+=(Sources/FileManagerDockPlugin/FileManagerDockPlugin.swift) ;;
    ExplorerOptions) sources+=(Sources/MacFileManager/ExplorerOptionsWindowController.swift) ;;
    RecentFolders) sources+=(Sources/MacFileManager/RecentFoldersStore.swift) ;;
    DockPlugin) sources=(Sources/FileManagerDockPlugin/FileManagerDockPlugin.swift) ;;
    BrowserShortcut) sources+=(Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/BrowserPaneViewController.swift Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/ShortcutSupport.swift Sources/MacFileManager/SendToService.swift Sources/MacFileManager/PreviewViewController.swift) ;;
    SendTo) sources=(Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/SendToService.swift) ;;
    ThisMac) sources+=(Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/SidebarViewController.swift) ;;
    MarqueeSelection|BrowserExplorer|BrowserPane|BrowserProperties|BrowserHover|BrowserSearch)
      sources+=(Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/BrowserPaneViewController.swift Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/ShortcutSupport.swift) ;;
    PropertiesWindow)
      sources+=(Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/PropertiesWindowController.swift .build/debug/FileManagerCore.build/*.swift.o)
      flags+=(-I .build/debug/Modules) ;;
    MultiWindow|AppDelegate|PasteShortcut|ExplorerIntegration)
      sources=()
      for source in Sources/MacFileManager/*.swift; do
        if [ "${source##*/}" != main.swift ]; then sources+=("$source"); fi
      done
      sources+=(.build/debug/FileManagerCore.build/*.swift.o)
      flags+=(-I .build/debug/Modules) ;;
    *) printf 'Unknown UI suite: %s\n' "$suite" >&2; exit 2 ;;
  esac
  case "$suite" in
    BrowserShortcut|MarqueeSelection|BrowserExplorer|BrowserPane|BrowserProperties|BrowserHover|BrowserSearch)
      sources+=(Sources/MacFileManager/BrowserSearchSupport.swift Sources/MacFileManager/VerticallyCenteredSearchField.swift .build/debug/FileManagerCore.build/*.swift.o)
      flags+=(-I .build/debug/Modules) ;;
  esac
  if "$needs_core"; then flags+=(-lsqlite3 -framework CoreServices); fi
  output=".build/qa/${suite}Regression"
  xcrun swiftc "${flags[@]}" "${sources[@]}" "Tests/UIRegression/${suite}Regression.swift" -o "$output"
  search_fixture="$(mktemp -d "$PROJECT_DIR/.build/qa/search-index-${suite}.XXXXXX")"
  if ! FILE_MANAGER_SEARCH_INDEX_PATH="$search_fixture/search.sqlite" "$output" > "$output.log" 2>&1; then
    cat "$output.log"
    rm -rf "$search_fixture"
    exit 1
  fi
  rm -rf "$search_fixture"
  tail -n 1 "$output.log"
done
