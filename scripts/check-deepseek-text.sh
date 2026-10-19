#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/yingshu-deepseek-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -D DEEPSEEK_TEXT_TESTS -parse-as-library \
  Sources/YingShu/DeepSeekTextService.swift Tests/DeepSeekTextChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
