#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Compile the real application exporter; no project, preferences, or user media is read.
SHOWCASE_RUN="$(mktemp -d /tmp/yingshu-showcase-outputs.XXXXXX)"
trap 'rm -rf "$SHOWCASE_RUN"' EXIT
swiftc -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift \
  Sources/YingShu/CompanionStickerRenderer.swift Sources/YingShu/MediaEngine.swift \
  Sources/YingShu/CaptionImageExporter.swift scripts/make-showcase-outputs.swift \
  -o "$SHOWCASE_RUN/make-showcase-outputs"
"$SHOWCASE_RUN/make-showcase-outputs" "$SHOWCASE_RUN/images"

# Copy only the seven public PNGs; the exporter's index and sidecars stay temporary.
mkdir -p docs/showcase/images
for image in caption-subtitle caption-sticker caption-note caption-companion \
             export-landscape export-portrait export-square; do
  cp "$SHOWCASE_RUN/images/$image.png" "docs/showcase/images/$image.png"
done
