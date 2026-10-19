#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-story-order-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift Sources/YingShu/StoryOrderEngine.swift \
  Tests/StoryOrderChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
