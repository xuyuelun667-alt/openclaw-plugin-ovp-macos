#!/usr/bin/env bash
# Build the engine and install it as the packaged artifact: ./bin/ovp
#
# Two macOS-specific details matter here:
#   1. We build a universal binary (arm64 + x86_64) so the published package works on both.
#   2. We never overwrite bin/ovp in place: replacing a signed Mach-O in place can leave the
#      kernel's code-signature cache stale, and the next exec is killed with SIGKILL (137).
#      Write to a temp name and mv it into place instead.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'MSG'
ovp engine needs the Swift toolchain.
Install Xcode Command Line Tools:  xcode-select --install
MSG
  exit 1
fi

echo "== building ovp engine (release, universal if supported) =="
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
  BUILT=".build/out/Products/Release/ovp"
  [ -f "$BUILT" ] || BUILT=".build/apple/Products/Release/ovp"
else
  echo "   (universal build unavailable; falling back to the host architecture)"
  swift build -c release
  BUILT=".build/release/ovp"
fi

if [ ! -f "$BUILT" ]; then
  echo "build produced no binary at $BUILT" >&2
  exit 1
fi

mkdir -p bin
# atomic replace (see the note at the top of this script)
cp -f "$BUILT" "bin/.ovp.new"
chmod 755 "bin/.ovp.new"
mv -f "bin/.ovp.new" "bin/ovp"

echo "== engine ready: $(pwd)/bin/ovp =="
if command -v lipo >/dev/null 2>&1; then
  lipo -info bin/ovp 2>/dev/null || true
fi

# A resident daemon keeps serving the OLD binary until it is restarted.
if ./bin/ovp daemon --status 2>/dev/null | grep -q "up"; then
  echo "== restarting warm daemon so it picks up the new binary =="
  ./bin/ovp daemon --stop >/dev/null 2>&1 || true
fi

./bin/ovp version
