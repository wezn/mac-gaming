#!/bin/bash
# A guided first test of mgx on a real Mac. See docs/TESTING.md.
#
# Downloads the newest CI builds (mgx, Wine, DXMT/DXVK) with `gh run download`, installs them into a
# throwaway MG_HOME, then walks through a checklist: wined3d Notepad, backend dry runs, DLL deployment
# probes, the D3DMetal overlay, Battle.net + Overwatch 2, Steam + CS2. Every long step asks first, and
# each step's outcome is recorded. At the end everything goes into one .tar.gz to attach to an issue.
#
# Safety: never uses sudo, never deletes anything (it only creates files under its work directory),
# and only touches the mgx root you give it (default: a fresh one under the work directory).
#
# Usage: scripts/mgx-test-session.sh [options]
#   --work DIR          Work directory: downloads, sessions, results (default: ~/mg-test)
#   --mg-home DIR       mgx root to use (default: <work>/home)
#   --mg PATH           Use this mgx binary instead of downloading the CI build
#   --gptk PATH         Game Porting Toolkit path (skips the prompt); "none" to skip D3DMetal
#   --repo OWNER/NAME   Repository to download from (default: wezn/mac-gaming)
#   --mg-run ID, --wine-run ID, --graphics-run ID
#                       Use these workflow runs instead of the newest successful ones
#   --from N            Start the checklist at step N (after setup), e.g. to resume
#   --package-only      Skip everything and just collect a report for the mgx root
#   -h, --help          Show this help
#
# Bash 3.2 compatible (the /bin/bash macOS ships).

set -euo pipefail

REPO="wezn/mac-gaming"
WORK="$HOME/mg-test"
MG_HOME_ARG=""
MG_ARG=""
GPTK_ARG=""
MG_RUN=""
WINE_RUN=""
GFX_RUN=""
FROM=1
PACKAGE_ONLY=false

usage() { sed -n '2,/^# Bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    --mg-home) MG_HOME_ARG="$2"; shift 2 ;;
    --mg) MG_ARG="$2"; shift 2 ;;
    --gptk) GPTK_ARG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --mg-run) MG_RUN="$2"; shift 2 ;;
    --wine-run) WINE_RUN="$2"; shift 2 ;;
    --graphics-run) GFX_RUN="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --package-only) PACKAGE_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

for v in "$MG_RUN" "$WINE_RUN" "$GFX_RUN" "$FROM"; do
  [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] || { echo "not a number: $v" >&2; exit 2; }
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FIXTURES="$REPO_ROOT/launcher/Tests/MGCoreTests/Fixtures"
STAMP=$(date +%Y%m%d-%H%M%S)

# ---------- output helpers ----------

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
say()  { printf '%s\n' "$*"; [[ -n "${TRANSCRIPT:-}" ]] && printf '%s\n' "$*" >> "$TRANSCRIPT"; return 0; }
info() { say "${B}==>${N} $*"; }
warn() { say "${Y}warning:${N} $*"; }
die()  { say "${R}error:${N} $*"; exit 1; }

# ask "question" default(y|n) -> 0 for yes. "q" quits (results so far are still packaged).
ask() {
  local q="$1" def="${2:-y}" hint reply
  if [[ "$def" == y ]]; then hint="[Y/n/q]"; else hint="[y/N/q]"; fi
  while true; do
    read -r -p "$q $hint " reply || reply=q
    reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
    [[ -z "$reply" ]] && reply="$def"
    case "$reply" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      q|quit) say "quitting"; exit 0 ;;
    esac
  done
}

# Run a command, show it, and append its output to the transcript. Returns the command's exit code.
run() {
  say "\$ $*"
  local code=0
  "$@" 2>&1 | tee -a "$TRANSCRIPT" || code=${PIPESTATUS[0]}
  [[ "$code" == 0 ]] || say "(exit code $code)"
  return "$code"
}

# Record the outcome of a manual check in results.md.
STEP_NO=0
STEP_TITLE=""
record() { printf -- '- **%s. %s**: %s\n' "$STEP_NO" "$STEP_TITLE" "$*" >> "$RESULTS"; }

