#!/bin/bash
# Builds KindleMTP.app. Requires: brew install libmtp
set -euo pipefail
cd "$(dirname "$0")"

PREFIX=$(brew --prefix libmtp)
APP="KindleMTP.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KindleMTP</string>
  <key>CFBundleDisplayName</key><string>Kindle</string>
  <key>CFBundleExecutable</key><string>KindleMTP</string>
  <key>CFBundleIdentifier</key><string>local.kindlemtp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -swift-version 5 -O -parse-as-library \
  -import-objc-header shim.h \
  -Xcc -I"$PREFIX/include" \
  -L"$PREFIX/lib" -lmtp \
  -o "$APP/Contents/MacOS/KindleMTP" \
  KindleMTP.swift

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
