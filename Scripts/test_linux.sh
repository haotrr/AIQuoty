#!/usr/bin/env bash
# Portable core verification on Linux (no AppKit / no .app).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/swift/usr/bin:${PATH:-}"
cd "$ROOT"
swift --version
swift test --package-path "$ROOT"
swift build --package-path "$ROOT" --product aiquoty-cli
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/aiquoty-cli"
"$BIN" providers | tee /tmp/aiquoty-providers.txt
"$BIN" --demo | tee /tmp/aiquoty-demo.txt
echo "Linux core tests + demo CLI OK"
