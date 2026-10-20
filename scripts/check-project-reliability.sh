#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-project-reliability.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
SOURCES=()
for source in Sources/YingShu/*.swift; do
  case "$(basename "$source")" in
    YingShuApp.swift|EditorView.swift|CompanionEditorView.swift) ;;
    *) SOURCES+=("$source") ;;
  esac
done
swiftc -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  "${SOURCES[@]}" Tests/ProjectReliabilityChecks.swift -o "$CHECK_DIR/check"
mkdir "$CHECK_DIR/work"
cd "$CHECK_DIR/work"
"$CHECK_DIR/check" "$CHECK_DIR/work"
