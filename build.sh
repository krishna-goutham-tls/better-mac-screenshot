#!/bin/bash
# Builds build/ScreenshotTool.app with plain swiftc (Command Line Tools are enough).
# Signs with the local "TLS Local Dev" identity when this Mac has it, so the Screen Recording
# permission survives rebuilds. Without it, signs ad hoc (macOS then asks again after each build).
set -euo pipefail

cd "$(dirname "$0")"

NAME="ScreenshotTool"
APP="build/$NAME.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS/$NAME"
MIN_OS="14.0"
SDK="$(xcrun --show-sdk-path)"
IDENTITY="TLS Local Dev"

shopt -s nullglob
SOURCES=(Sources/*.swift)
if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "error: no Swift files in Sources/" >&2
    exit 1
fi

rm -rf "$APP" build/obj
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" build/obj

compile() {
    local arch="$1"
    swiftc -O -swift-version 5 \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MIN_OS" \
        -module-name "$NAME" \
        -framework AppKit -framework Carbon -framework ScreenCaptureKit \
        -o "build/obj/$NAME-$arch" \
        "${SOURCES[@]}"
}

echo "==> compiling arm64"
compile arm64

echo "==> compiling x86_64"
if compile x86_64; then
    lipo -create "build/obj/$NAME-arm64" "build/obj/$NAME-x86_64" -output "$BIN"
else
    echo "warning: x86_64 build failed, shipping arm64 only" >&2
    cp "build/obj/$NAME-arm64" "$BIN"
fi

echo "==> writing Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ScreenshotTool</string>
    <key>CFBundleIdentifier</key>
    <string>space.thelaunch.screenshottool</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Screenshot Tool</string>
    <key>CFBundleDisplayName</key>
    <string>Screenshot Tool</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 thelaunch.space</string>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "==> signing with $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "==> signing (ad hoc)"
    codesign --force --sign - --timestamp=none "$APP"
fi

rm -rf build/obj
echo "==> built $APP ($(lipo -archs "$BIN"))"
