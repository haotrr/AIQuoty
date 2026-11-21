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

if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]] && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Optionally load gitignored local build secrets (.env.build / .env.local) if present.
for env_file in "$ROOT/.env.build" "$ROOT/.env.local"; do
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
done

swift --version
swift test --package-path "$ROOT"

swift build --package-path "$ROOT" -c release --product AIQuoty

BIN="$(swift build --package-path "$ROOT" -c release --product AIQuoty --show-bin-path)/AIQuoty"
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

# Inject build-time OAuth client credentials into Info.plist (never committed to Git).
PLIST_PATH="$DIST/AIQuoty.app/Contents/Info.plist"
inject_plist_string() {
  local key="$1"
  local val="$2"
  if [[ -n "$val" ]]; then
    /usr/libexec/PlistBuddy -c "Add :$key string $val" "$PLIST_PATH" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :$key $val" "$PLIST_PATH"
  fi
}
inject_plist_string "AIQuotyAntigravityOAuthClientID" "${AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_ID:-}"
inject_plist_string "AIQuotyAntigravityOAuthClientSecret" "${AIQUOTY_ANTIGRAVITY_OAUTH_CLIENT_SECRET:-}"
inject_plist_string "AIQuotyGeminiOAuthClientID" "${AIQUOTY_GEMINI_OAUTH_CLIENT_ID:-}"
inject_plist_string "AIQuotyGeminiOAuthClientSecret" "${AIQUOTY_GEMINI_OAUTH_CLIENT_SECRET:-}"

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:|Apple Development:/ {print $2; exit}' || true)"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with identity: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$DIST/AIQuoty.app"
else
  echo "Signing ad-hoc (no local Apple Development / Developer ID identity found)"
  codesign --force --deep --sign - "$DIST/AIQuoty.app" || true
fi
ditto -c -k --sequesterRsrc --keepParent "$DIST/AIQuoty.app" "$DIST/AIQuoty-macos14.zip"
echo "Built: $DIST/AIQuoty.app"
echo "Zip:   $DIST/AIQuoty-macos14.zip"
