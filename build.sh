#!/bin/bash
# Builds build.noindex/BetterMacScreenshot.app (".noindex" keeps dev builds out of Spotlight) with plain swiftc (Command Line Tools are enough).
# Signs with the local "TLS Local Dev" identity when this Mac has it, so the Screen Recording
# permission survives rebuilds. Without it, signs ad hoc (macOS then asks again after each build).
set -euo pipefail

cd "$(dirname "$0")"

NAME="BetterMacScreenshot"
APP="build.noindex/$NAME.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS/$NAME"
MIN_OS="14.0"
SDK="$(xcrun --show-sdk-path)"
# Developer ID when this Mac has it: dev builds then share the installed app's Screen Recording grant.
IDENTITY="Developer ID Application: Narasipuram Krishna Goutham (859S7G7287)"
security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" || IDENTITY="TLS Local Dev"

shopt -s nullglob
SOURCES=(Sources/*.swift)
if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "error: no Swift files in Sources/" >&2
    exit 1
fi

rm -rf "$APP" build.noindex/obj
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" build.noindex/obj

compile() {
    local arch="$1"
    swiftc -O -swift-version 5 \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MIN_OS" \
        -module-name "$NAME" \
        -framework AppKit -framework Carbon -framework ScreenCaptureKit -framework ServiceManagement -framework SwiftUI \
        -o "build.noindex/obj/$NAME-$arch" \
        "${SOURCES[@]}"
}

echo "==> compiling arm64"
compile arm64

echo "==> compiling x86_64"
if compile x86_64; then
    lipo -create "build.noindex/obj/$NAME-arm64" "build.noindex/obj/$NAME-x86_64" -output "$BIN"
else
    echo "warning: x86_64 build failed, shipping arm64 only" >&2
    cp "build.noindex/obj/$NAME-arm64" "$BIN"
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
    <string>BetterMacScreenshot</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>space.thelaunch.screenshottool</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Better Mac Screenshot</string>
    <key>CFBundleDisplayName</key>
    <string>Better Mac Screenshot</string>
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

echo "==> copying Resources"
if [ -d Resources ]; then
    for f in Resources/*; do
        [ -f "$f" ] && cp "$f" "$CONTENTS/Resources/"
    done
fi

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "==> signing with $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "==> signing (ad hoc)"
    codesign --force --sign - --timestamp=none "$APP"
fi

rm -rf build.noindex/obj
echo "==> built $APP ($(lipo -archs "$BIN"))"
