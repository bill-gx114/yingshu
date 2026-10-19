#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-local-ai-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -D LOCAL_AI_VOICE_TESTS -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/SpeechInput.swift \
  Sources/YingShu/SpeechCapture.swift Sources/YingShu/ModernSpeechCapture.swift \
  Sources/YingShu/LocalAIVoiceService.swift Sources/YingShu/DeepSeekTextService.swift Sources/YingShu/SpeechTextCleaner.swift Sources/YingShu/LocalAISpeechCapture.swift \
  Tests/LocalAIVoiceChecks.swift -o "$CHECK_DIR/check"
YINGSHU_LOCAL_AI_WORKER="$PWD/Resources/ai_voice_worker.py" \
YINGSHU_LOCAL_AI_FIXTURE="$PWD/Tests/fixtures/mandarin-diagnostic.aiff" \
"$CHECK_DIR/check"
