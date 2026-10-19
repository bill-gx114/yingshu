#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-preview-state.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
sources=()
for source in Sources/YingShu/*.swift; do
    if [[ "$source" != *YingShuApp.swift && "$source" != *EditorView.swift ]]; then sources+=("$source"); fi
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library "${sources[@]}" Tests/MusicPreviewStateChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
