#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/cache .build/config .build/security .build/module-cache .build/test-fixtures
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
export FILE_MANAGER_TEST_ROOT="$PROJECT_DIR/.build/test-fixtures"
TEST_FLAGS=(
  --package-path "$PROJECT_DIR"
  --scratch-path "$PROJECT_DIR/.build"
  --cache-path "$PROJECT_DIR/.build/cache"
  --config-path "$PROJECT_DIR/.build/config"
  --security-path "$PROJECT_DIR/.build/security"
)
SDK_DEVELOPER_PATH="$(xcode-select -p)"
if [ -d "$SDK_DEVELOPER_PATH/Library/Developer/Frameworks/Testing.framework" ]; then
  TEST_FLAGS+=(
    -Xswiftc -F -Xswiftc "$SDK_DEVELOPER_PATH/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$SDK_DEVELOPER_PATH/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$SDK_DEVELOPER_PATH/Library/Developer/usr/lib"
  )
fi
swift test "${TEST_FLAGS[@]}"
