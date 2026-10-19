#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-music-stream-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
FFMPEG_PATH="$(command -v ffmpeg)"
"$FFMPEG_PATH" -loglevel error -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=60' \
  -ac 1 -c:a libmp3lame -b:a 320k -write_xing 0 "$CHECK_DIR/fixture.mp3"
"$FFMPEG_PATH" -loglevel error -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=600' \
  -ac 1 -c:a libmp3lame -q:a 0 -write_xing 1 "$CHECK_DIR/vbr.mp3"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
  Sources/YingShu/OnlineMusicLibrary.swift Sources/YingShu/OnlineMusicPreview.swift Sources/YingShu/OnlineMusicStream.swift \
  Tests/OnlineMusicStreamChecks.swift -o "$CHECK_DIR/check"
YINGSHU_PREVIEW_FIXTURE="$CHECK_DIR/fixture.mp3" YINGSHU_VBR_FIXTURE="$CHECK_DIR/vbr.mp3" "$CHECK_DIR/check"
