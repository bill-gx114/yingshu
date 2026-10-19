#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-streaming-preview-state.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
FFMPEG_PATH="$(command -v ffmpeg)"
"$FFMPEG_PATH" -loglevel error -f lavfi -i 'anullsrc=r=44100:cl=mono' -t 70 \
  -ac 1 -c:a libmp3lame -b:a 320k -write_xing 0 "$CHECK_DIR/silent.mp3"
sources=()
for source in Sources/YingShu/*.swift; do
    if [[ "$source" != *YingShuApp.swift && "$source" != *EditorView.swift ]]; then sources+=("$source"); fi
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  "${sources[@]}" Tests/StreamingPreviewStateChecks.swift -o "$CHECK_DIR/check"
YINGSHU_STREAM_STATE_FIXTURE="$CHECK_DIR/silent.mp3" "$CHECK_DIR/check"
