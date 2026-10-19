#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-layout-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
SOURCES=()
for source in Sources/YingShu/*.swift; do
  if [[ "$(basename "$source")" != "YingShuApp.swift" ]]; then SOURCES+=("$source"); fi
done
swiftc -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  "${SOURCES[@]}" Tests/RenderChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