outcome() {
  local q="$1" reply note
  while true; do
    read -r -p "$q [p]ass / [f]ail / [s]kip: " reply || reply=s
    case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
      p|pass) reply=PASS; break ;;
      f|fail) reply=FAIL; break ;;
      s|skip|"") reply=SKIPPED; break ;;
    esac
  done
  read -r -p "Notes (what you saw, fps, errors; Enter for none): " note || note=""
  record "$reply${note:+ — $note}"
  say "recorded: $reply${note:+ — $note}"
}

# step "title" "what it does / what to look for": returns 1 if the user skips it.
step() {
  STEP_NO=$((STEP_NO + 1))
  STEP_TITLE="$1"
  if (( STEP_NO < FROM )); then return 1; fi
  say ""
  say "${B}---- Step $STEP_NO: $1 ----${N}"
  [[ -n "${2:-}" ]] && say "$2"
  if ask "Run step $STEP_NO?" y; then return 0; fi
  record "SKIPPED (not run)"
  return 1
}

# first <glob results>...: the first path that exists (globs that match nothing stay literal).
first() {
  local f
  for f in "$@"; do
    if [[ -e "$f" ]]; then echo "$f"; return 0; fi
  done
  return 0
}

# has_bottle <name>. (grep without -q: an early exit would make the writer fail under pipefail.)
has_bottle() {
  "$MG" bottle list 2>/dev/null | grep -E "^[* ] ${1}[[:space:]]" >/dev/null
}

