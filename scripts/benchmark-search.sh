#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/qa .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
swift build --package-path "$PROJECT_DIR" --scratch-path "$PROJECT_DIR/.build" \
  --cache-path "$PROJECT_DIR/.build/cache" --config-path "$PROJECT_DIR/.build/config" \
  --security-path "$PROJECT_DIR/.build/security" -c release
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
  -I .build/release/Modules scripts/benchmark-search.swift \
  .build/release/FileManagerCore.build/*.swift.o -lsqlite3 -framework CoreServices \
  -o .build/qa/benchmark-search
exec .build/qa/benchmark-search "$@"
