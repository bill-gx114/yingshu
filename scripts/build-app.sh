#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$(pwd)/dist/映述.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/YingShu "$APP/Contents/MacOS/YingShu"
for resource in Resources/*; do
    if [[ -f "$resource" ]]; then cp "$resource" "$APP/Contents/Resources/"; fi
done
cp docs/使用说明.md "$APP/Contents/Resources/使用说明.md"
cp docs/素材格式支持.md "$APP/Contents/Resources/素材格式支持.md"
cp docs/配乐曲库说明.md "$APP/Contents/Resources/配乐曲库说明.md"
cp docs/小人气泡说明.md "$APP/Contents/Resources/小人气泡说明.md"
mkdir -p "$APP/Contents/Resources/showcase"
cp docs/showcase/my-companion.png "$APP/Contents/Resources/showcase/my-companion.png"
cp docs/本地AI说明.md "$APP/Contents/Resources/本地AI说明.md"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>YingShu</string>
<key>CFBundleIdentifier</key><string>local.yingshu.studio</string>
<key>CFBundleName</key><string>映述</string>
<key>CFBundleDisplayName</key><string>映述</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleShortVersionString</key><string>0.14.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>映述使用麦克风输入你对当前画面的感想，并把语音转为字幕或文字贴纸。录音不会加入导出视频。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>映述使用系统中文语音识别，把你的口述转为文字并附着在当前素材片段。系统可能通过 Apple 服务处理语音。</string>
<key>NSHumanReadableCopyright</key><string>映述 · 本地旅行口述剪辑工具</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf '%s\n' "$APP"
