#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" != 2 ]]; then printf '%s\n' 'Usage: scripts/check-import-workflow.sh generated-still generated-movie'; exit 2; fi
CHECK_DIR="$(mktemp -d /tmp/yingshu-import-workflow.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/Models.swift Sources/YingShu/SpeechCapture.swift Sources/YingShu/ModernSpeechCapture.swift Sources/YingShu/LocalAISpeechCapture.swift Sources/YingShu/LocalAIVoiceService.swift Sources/YingShu/DeepSeekTextService.swift Sources/YingShu/SpeechInput.swift \
  Sources/YingShu/CompanionStickerRenderer.swift Sources/YingShu/MediaEngine.swift Sources/YingShu/AutoEditEngine.swift Sources/YingShu/LivePhotoImporter.swift \
  Sources/YingShu/PhotoLibraryImporter.swift \
  Sources/YingShu/StoryOrderEngine.swift Sources/YingShu/DictationAlignment.swift Sources/YingShu/OnlineMusicLibrary.swift Sources/YingShu/MusicRecommendationEngine.swift Sources/YingShu/CaptionImageExporter.swift Sources/YingShu/OnlineMusicPreview.swift Sources/YingShu/OnlineMusicStream.swift Sources/YingShu/SpeechTextCleaner.swift Sources/YingShu/AppModel.swift \
  Tests/ImportWorkflowChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check" "$1" "$2"
