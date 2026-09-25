#!/usr/bin/env bash
# Build the local engine (Swift) and place it where the plugin looks first: ./bin/ovp
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'MSG'
ovp engine needs the Swift toolchain.
Install Xcode Command Line Tools:  xcode-select --install
MSG
  exit 1
fi

echo "== building ovp engine (release) =="
swift build -c release

mkdir -p bin
cp -f .build/release/ovp bin/ovp
chmod +x bin/ovp
echo "== engine ready: $(pwd)/bin/ovp =="

# A resident daemon keeps serving the OLD binary until it is restarted.
if ./bin/ovp daemon --status 2>/dev/null | grep -q "up"; then
  echo "== restarting warm daemon so it picks up the new binary =="
  ./bin/ovp daemon --stop >/dev/null 2>&1 || true
fi

./bin/ovp version
