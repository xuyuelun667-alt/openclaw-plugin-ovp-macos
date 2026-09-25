#!/bin/bash
# Phase 1 scenario test harness. Captures real screenshots/state per scenario.
# Focus policy: background windows via `open -g`; only the desktop + error-dialog
# captures temporarily change focus, and Chrome is re-activated afterwards.
set -u
OVP=/Users/xu/.openclaw/workspace/visual-preprocessor/.build/release/ovp
OUT=/tmp/ovp_tests
mkdir -p "$OUT"
cd "$OUT"

say() { echo "[$(date +%H:%M:%S)] $*"; }

win_id_by_app() {  # $1 = app substring
  "$OVP" windows 2>/dev/null | awk -F'\t' -v a="$1" 'index($2,a)>0 {print $1; exit}'
}
win_title_by_app() {
  "$OVP" windows 2>/dev/null | awk -F'\t' -v a="$1" 'index($2,a)>0 {print $3; exit}'
}

run_scenario() {  # $1=name, rest=ovp args
  local name="$1"; shift
  local t0=$(python3 -c 'import time;print(time.time())')
  "$OVP" inspect "$@" --max-chars 4000 > "$OUT/$name.text" 2> "$OUT/$name.err"
  local rc=$?
  local t1=$(python3 -c 'import time;print(time.time())')
  local ms=$(python3 -c "print(int(($t1-$t0)*1000))")
  echo "$name rc=$rc wall_ms=$ms" >> "$OUT/summary.txt"
  say "$name rc=$rc wall=${ms}ms"
}

: > "$OUT/summary.txt"

# ---------- phase A: background windows (no focus change) ----------
say "opening background windows"
open -g /tmp                      # Finder window, background
open -g -a Terminal               # Terminal (background)
open -g -a "System Settings"      # Settings (background)
sleep 4

say "window list:"
"$OVP" windows | tee "$OUT/windows.txt"

CHROME_ID=$(win_id_by_app "Chrome")
QQ_ID=$(win_id_by_app "QQ")
FINDER_ID=$(win_id_by_app "Finder")
TERM_ID=$(win_id_by_app "Terminal")
SETTINGS_ID=$(win_id_by_app "System Settings")
EMULATOR_ID=$(win_id_by_app "emulator")
STUDIO_ID=$(win_id_by_app "Android Studio")

echo "ids chrome=$CHROME_ID qq=$QQ_ID finder=$FINDER_ID term=$TERM_ID settings=$SETTINGS_ID studio=$STUDIO_ID emu=$EMULATOR_ID" >> "$OUT/summary.txt"

# ---------- phase B: screen-level scenarios (focus changes, restored after) ----------
say "screen baseline"
run_scenario "screen_baseline" --screen --level normal

if [ -n "$FINDER_ID" ]; then
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
  sleep 1.2
  run_scenario "desktop" --screen --level normal
fi

# error dialog (real modal alert)
say "raising modal alert"
osascript -e 'display alert "ovp phase1 test" message "synthetic modal dialog for pipeline validation" as critical' >/tmp/ovp_alert.log 2>&1 &
ALERT_PID=$!
sleep 1.5
run_scenario "dialog" --screen --level normal
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 0.6
kill $ALERT_PID 2>/dev/null
say "dialog dismissed"

# restore the user's front app
osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1
sleep 0.8

# ---------- phase C: window-level scenarios ----------
[ -n "$CHROME_ID" ]   && run_scenario "chrome"   --window "$CHROME_ID"   --level normal
[ -n "$TERM_ID" ]     && run_scenario "terminal" --window "$TERM_ID"     --level normal
[ -n "$QQ_ID" ]       && run_scenario "qq"       --window "$QQ_ID"       --level normal
[ -n "$SETTINGS_ID" ] && run_scenario "settings" --window "$SETTINGS_ID" --level normal
[ -n "$FINDER_ID" ]   && run_scenario "finder"   --window "$FINDER_ID"   --level normal
[ -n "$STUDIO_ID" ]   && run_scenario "studio"   --window "$STUDIO_ID"   --level normal
[ -n "$EMULATOR_ID" ] && run_scenario "emulator" --window "$EMULATOR_ID" --level normal

# ---------- phase D: file input + levels + cache ----------
say "file input"
if [ -f "$OUT/screen_baseline.png" ]; then :; fi
screencapture -x -o "$OUT/fixture_desktop.png"
run_scenario "file_desktop" "$OUT/fixture_desktop.png" --level normal
run_scenario "file_desktop_repeat" "$OUT/fixture_desktop.png" --level normal
run_scenario "file_desktop_fast" "$OUT/fixture_desktop.png" --level fast
run_scenario "file_desktop_nocache" "$OUT/fixture_desktop.png" --level normal --no-cache

say "cache stats:"
"$OVP" cache stats | tee -a "$OUT/summary.txt"
say "daemon stats:"
"$OVP" daemon --status | tee -a "$OUT/summary.txt"

say "done"
cat "$OUT/summary.txt"
