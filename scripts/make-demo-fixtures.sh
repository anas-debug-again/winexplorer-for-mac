#!/bin/bash
# Reproducible, disposable demonstration files. Existing files are preserved.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
build_dir="$project_root/.build"
demo_dir="$build_dir/demo"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--reset" ) ]]; then
    printf 'Usage: %s [--reset]\n' "$0" >&2
    exit 2
fi
if [[ -L "$build_dir" || -L "$demo_dir" ]]; then
    printf 'Refusing to create or reset demo data through a symbolic link.\n' >&2
    exit 1
fi
mkdir -p "$build_dir"
if [[ "$(cd "$build_dir" && pwd -P)/demo" != "$demo_dir" ]]; then
    printf 'Demo path must remain inside this project at .build/demo.\n' >&2
    exit 1
fi
if [[ "${1:-}" == "--reset" && -e "$demo_dir" ]]; then
    # This is the only removal operation, guarded above and available only by
    # explicit request. It never targets a user directory outside the project.
    rm -rf -- "$demo_dir"
fi

ensure_directory() {
    if [[ -L "$1" || ( -e "$1" && ! -d "$1" ) ]]; then
        printf 'Expected an ordinary directory, refusing path: %s\n' "$1" >&2
        exit 1
    fi
    mkdir -p "$1"
}

write_if_missing() {
    local destination="$1"
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        cat > "$destination"
    else
        # Consume the here-document without changing the existing fixture.
        cat > /dev/null
    fi
}

ensure_directory "$demo_dir"
ensure_directory "$demo_dir/Projects"
ensure_directory "$demo_dir/Downloads"
ensure_directory "$demo_dir/Projects/Brand assets"
ensure_directory "$demo_dir/Projects/Invoices"
ensure_directory "$demo_dir/Projects/Website"
ensure_directory "$demo_dir/Downloads/Installers"

write_if_missing "$demo_dir/Projects/report.txt" <<'EOF'
PROJECT REPORT — CURRENT VERSION

Website refresh: navigation approved, content review complete.
Next milestone: test the file manager's copy, move, and duplicate handling.
This is the newer source file. Keep Both should preserve both versions.
EOF
write_if_missing "$demo_dir/Downloads/report.txt" <<'EOF'
PROJECT REPORT — EARLIER VERSION

Website refresh: initial draft awaiting review.
This is the existing destination file used to demonstrate a conflict.
EOF
write_if_missing "$demo_dir/Projects/Roadmap.md" <<'EOF'
# Project roadmap

- Browse folders and open files.
- Compare two folders side by side.
- Copy and move files with visible progress.
- Resolve duplicate names explicitly.
EOF
write_if_missing "$demo_dir/Projects/Tasks.csv" <<'EOF'
Task,Owner,Status
Navigation,Design,Done
File operations,Engineering,In progress
Visual review,QA,Ready
EOF
write_if_missing "$demo_dir/Projects/Brand assets/README.txt" <<'EOF'
Demo asset folder.
preview-data.bin contains 64 MiB of zero bytes to exercise transfer progress.
It is binary test data, not a playable video or an application installer.
EOF
write_if_missing "$demo_dir/Projects/Website/index.html" <<'EOF'
<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Demo project</title>
<h1>Website refresh</h1><p>A small sample file for browser and preview checks.</p></html>
EOF
write_if_missing "$demo_dir/Projects/Invoices/invoice-001.txt" <<'EOF'
SAMPLE INVOICE — NOT A REAL BILL
Reference: DEMO-001
Description: File manager test fixture
EOF
write_if_missing "$demo_dir/Downloads/Notes.txt" <<'EOF'
These files are safe demonstration data inside the project.
They can be copied, renamed, or moved during verification.
EOF
write_if_missing "$demo_dir/Downloads/Installers/README.txt" <<'EOF'
This folder deliberately contains no executable installers.
It is a sample directory for testing folder transfers.
EOF

binary_path="$demo_dir/Projects/Brand assets/preview-data.bin"
if [[ ! -e "$binary_path" && ! -L "$binary_path" ]]; then
    dd if=/dev/zero of="$binary_path" bs=1048576 count=64 2>/dev/null
fi
printf 'Demo files ready:\n  %s\n  %s\n' "$demo_dir/Projects" "$demo_dir/Downloads"
printf 'Existing files were preserved. Use --reset only to recreate the demo from scratch.\n'
