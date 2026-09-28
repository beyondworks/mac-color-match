#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="Mac Color Match.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -O -framework AppKit -framework SwiftUI -framework CoreGraphics -framework Vision -framework CoreImage -framework ImageIO Sources/DisplayEngine.swift Sources/PhotoCalibration.swift Sources/PhotoPattern.swift Sources/main.swift -o "$APP/Contents/MacOS/MacColorMatch"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if xattr "$APP" | /usr/bin/grep -qx 'com.apple.FinderInfo'; then
    xattr -d com.apple.FinderInfo "$APP"
fi
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
