#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-text-cleanup-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  Sources/YingShu/SpeechRecognitionOptions.swift Sources/YingShu/LocalAIVoiceService.swift Sources/YingShu/DeepSeekTextService.swift Sources/YingShu/SpeechTextCleaner.swift Tests/TextCleanupChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check" "$@"
