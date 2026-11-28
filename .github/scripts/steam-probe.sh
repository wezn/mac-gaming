# shellcheck shell=bash
# Helpers for .github/workflows/steam.yml, sourced by its steps. Each takes a stage name
# ("update" for the first start, "client" for the second) and keeps its files in $PROBE.
# The steps run with bash -eo pipefail, so a pipeline that may find nothing ends in `|| true`.

# Wine processes, as ps shows them: "<pid> C:\...\program.exe args", or the Unix path inside the
# bottle for a program mgx started directly.
wine_ps() { { pgrep -fl . || true; } | { grep -E '^[0-9]+ ([A-Za-z]:[\\/]|[^ ]*/drive_c/)' || true; } | cut -c1-400; }

# A screenshot plus the list of Wine windows (position, size, alpha), since an off-screen or
# transparent window is invisible in the screenshot.
shot() {
  local stage=$1 name=$2
  screencapture -x "$SHOTS/$name.png" || true
  { echo "== $name $(date +%T)"; "$WINLIST" || true; } >> "$PROBE/$stage-windows.txt"
  echo "$name $("$WINLIST" --lit "$SHOTS/$name.png" 'Sign in to Steam' 2>&1 || true)" >> "$PROBE/$stage-lit.txt"
}

# The login window in the last screenshot of a stage: how much of it is not black.
lit() { tail -n 1 "$PROBE/$1-lit.txt" 2>/dev/null | cut -d' ' -f2- || true; }

# Starts steam.exe with $CLIENT_ARGS and crash tracing, in the background, and finds its mgx log.
start_steam() {
  local stage=$1 logs="$MG_HOME/logs/st"
  mkdir -p "$PROBE" "$SHOTS"
  ls "$logs" > "$PROBE/$stage.logs-before" 2>/dev/null || true
  # shellcheck disable=SC2086 # CLIENT_ARGS is a word list
  $MGX run --bottle st --debug 'err+all,+seh' "$STEAM_DIR/steam.exe" $CLIENT_ARGS > "$PROBE/$stage.out" 2>&1 &
  echo $! > "$PROBE/$stage.pid"
  for _ in $(seq 1 20); do
    sleep 1
    local new
    # shellcheck disable=SC2010 # mgx names logs itself (no newlines)
    new=$(ls "$logs" 2>/dev/null | grep -vxF -f "$PROBE/$stage.logs-before" | grep -i 'steam' | tail -n 1 || true)
    if [[ -n "$new" ]]; then echo "$logs/$new" > "$PROBE/$stage.logpath"; break; fi
  done
  echo "$stage log: $(cat "$PROBE/$stage.logpath" 2>/dev/null || echo 'not found')"
}

# Records the Wine processes, and the steamwebhelper browser processes (no --type=) by PID.
sample() {
  local stage=$1 ps
  ps=$(wine_ps)
  { echo "== $(date +%T)"; echo "$ps"; } >> "$PROBE/$stage-ps.txt"
  echo "$ps" | grep -i 'steamwebhelper.exe' | grep -v -- '--type=' | awk '{print $1}' >> "$PROBE/$stage-webhelper-pids.txt" || true
}

stop_steam() {
  local stage=$1 pid
  wine_ps > "$PROBE/$stage-alive.txt" || true
  cat "$PROBE/$stage-alive.txt"
  $MGX bottle stop st || true
  pid=$(cat "$PROBE/$stage.pid" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  # Do not leave a client running into the next stage.
  pkill -9 -f 'wineserver|wine64-preloader|wine-preloader' 2>/dev/null || true
}

logpath() { cat "$PROBE/$1.logpath" 2>/dev/null || true; }
count_in_log() { local f; f=$(logpath "$1"); if [[ -f "$f" ]]; then grep -c "$2" "$f" || true; else echo "n/a"; fi; }
crashes() { count_in_log "$1" 'Unhandled exception'; }
swapchain() { count_in_log "$1" 'cross-process swapchain'; }

# Crash backtraces that involve steamwebhelper or its Chromium (libcef.dll).
webhelper_crashes() {
  local f; f=$(logpath "$1")
  [[ -f "$f" ]] || { echo "n/a"; return; }
  awk '/Unhandled exception/ { if (n && hit) c++; n = 1; hit = 0; next }
       n && n < 80 { n++; if (tolower($0) ~ /libcef|steamwebhelper/) hit = 1 }
       END { if (n && hit) c++; print c + 0 }' "$f"
}

webhelper_starts() { sort -u "$PROBE/$1-webhelper-pids.txt" 2>/dev/null | grep -c . || true; }

alive() {
  local f="$PROBE/$1-alive.txt"
  [[ -f "$f" ]] || { echo "n/a"; return; }
  echo "$(grep -ci '\\steam.exe\|/steam.exe' "$f" || true) / $(grep -ci 'steamwebhelper.exe' "$f" || true)"
}
