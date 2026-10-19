#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO_CHECK_DIR="$(mktemp -d /tmp/yingshu-demo.XXXXXX)"
trap 'rm -rf "$DEMO_CHECK_DIR"' EXIT
mkdir -p dist
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift Sources/YingShu/CompanionStickerRenderer.swift Sources/YingShu/MediaEngine.swift Sources/YingShu/AutoEditEngine.swift scripts/make-demo.swift -o "$DEMO_CHECK_DIR/demo"
"$DEMO_CHECK_DIR/demo"
ffmpeg -v error -i dist/映述示例短片.mp4 -f null -
