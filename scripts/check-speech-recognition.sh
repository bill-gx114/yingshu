#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-speech-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
mkdir -p "$CHECK_DIR/SpeechChecks.app/Contents/MacOS" "$CHECK_DIR/fixtures"
cat > "$CHECK_DIR/SpeechChecks.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.yingshu.speech-checks</string><key>CFBundleExecutable</key><string>check</string><key>NSSpeechRecognitionUsageDescription</key><string>仅检查自制普通话测试音频，不使用麦克风。</string></dict></plist>
PLIST
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/SpeechInput.swift \
  Sources/YingShu/SpeechCapture.swift Sources/YingShu/ModernSpeechCapture.swift Sources/YingShu/LocalAISpeechCapture.swift Sources/YingShu/LocalAIVoiceService.swift Sources/YingShu/DeepSeekTextService.swift Sources/YingShu/SpeechTextCleaner.swift \
  Tests/SpeechRecognitionChecks.swift -o "$CHECK_DIR/SpeechChecks.app/Contents/MacOS/check"
if [[ "${YINGSHU_SPEECH_QUALITY:-0}" == "1" ]]; then
  cat > "$CHECK_DIR/fixtures/ordinary.txt" <<'TEXT'
今天的海边很安静。我们沿着山路慢慢走。傍晚的风，让人舍不得回家。
TEXT
  cat > "$CHECK_DIR/fixtures/places.txt" <<'TEXT'
今天我们从熊本出发，经过阿苏，来到白川水源。下午去了上色见熊野座神社。这趟旅行，最喜欢的是山里的风。
TEXT
  say -v Tingting -r 170 -f "$CHECK_DIR/fixtures/ordinary.txt" -o "$CHECK_DIR/fixtures/ordinary.aiff"
  say -v Tingting -r 170 -f "$CHECK_DIR/fixtures/places.txt" -o "$CHECK_DIR/fixtures/places.aiff"
  afconvert -f WAVE -d LEF32@48000 "$CHECK_DIR/fixtures/ordinary.aiff" "$CHECK_DIR/fixtures/ordinary-48k.wav"
fi
YINGSHU_SPEECH_FIXTURES="$CHECK_DIR/fixtures" "$CHECK_DIR/SpeechChecks.app/Contents/MacOS/check"
if [[ -f "$CHECK_DIR/fixtures/quality-results.json" ]]; then
  mkdir -p Tests/output
  cp "$CHECK_DIR/fixtures/quality-results.json" Tests/output/speech-quality-results.json
fi