# compare_dlls <component> <target dir> <src:dst>...: is each <target>/<dst> byte-identical to runtimes/*/<component>/<src>?
compare_dlls() {
  local comp="$1" win="$2" pair src; shift 2
  for pair in "$@"; do
    src=$(first "$MG_HOME"/runtimes/*/"$comp"/"${pair%%:*}")
    if [[ -n "$src" ]] && cmp -s "$src" "$win/${pair#*:}"; then
      say "ok: ${pair#*:} is $comp's ${pair%%:*}"
    else
      say "MISMATCH: ${pair#*:} is not $comp's ${pair%%:*}"
    fi
  done
}

# Replace $HOME with ~ and the account name in Wine user paths with USER (literal, not regex).
redact_file() {
  local f="$1" tmp
  tmp="$f.redact.$$"
  awk -v home="$HOME" -v user="${USER:-}" '
    function repl(s, needle, rep,   out, i, ls, ln) {
      out = ""; ln = length(needle)
      if (ln == 0) return s
      ls = tolower(s); needle = tolower(needle)
      while ((i = index(ls, needle)) > 0) {
        out = out substr(s, 1, i - 1) rep
        s = substr(s, i + ln); ls = substr(ls, i + ln)
      }
      return out s
    }
    {
      line = $0
      if (length(home) > 1) line = repl(line, home, "~")
      if (user != "") { line = repl(line, "users/" user "/", "users/USER/"); line = repl(line, "users\\" user "\\", "users\\USER\\") }
      print line
    }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ---------- preflight ----------

[[ "$(id -u)" != 0 ]] || die "do not run this as root or with sudo"
[[ "$(uname -s)" == Darwin ]] || die "this script tests mgx on macOS; run it on the Mac"
[[ "$(uname -m)" == arm64 ]] || echo "warning: this is not an Apple Silicon Mac ($(uname -m)); mgx targets Apple Silicon"

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
SESSION="$WORK/sessions/$STAMP"
mkdir -p "$SESSION"
TRANSCRIPT="$SESSION/transcript.log"
RESULTS="$SESSION/results.md"
: > "$TRANSCRIPT"
{
  echo "# mgx test session $STAMP"
  echo
  echo "Steps and outcomes (PASS / FAIL / SKIPPED, with the tester's notes):"
  echo
} > "$RESULTS"

if [[ -n "$MG_HOME_ARG" ]]; then
  mkdir -p "$MG_HOME_ARG"
  MG_HOME=$(cd "$MG_HOME_ARG" && pwd)
  if [[ "$MG_HOME" == "$HOME/Library/Application Support/mac-gaming" ]]; then
    warn "that is mgx's real default root; bottles created here are your everyday ones."
    ask "Use it anyway?" n || exit 0
  fi
else
  MG_HOME="$WORK/home"
  mkdir -p "$MG_HOME"
fi
export MG_HOME
# Things in the shell that would change Wine's behaviour behind mgx's back.
unset WINEPREFIX WINEDLLOVERRIDES WINEDEBUG WINELOADER WINESERVER WINEDLLPATH WINEARCH MG_GPTK 2>/dev/null || true

info "work directory: $WORK"
info "mgx root (MG_HOME): $MG_HOME"
info "session: $SESSION"

# ---------- packaging (also runs on exit, so a quit or failure still leaves a report) ----------

PACKAGED=false
MG=""
GPTK_PATH=""
package() {
  $PACKAGED && return 0
  PACKAGED=true
  set +e
  say ""
  info "collecting the report"
  local out="$SESSION/report"
  mkdir -p "$out"
  {
    echo "script: scripts/mgx-test-session.sh ($(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
    echo "repo: $REPO"
    echo "runs: mg=${MG_RUN:-local} wine=${WINE_RUN:-none} graphics=${GFX_RUN:-none}"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## sw_vers"; sw_vers
    echo
    echo "## sysctl"
    sysctl -n machdep.cpu.brand_string hw.model hw.memsize hw.ncpu 2>&1
    echo "sysctl.proc_translated: $(sysctl -n sysctl.proc_translated 2>/dev/null || echo n/a) (1 = this shell runs under Rosetta)"
    echo
    echo "## Rosetta"
    if arch -x86_64 /usr/bin/true 2>/dev/null; then echo "installed"; else echo "NOT installed"; fi
    echo
    echo "## Display"
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|Resolution|Retina|Metal' || true
    echo
    echo "## GPTK"
    echo "path: ${GPTK_PATH:-not set}"
    gptk_version
    echo
    echo "## mgx"
    if [[ -n "$MG" ]]; then
      "$MG" --version
      "$MG" config show
      "$MG" runtime list
      "$MG" bottle list
    fi
    echo
    echo "## Overlays"
    ls -ld "$MG_HOME"/runtimes/*/wine-dxmt/lib/wine/x86_64-unix/winemetal.so 2>&1
    ls -ld "$MG_HOME"/runtimes/*/wine-d3dmetal/lib/external/D3DMetal.framework 2>&1
  } > "$out/host.txt" 2>&1
  if [[ -n "$MG" ]]; then
    "$MG" doctor > "$out/doctor.txt" 2>&1
    "$MG" doctor --json > "$out/doctor.json" 2>&1
    "$MG" logs -n 100 > "$out/logs-list.txt" 2>&1
    "$MG" report --logs 30 -o "$out/mgx-report" > /dev/null 2>"$out/mgx-report.err" || warn "mgx report failed: $(cat "$out/mgx-report.err")"
  fi
  cp "$RESULTS" "$out/results.md"
  cp "$TRANSCRIPT" "$out/transcript.log"
  local f
  while IFS= read -r f; do redact_file "$f"; done < <(find "$out" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.md' -o -name '*.json' \))
  local tarball="$WORK/mg-test-$STAMP.tar.gz"
  tar -czf "$tarball" -C "$SESSION" report
  say ""
  say "${G}Report: $tarball${N} ($(du -h "$tarball" | cut -f1))"
  say "Your home folder is replaced with ~ and your account name with USER. Skim $out before posting."
  say "Attach the tarball to a GitHub issue on $REPO, and paste $out/results.md into the issue text."
  say "To remove everything this script created later: rm -rf \"$WORK\" (it never touched anything else)."
}

gptk_version() {
  [[ -n "$GPTK_PATH" && -d "$GPTK_PATH" ]] || return 0
  local plist
  plist=$(find "$GPTK_PATH" -maxdepth 7 -path '*D3DMetal.framework*' -name Info.plist 2>/dev/null | head -n 1)
  if [[ -n "$plist" ]]; then
    echo "D3DMetal.framework: $(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || echo '?') (build $(plutil -extract CFBundleVersion raw "$plist" 2>/dev/null || echo '?'))"
  else
    echo "D3DMetal.framework Info.plist not found"
  fi
  echo "layout (depth 4):"
  local line
  find "$GPTK_PATH" -maxdepth 4 \( -name '*.framework' -print -prune -o -print \) 2>/dev/null | sort | head -n 200 |
    while IFS= read -r line; do echo ".${line#"$GPTK_PATH"}"; done
}

trap package EXIT

if $PACKAGE_ONLY; then
  MG="${MG_ARG:-$(command -v mgx || true)}"
  [[ -n "$MG" ]] || die "no mgx binary: pass --mg PATH"
  GPTK_PATH="$GPTK_ARG"
  exit 0
fi

# ---------- downloads ----------

command -v gh >/dev/null || die "the GitHub CLI is needed to download CI builds: brew install gh, then gh auth login"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (downloading artifacts needs it even for a public repo): gh auth login"

# newest_run <workflow file> <artifact name regex>: the newest successful run that still has a
# matching, unexpired artifact. Prints nothing if there is none (or the workflow does not exist).
newest_run() {
  local wf="$1" re="$2" id
  for id in $(gh run list --repo "$REPO" --workflow "$wf" --status success --limit 30 --json databaseId --jq '.[].databaseId' 2>/dev/null); do
    if gh api "repos/$REPO/actions/runs/$id/artifacts?per_page=100" --jq '.artifacts[] | select(.expired | not) | .name' 2>/dev/null | grep -E "$re" >/dev/null; then
      echo "$id"
      return 0
    fi
  done
}

# fetch <kind> <run id> <glob>...: downloads into <work>/downloads/<kind>-<run>/ once, prints that dir.
fetch() {
  local kind="$1" id="$2"; shift 2
  local dest="$WORK/downloads/$kind-$id" part="$WORK/downloads/.partial-$kind-$id-$$"
  if [[ -f "$dest/.complete" ]]; then echo "$dest"; return 0; fi
  [[ ! -e "$dest" ]] || die "$dest exists but is incomplete; move it away and re-run"
  mkdir -p "$part"
  local args=() g
  for g in "$@"; do args+=(--pattern "$g"); done
  say "\$ gh run download $id --repo $REPO ${args[*]} --dir $part" >&2
  gh run download "$id" --repo "$REPO" "${args[@]}" --dir "$part" >&2 || { warn "download failed; partial files are in $part" >&2; return 1; }
  touch "$part/.complete"
  mv "$part" "$dest"
  echo "$dest"
}

info "looking up CI builds in $REPO"
if [[ -z "$MG_ARG" && -z "$MG_RUN" ]]; then MG_RUN=$(newest_run launcher.yml '^mgx-macos-arm64$'); fi
if [[ -z "$WINE_RUN" ]]; then WINE_RUN=$(newest_run build-wine.yml '^wine-crossover-'); fi
if [[ -z "$GFX_RUN" ]]; then GFX_RUN=$(newest_run build-graphics.yml '^(dxmt|dxvk-macos)-'); fi
if [[ -n "$MG_ARG" ]]; then say "mgx: $MG_ARG (local)"; else say "mgx: ${MG_RUN:-none found} (Launcher workflow)"; fi
say "wine: ${WINE_RUN:-none found} (Build Wine)"
say "graphics: ${GFX_RUN:-none found} (Build graphics layers)"
[[ -n "$MG_ARG" || -n "$MG_RUN" ]] || die "no Launcher run with an mgx-macos-arm64 artifact; build mgx (cd launcher && swift build -c release) and pass --mg launcher/.build/release/mgx"
[[ -n "$WINE_RUN" ]] || die "no successful Build Wine run with an unexpired artifact; run build-wine.yml first"
if [[ -z "$GFX_RUN" ]]; then
  warn "no Build graphics layers artifacts yet: DXMT and DXVK steps will be skipped (wined3d and D3DMetal still work)"
fi

say "Downloads: Wine ~85 MB, DXMT ~10 MB, DXVK ~3 MB, mgx ~5 MB (cached under $WORK/downloads)."
ask "Download now?" y || exit 0

if [[ -n "$MG_ARG" ]]; then
  MG=$(cd "$(dirname "$MG_ARG")" && pwd)/$(basename "$MG_ARG")
else
  d=$(fetch mgx "$MG_RUN" mgx-macos-arm64) || die "could not download mgx"
  tgz=$(find "$d" -name 'mgx-macos-arm64.tar.gz' | head -n 1)
  [[ -n "$tgz" ]] || die "no mgx-macos-arm64.tar.gz in $d"
  sumfile="$tgz.sha256"
  if [[ -f "$sumfile" ]]; then (cd "$(dirname "$tgz")" && shasum -a 256 -c "$(basename "$sumfile")") || die "mgx checksum mismatch"; fi
  mkdir -p "$WORK/bin"
  tar -xzf "$tgz" -C "$WORK/bin"
  MG="$WORK/bin/mgx"
fi
# gh downloads are not quarantined, but a browser download would be. Only this one file is touched.
if xattr -p com.apple.quarantine "$MG" >/dev/null 2>&1; then
  run xattr -d com.apple.quarantine "$MG" || true
fi
run "$MG" --version || die "$MG does not run (if macOS blocked it, see docs/TESTING.md, \"Gatekeeper\")"

WINE_DIR=$(fetch wine "$WINE_RUN" 'wine-crossover-*') || die "could not download Wine"
GFX_DIR=""
if [[ -n "$GFX_RUN" ]]; then
  GFX_DIR=$(fetch graphics "$GFX_RUN" 'dxmt-*' 'dxvk-macos-*') || { warn "graphics download failed; continuing without DXMT/DXVK"; GFX_DIR=""; }
fi

# ---------- install ----------

marker="$MG_HOME/.mg-test-session-installed"
want="wine=$WINE_RUN graphics=${GFX_RUN:-none}"
if [[ -f "$marker" && "$(cat "$marker")" == "$want" ]] && "$MG" runtime list 2>/dev/null | grep '^\*' >/dev/null; then
  info "runtime from these runs is already installed in $MG_HOME"
else
  info "installing the runtime into $MG_HOME"
  if [[ -n "$GFX_DIR" ]]; then
    run "$MG" runtime install --set-default "$WINE_DIR" "$GFX_DIR" || die "runtime install failed"
  else
    run "$MG" runtime install --set-default "$WINE_DIR" || die "runtime install failed"
  fi
  printf '%s' "$want" > "$marker"
fi
run "$MG" runtime list || true
for f in "$MG_HOME"/runtimes/*/dxmt/VERSION "$MG_HOME"/runtimes/*/dxvk/VERSION; do
  if [[ -f "$f" ]]; then run cat "$f" || true; fi
done

HAS_DXMT=false; HAS_DXVK=false
[[ -n "$(first "$MG_HOME"/runtimes/*/dxmt/x86_64-windows/d3d11.dll)" ]] && HAS_DXMT=true
[[ -n "$(first "$MG_HOME"/runtimes/*/dxvk/x64/d3d11.dll)" ]] && HAS_DXVK=true

# ---------- doctor + GPTK ----------

info "mgx doctor"
run "$MG" doctor || warn "doctor reported errors (see above); later steps may fail"
if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  warn "Rosetta 2 is missing. Install it yourself (this script never uses sudo):"
  say "    softwareupdate --install-rosetta --agree-to-license"
  ask "Continue anyway?" n || exit 0
fi

find_gptk_candidate() {
  local c
  for c in "/Volumes/Evaluation environment for Windows games"* "/Applications/Game Porting Toolkit.app" \
           "$HOME/Downloads/Evaluation environment for Windows games"* /opt/homebrew/opt/game-porting-toolkit; do
    [[ -e "$c" ]] && { echo "$c"; return 0; }
  done
  return 0
}

if [[ "$GPTK_ARG" == none ]]; then
  GPTK_PATH=""
elif [[ -n "$GPTK_ARG" ]]; then
  GPTK_PATH="$GPTK_ARG"
else
  say ""
  say "D3DMetal comes from your own copy of Apple's Game Porting Toolkit (the mounted"
  say "\"Evaluation environment for Windows games\" volume, or a folder with redist/lib in it)."
  cand=$(find_gptk_candidate)
  read -r -p "GPTK path${cand:+ [$cand]} (Enter to accept, 'none' to skip D3DMetal): " GPTK_PATH || GPTK_PATH=""
  [[ -z "$GPTK_PATH" ]] && GPTK_PATH="$cand"
  [[ "$GPTK_PATH" == none ]] && GPTK_PATH=""
fi
GPTK_PATH="${GPTK_PATH/#\~/$HOME}"
HAS_GPTK=false
if [[ -n "$GPTK_PATH" ]]; then
  if run "$MG" config set gptk "$GPTK_PATH"; then
    HAS_GPTK=true
  else
    warn "mgx did not accept that folder. Its layout (please include this in the report):"
  fi
  gptk_version 2>&1 | tee -a "$TRANSCRIPT"
  if $HAS_GPTK; then run "$MG" doctor || true; fi
fi

# ---------- checklist ----------

say ""
info "checklist: answer each prompt; 'q' at any prompt stops and writes the report"

if step "wined3d sanity: Notepad" \
  "Creates bottle 'mgtest' (wineboot, ~1 min) and opens Notepad with wined3d. Type something, then close Notepad to continue."; then
  has_bottle mgtest || run "$MG" bottle create mgtest || true
  run "$MG" run --bottle mgtest --backend wined3d notepad.exe || true
  outcome "Did Notepad open, render text crisply and accept typing?"
fi

if step "Backend selection dry runs (no side effects)" \
  "Runs 'mgx run --dry-run' on the synthetic test executables, auto and with each backend forced."; then
  if [[ -d "$FIXTURES" ]]; then
    has_bottle mgtest || run "$MG" bottle create mgtest --no-init || true
    for exe in dx8.exe dx9.exe dx10.exe dx11.exe dx12.exe ddraw.exe engine/game.exe; do
      run "$MG" run --bottle mgtest --dry-run "$FIXTURES/$exe" || true
    done
    for b in wined3d dxvk dxmt d3dmetal; do
      run "$MG" run --bottle mgtest --backend "$b" --dry-run "$FIXTURES/dx11.exe" || true
    done
    record "ran (see transcript: auto dx8/9/10/11/12/ddraw/engine, forced wined3d/dxvk/dxmt/d3dmetal)"
  else
    warn "no fixtures at $FIXTURES (run this script from a checkout of the repo)"
    record "SKIPPED (no fixtures)"
  fi
fi

# probe <bottle> <backend> <dll>: loads <dll> in rundll32 with +loaddll so the log shows which file
# Wine loaded and whether it counts as native or builtin. The entry point does not exist on purpose:
# rundll32 loads the DLL (and its imports), fails to find the export and exits.
probe() {
  local bottle="$1" backend="$2" dll="$3"
  has_bottle "$bottle" || run "$MG" bottle create "$bottle" || return 1
  run "$MG" run --bottle "$bottle" --backend "$backend" --debug +loaddll rundll32.exe "$dll,mgProbe" || true
  say "loaddll lines from the log:"
  "$MG" logs --bottle "$bottle" --last 2>/dev/null | grep -iE 'loaddll|d3d1[12]|dxgi|winemetal|d3dmetal' | head -n 40 | tee -a "$TRANSCRIPT" || true
}

if $HAS_DXVK && step "DXVK DLL deploy" \
  "Creates bottle 'mgdxvk', lets mgx copy DXVK into system32/syswow64, and loads d3d11.dll with +loaddll."; then
  probe mgdxvk dxvk d3d11.dll || true
  compare_dlls dxvk "$MG_HOME/bottles/mgdxvk/drive_c/windows" \
    x64/d3d11.dll:system32/d3d11.dll x64/dxgi.dll:system32/dxgi.dll x32/d3d11.dll:syswow64/d3d11.dll
  outcome "Did the log show system32\\d3d11.dll loaded as native (and no errors)?"
fi

if $HAS_DXMT && step "DXMT DLL deploy" \
  "Creates bottle 'mgdxmt' and loads d3d11.dll with --backend dxmt under +loaddll. mgx runs DXMT from runtimes/<r>/wine-dxmt/ (Wine with DXMT's DLLs and winemetal.so merged into lib/wine), keeps every D3D DLL builtin (no n,b overrides) and copies only winemetal.dll into system32/syswow64."; then
  probe mgdxmt dxmt d3d11.dll || true
  rt=$(first "$MG_HOME"/runtimes/*/wine-dxmt)
  if [[ -n "$rt" ]]; then
    rt=$(dirname "$rt")
    compare_dlls dxmt "$rt/wine-dxmt/lib/wine" \
      x86_64-windows/d3d11.dll:x86_64-windows/d3d11.dll x86_64-windows/dxgi.dll:x86_64-windows/dxgi.dll \
      x86_64-windows/d3d10core.dll:x86_64-windows/d3d10core.dll x86_64-windows/winemetal.dll:x86_64-windows/winemetal.dll \
      i386-windows/d3d11.dll:i386-windows/d3d11.dll i386-windows/winemetal.dll:i386-windows/winemetal.dll \
      x86_64-unix/winemetal.so:x86_64-unix/winemetal.so
    compare_dlls dxmt "$MG_HOME/bottles/mgdxmt/drive_c/windows" \
      x86_64-windows/winemetal.dll:system32/winemetal.dll i386-windows/winemetal.dll:syswow64/winemetal.dll
    if [[ -e "$rt/wine/lib/wine/x86_64-unix/winemetal.so" ]]; then say "PROBLEM: DXMT leaked into the stock wine/ tree"; else say "ok: stock wine/ has no winemetal.so"; fi
  else
    say "PROBLEM: no runtimes/*/wine-dxmt overlay was built"
  fi
  log=$("$MG" logs --bottle mgdxmt --last 2>/dev/null || true)
  ovr=$(grep -m1 'WINEDLLOVERRIDES=' <<<"$log" || true)
  say "overrides: ${ovr:-not in the log}"
  if [[ "$ovr" == *"n,b"* ]]; then say "PROBLEM: DXMT run has n,b overrides (expected everything builtin)"; else say "ok: no n,b overrides"; fi
  if grep -iE 'loaddll.*winemetal\.dll.*builtin' >/dev/null <<<"$log"; then say "ok: winemetal.dll loaded as builtin"; else say "PROBLEM: winemetal.dll did not load as builtin, so d3d11.dll is probably not DXMT's"; fi
  if grep -iE 'loaddll.*wined3d\.dll' >/dev/null <<<"$log"; then say "PROBLEM: wined3d.dll loaded (Wine's own d3d11)"; else say "ok: wined3d.dll not loaded"; fi
  outcome "Were all lines above 'ok:' (winemetal.dll builtin, wine-dxmt files are DXMT's, no n,b)?"
fi

if $HAS_GPTK && step "D3DMetal overlay" \
  "Builds runtimes/<r>/wine-d3dmetal (an APFS clone of Wine plus your GPTK lib folder; a few seconds, more if the GPTK is on a disk image) and loads d3d12.dll with +loaddll."; then
  probe mgtest d3dmetal d3d12.dll || true
  run ls -ld "$MG_HOME"/runtimes/*/wine-d3dmetal/lib/external/D3DMetal.framework || true
  run ls "$MG_HOME"/runtimes/*/wine-d3dmetal/lib/external/ || true
  outcome "Does runtimes/*/wine-d3dmetal/lib/external/D3DMetal.framework exist, and did d3d12.dll load from the overlay?"
fi

if step "Battle.net install (bottle 'ow', backend d3dmetal)" \
  "Downloads Blizzard's installer (~5 MB) and runs it with wined3d. The installer is interactive: click through it, sign in if asked. It may start Battle.net at the end; quit it to continue."; then
  if $HAS_GPTK; then bn_backend=d3dmetal; elif $HAS_DXMT; then bn_backend=dxmt; else bn_backend=wined3d; fi
  [[ "$bn_backend" == d3dmetal ]] || warn "no GPTK configured: using --backend $bn_backend instead"
  run "$MG" battlenet install --bottle ow --backend "$bn_backend" || true
  outcome "Did the installer download from the battle.net URL and finish?"
fi

ow_round() {
  local label="$1"
  say "Start Overwatch 2 from Battle.net (first time: install it, ~50 GB, from the client)."
  say "Try the Practice Range for a minute: rendering, input, fps (Metal HUD top right if on). Quit Battle.net to continue."
  run "$MG" battlenet run --bottle ow || true
  outcome "Overwatch 2 on $label: did the client render, did the game reach the menu and the Practice Range?"
}

if has_bottle ow; then HAS_OW=true; else HAS_OW=false; fi

if $HAS_OW && $HAS_GPTK && step "Overwatch 2 on D3DMetal (Metal HUD on)" \
  "Sets bottle 'ow' to d3dmetal with the Metal HUD and starts Battle.net. Long: the game download is ~50 GB."; then
  run "$MG" bottle set ow --backend d3dmetal --hud || true
  ow_round "D3DMetal"
fi

if $HAS_OW && $HAS_DXMT && step "Overwatch 2 on DXMT (Metal HUD on)" \
  "Same bottle, backend dxmt. The Battle.net client itself also runs on DXMT now."; then
  run "$MG" bottle set ow --backend dxmt --hud || true
  ow_round "DXMT"
fi

if $HAS_OW && step "Retina mode on" \
  "Turns Retina on for bottle 'ow' (full-resolution rendering: sharper, slower) and starts Battle.net again."; then
  if $HAS_GPTK; then run "$MG" bottle set ow --backend d3dmetal --retina || true; else run "$MG" bottle set ow --retina || true; fi
  ow_round "Retina on"
  run "$MG" bottle set ow --no-retina || true
fi

if $HAS_OW && step "msync off" \
  "Turns msync off for bottle 'ow' and starts Battle.net again. Compare smoothness and CPU use with the earlier runs."; then
  run "$MG" bottle set ow --no-msync || true
  ow_round "msync off"
  run "$MG" bottle set ow --msync || true
fi

if step "Steam install (bottle 'cs2')" \
  "Downloads SteamSetup.exe and runs it silently (/S): no window is expected, it should just finish. Steam then updates itself on first start."; then
  if $HAS_DXMT; then cs_backend=dxmt; elif $HAS_GPTK; then cs_backend=d3dmetal; else cs_backend=wined3d; fi
  run "$MG" steam install --bottle cs2 --backend "$cs_backend" || true
  run ls -l "$MG_HOME/bottles/cs2/drive_c/Program Files (x86)/Steam/steam.exe" || true
  outcome "Did the silent install finish and create steam.exe?"
fi

if [[ -f "$MG_HOME/bottles/cs2/drive_c/Program Files (x86)/Steam/steam.exe" ]] && step "Steam client and CS2 (THROWAWAY ACCOUNT ONLY)" \
  "Starts Steam with -cef-disable-gpu-compositing. On a CI Mac its login window opens but stays black (Steam probe workflow); say whether it does here too. VAC ban risk under Wine is unknown: sign in with a throwaway account only (docs/PLAN.md). Play offline vs bots only; never matchmaking."; then
  read -r -p "Type 'throwaway' to confirm you are using a throwaway Steam account: " confirm || confirm=""
  if [[ "$confirm" == throwaway ]]; then
    run "$MG" steam run --bottle cs2 || true
    outcome "Did the Steam login window render or stay black? If it rendered: store/library visible, and did CS2 reach the menu / an offline bot match?"
  else
    record "SKIPPED (no throwaway account confirmation)"
  fi
fi

say ""
info "checklist done"
# The EXIT trap writes the report.
