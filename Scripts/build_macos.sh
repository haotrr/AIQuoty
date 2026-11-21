#!/usr/bin/env bash
# Build AIQuoty.app on macOS 14+ with Xcode / Swift 5.9+.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: macOS .app packaging requires Darwin. Current: $(uname -s)" >&2
  echo "On this host, run: Scripts/test_linux.sh  (core + CLI only)" >&2
  exit 2
fi

swift --version
swift test --package-path "$ROOT"

APP_DIR="$ROOT/Apps/AIQuoty"
cd "$APP_DIR"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/AIQuoty"
DIST="$ROOT/dist"
rm -rf "$DIST/AIQuoty.app"
mkdir -p "$DIST/AIQuoty.app/Contents/MacOS"
mkdir -p "$DIST/AIQuoty.app/Contents/Resources"
cp "$BIN" "$DIST/AIQuoty.app/Contents/MacOS/AIQuoty"
cat > "$DIST/AIQuoty.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>AIQuoty</string>
  <key>CFBundleIdentifier</key><string>local.aiquoty.app</string>
  <key>CFBundleName</key><string>AIQuoty</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$DIST/AIQuoty.app" || true
ditto -c -k --sequesterRsrc --keepParent "$DIST/AIQuoty.app" "$DIST/AIQuoty-macos14.zip"
echo "Built: $DIST/AIQuoty.app"
echo "Zip:   $DIST/AIQuoty-macos14.zip"
