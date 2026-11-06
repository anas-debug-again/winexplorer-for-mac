#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_DIR="${FILE_MANAGER_APP_OUTPUT:-$PROJECT_DIR/build/WinExplorer for Mac.app}"
if [ ! -x "$APP_DIR/Contents/MacOS/MacFileManager" ]; then
  "$PROJECT_DIR/scripts/build.sh"
fi
open "$APP_DIR" --args "$@"
