#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-companion-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift Sources/YingShu/CompanionStickerRenderer.swift \
  Sources/YingShu/MediaEngine.swift Sources/YingShu/CaptionImageExporter.swift \
  Tests/CompanionStickerChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
