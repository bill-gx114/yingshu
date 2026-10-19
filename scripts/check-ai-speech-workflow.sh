#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-ai-workflow.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
SOURCES=()
for source in Sources/YingShu/*.swift; do
    case "$source" in */EditorView.swift|*/YingShuApp.swift) continue ;; esac
    SOURCES+=("$source")
done
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library "${SOURCES[@]}" Tests/AISpeechWorkflowChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
