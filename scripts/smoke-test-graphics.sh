#!/usr/bin/env bash
# Install DXMT and DXVK into throwaway Wine prefixes, the way docs/ARTIFACTS.md describes,
# and run tests/d3d11-smoke.c (64- and 32-bit) under each.
#
# A backend whose DLLs fail to load fails the script. A D3D11 device that cannot be
# created (e.g. a Metal feature missing on a CI virtual GPU) is reported as a warning
# unless STRICT_DEVICE=1.
#
# Usage: scripts/smoke-test-graphics.sh <wine.tar.xz> <dxmt.tar.xz> <dxvk-macos.tar.xz>
set -euo pipefail

WINE_TAR="$(cd "$(dirname "${1:?usage}")" && pwd)/$(basename "$1")"
DXMT_TAR="$(cd "$(dirname "${2:?usage}")" && pwd)/$(basename "$2")"
DXVK_TAR="$(cd "$(dirname "${3:?usage}")" && pwd)/$(basename "$3")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
T="$WORK/smoke"
BREW=/opt/homebrew/bin/brew
STRICT_DEVICE="${STRICT_DEVICE:-0}"

[[ "$(uname -s)" == Darwin ]] || { echo "must run on macOS" >&2; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1
"$BREW" list --formula --versions mingw-w64 >/dev/null || "$BREW" install --quiet mingw-w64
export PATH="/opt/homebrew/bin:$PATH"

rm -rf "$T" && mkdir -p "$T"
echo "==> Extracting artifacts"
mkdir "$T/wine-stock" "$T/wine-dxmt" "$T/pkg"
tar -xJf "$WINE_TAR" -C "$T/wine-stock" --strip-components=1
tar -xJf "$WINE_TAR" -C "$T/wine-dxmt" --strip-components=1
tar -xJf "$DXMT_TAR" -C "$T/pkg"
tar -xJf "$DXVK_TAR" -C "$T/pkg"

echo "==> Checking winemac.drv exports what DXMT looks up"
if nm -gU "$T/wine-stock/lib/wine/x86_64-unix/winemac.so" | grep -E ' _(macdrv_functions|macdrv_view_create_metal_view|get_win_data)$'; then
  :
else
  echo "::warning::winemac.so exports neither macdrv_functions nor the macdrv_* Metal view symbols; DXMT cannot attach to windows (swapchains will fail)"
fi

echo "==> Building the test program"
x86_64-w64-mingw32-gcc -O2 -Wall -o "$T/d3d11-smoke64.exe" "$ROOT/tests/d3d11-smoke.c"
i686-w64-mingw32-gcc -O2 -Wall -o "$T/d3d11-smoke32.exe" "$ROOT/tests/d3d11-smoke.c"

failures=0
warnings=0
run() { # run <label> <wine-dir> <prefix> <exe> <backend> [ENV=...]
  local label="$1" wine="$2" prefix="$3" exe="$4" backend="$5"; shift 5
  local log="$T/$label.log" rc=0
  echo "==> [$label] $exe"
  env WINEPREFIX="$prefix" WINEDEBUG="${WINEDEBUG:--all}" "$@" \
    "$wine/bin/wine" "$exe" "$backend" >"$log" 2>&1 || rc=$?
  cat "$log"
  case "$rc" in
    0) ;;
    3) if [[ "$STRICT_DEVICE" == 1 ]]; then failures=$((failures + 1)); else
         warnings=$((warnings + 1))
         echo "::warning::[$label] DLLs loaded but D3D11CreateDevice failed (see log)"
       fi ;;
    *) failures=$((failures + 1)); echo "::error::[$label] exit code $rc" ;;
  esac
  if [[ "$backend" == dxvk && "$rc" != 2 ]] && ! grep -q 'DXVK: v1\.10' "$log"; then
    failures=$((failures + 1)); echo "::error::[$label] no DXVK banner in the log, so DXVK was not loaded"
  fi
}

boot() { # boot <wine-dir> <prefix>
  echo "==> wineboot $2"
  WINEPREFIX="$2" WINEDEBUG=-all "$1/bin/wine" wineboot -i
  WINEPREFIX="$2" "$1/bin/wineserver" -w
}

# --- DXMT: builtin-marked DLLs replace Wine's own, winemetal.so goes next to the other unixlibs.
D="$T/pkg/dxmt"
for a in x86_64-windows i386-windows; do cp "$D/$a/"*.dll "$T/wine-dxmt/lib/wine/$a/"; done
cp "$D/x86_64-unix/winemetal.so" "$T/wine-dxmt/lib/wine/x86_64-unix/"
boot "$T/wine-dxmt" "$T/pfx-dxmt"
cp "$D/x86_64-windows/winemetal.dll" "$T/pfx-dxmt/drive_c/windows/system32/"
cp "$D/i386-windows/winemetal.dll" "$T/pfx-dxmt/drive_c/windows/syswow64/"
run dxmt-x64 "$T/wine-dxmt" "$T/pfx-dxmt" "$T/d3d11-smoke64.exe" dxmt DXMT_LOG_LEVEL=info
run dxmt-x86 "$T/wine-dxmt" "$T/pfx-dxmt" "$T/d3d11-smoke32.exe" dxmt DXMT_LOG_LEVEL=info
WINEPREFIX="$T/pfx-dxmt" "$T/wine-dxmt/bin/wineserver" -k || true

# --- DXVK: native DLLs in the prefix plus n,b overrides, on stock Wine (winevulkan -> MoltenVK).
V="$T/pkg/dxvk"
boot "$T/wine-stock" "$T/pfx-dxvk"
cp "$V/x64/"*.dll "$T/pfx-dxvk/drive_c/windows/system32/"
cp "$V/x32/"*.dll "$T/pfx-dxvk/drive_c/windows/syswow64/"
OVR="dxgi,d3d9,d3d10core,d3d11=n,b"
run dxvk-x64 "$T/wine-stock" "$T/pfx-dxvk" "$T/d3d11-smoke64.exe" dxvk WINEDLLOVERRIDES="$OVR" DXVK_LOG_LEVEL=info
run dxvk-x86 "$T/wine-stock" "$T/pfx-dxvk" "$T/d3d11-smoke32.exe" dxvk WINEDLLOVERRIDES="$OVR" DXVK_LOG_LEVEL=info
WINEPREFIX="$T/pfx-dxvk" "$T/wine-stock/bin/wineserver" -k || true

echo "==> Smoke test: $failures failure(s), $warnings warning(s)"
(( failures == 0 ))
