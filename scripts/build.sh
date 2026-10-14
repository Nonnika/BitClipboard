#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/clang-cache"
swift build -c release --disable-sandbox --cache-path "$TASK_ROOT/.build/cache"
TASK_BINARY_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path "$TASK_ROOT/.build/cache")"
TASK_BUNDLE="$TASK_ROOT/dist/BitClipboard.app"
mkdir -p "$TASK_BUNDLE/Contents/MacOS" "$TASK_BUNDLE/Contents/Resources"
cp "$TASK_BINARY_DIR/BitClipboard" "$TASK_BUNDLE/Contents/MacOS/BitClipboard"
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_BUNDLE/Contents/Info.plist"
cp -R "$TASK_ROOT/Resources/ThirdParty" "$TASK_BUNDLE/Contents/Resources/"
cp -R "$TASK_BINARY_DIR/BitClipboard_BitClipboard.bundle" "$TASK_BUNDLE/Contents/Resources/"
swift "$TASK_ROOT/scripts/make-icon.swift" "$TASK_ROOT/.build/AppIcon.iconset"
iconutil -c icns "$TASK_ROOT/.build/AppIcon.iconset" -o "$TASK_BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$TASK_BUNDLE"
touch "$TASK_BUNDLE"
echo "应用已生成：$TASK_BUNDLE"
