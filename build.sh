#!/bin/bash
# Builds Resizer.app into ./build. Usage:
#   ./build.sh            build only
#   ./build.sh install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Resizer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc Sources/*.swift \
    -o "$APP/Contents/MacOS/Resizer" \
    -swift-version 5 -O \
    -framework AppKit -framework PDFKit

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Stamp the build number (git commit count) and generate the changelog shown
# in the About window. Skipped gracefully when building outside a git clone.
if git rev-parse --git-dir >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleVersion $(git rev-list --count HEAD)" \
        "$APP/Contents/Info.plist"
    git log -n 100 --pretty='%ad  %s' --date=short \
        > "$APP/Contents/Resources/changelog.txt"
fi

# Build the .icns from Resources/AppIcon.png (Icons8 "resize" icon) when the
# source is newer than the cached icns.
if [ ! -f build/AppIcon.icns ] || [ Resources/AppIcon.png -nt build/AppIcon.icns ]; then
    echo "Generating icon…"
    ICONSET=build/AppIcon.iconset
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -s format png -z "$size" "$size" Resources/AppIcon.png \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    done
    for size in 16 32 128 256; do
        cp "$ICONSET/icon_$((size * 2))x$((size * 2)).png" \
            "$ICONSET/icon_${size}x${size}@2x.png"
    done
    cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
    rm -rf "$ICONSET"
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS treats the bundle as a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    echo "Installing to /Applications…"
    rm -rf /Applications/Resizer.app
    cp -R "$APP" /Applications/
    echo "Installed. Launch with: open /Applications/Resizer.app"
fi
