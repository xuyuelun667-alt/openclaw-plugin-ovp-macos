#!/bin/bash
# Round 2: focus-assisted scenarios (QQ / Settings / Terminal / Finder).
# Everything created here is cleaned up at the end; Chrome is restored as front app.
set -u
OVP=/Users/xu/.openclaw/workspace/visual-preprocessor/.build/release/ovp
OUT=/tmp/ovp_tests
mkdir -p "$OUT"
say() { echo "[$(date +%H:%M:%S)] $*"; }

# probe tool: list ALL windows (incl. other spaces / minimized)
cat > /tmp/wlall.swift <<'EOF'
import CoreGraphics
import Foundation
let opts = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
  for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let id = (w[kCGWindowNumber as String] as? Int) ?? 0
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    var b = "?"
    if let d = w[kCGWindowBounds as String] as? [String: Any] { b = "\(d["X"] ?? 0),\(d["Y"] ?? 0) \(d["Width"] ?? 0)x\(d["Height"] ?? 0)" }
    print("\(id)\t\(owner)\t\(name)\tlayer=\(layer)\t\(b)")
  }
}
EOF
swiftc -O /tmp/wlall.swift -o /tmp/wlall 2>/dev/null

say "== all windows (optionAll) before =="
/tmp/wlall | grep -Ei "finder|terminal|qq|settings|studio|emulator" | tee "$OUT/windows_all_before.txt"

say "== AVD inventory =="
{ ls ~/.android/avd 2>&1 | head; ~/Library/Android/sdk/emulator/emulator -list-avds 2>&1 | head; } | tee "$OUT/avds.txt"

say "== bringing up apps (focus changes) =="
open -a QQ >/dev/null 2>&1
sleep 2.5
open -a "System Settings" >/dev/null 2>&1
sleep 3
/tmp/wlall | grep -Ei "finder|terminal|qq|settings" | tee "$OUT/windows_all_after.txt"

run_win() {  # $1 name  $2 app-filter
  local name="$1" filt="$2"
  local id
  id=$(awk -F'\t' -v a="$filt" 'index($2,a)>0 && $4=="layer=0" {print $1; exit}' "$OUT/windows_all_after.txt")
  if [ -z "$id" ]; then echo "$name: NO WINDOW" >> "$OUT/summary2.txt"; say "$name: no window found"; return; fi
  local t0=$(python3 -c 'import time;print(time.time())')
  "$OVP" inspect --window "$id" --level normal --max-chars 4000 > "$OUT/$name.text" 2> "$OUT/$name.err"
  local rc=$?
  local t1=$(python3 -c 'import time;print(time.time())')
  local ms=$(python3 -c "print(int(($t1-$t0)*1000))")
  echo "$name win=$id rc=$rc wall_ms=$ms" >> "$OUT/summary2.txt"
  say "$name win=$id rc=$rc wall=${ms}ms"
}

: > "$OUT/summary2.txt"
run_win "terminal" "Terminal"
run_win "finder" "Finder"
run_win "settings" "System Settings"
run_win "qq" "QQ"

say "== desktop (Finder frontmost) screen capture =="
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
sleep 1.5
local_t0=$(python3 -c 'import time;print(time.time())')
"$OVP" inspect --screen --level normal --max-chars 4000 > "$OUT/desktop.text" 2>&1
echo "desktop rc=$? wall_ms=$(python3 -c "print(int(($(python3 -c 'import time;print(time.time())')-$local_t0)*1000))")" >> "$OUT/summary2.txt"

say "== cleanup =="
osascript <<'APPLESCRIPT' >/dev/null 2>&1
try
  tell application "Terminal"
    repeat with w in (every window)
      if busy of w is false then close w
    end repeat
  end tell
end try
APPLESCRIPT
osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1
osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1
sleep 1
say "cleanup done (Finder /tmp window and QQ window left as-is)"
cat "$OUT/summary2.txt"
