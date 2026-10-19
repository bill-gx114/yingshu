#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f Tests/fixtures/live-photo/iphone-style-still.heic || ! -f Tests/fixtures/live-photo/iphone-style-motion.mov ]]; then
  ./scripts/check-live-photo.sh
fi
CHECK_DIR="$(mktemp -d /tmp/yingshu-caption-images.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift Sources/YingShu/CompanionStickerRenderer.swift Sources/YingShu/MediaEngine.swift Sources/YingShu/CaptionImageExporter.swift \
  Tests/CaptionImageExportChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
