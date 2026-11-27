#!/usr/bin/env bash
# Build DXVK for macOS (Direct3D 9/10/11 -> Vulkan, run on MoltenVK), from Gcenx/DXVK-macOS.
#
# Upstream DXVK 2.x needs Vulkan features MoltenVK lacks, so we use the 1.10.x macOS fork
# (https://github.com/Gcenx/DXVK-macOS, branch 1.10.x), the one Whisky and other macOS Wine
# wrappers ship. It includes the async pipeline-compile patch (DXVK_ASYNC=1).
#
# Produces build/dist/dxvk-macos-<version>.tar.xz:
#   dxvk/x64/{d3d9,d3d10core,d3d11,dxgi}.dll   (64-bit PE)
#   dxvk/x32/{d3d9,d3d10core,d3d11,dxgi}.dll   (32-bit PE)
#   dxvk/LICENSE, dxvk/VERSION, dxvk/dxvk.conf
# See docs/ARTIFACTS.md for how to install it.
#
# Usage: scripts/build-dxvk.sh
set -euo pipefail

DXVK_TAG=v1.10.3-20230507-repack
DXVK_COMMIT=8f1e28deed3ad30802f7e1bdff428ec14e6e7817
DXVK_VERSION="${DXVK_TAG#v}"
MESON_VERSION=1.10.0
NINJA_VERSION=1.13.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
BREW=/opt/homebrew/bin/brew
OUT="$WORK/dist"

[[ "$(uname -s)" == Darwin ]] || { echo "must run on macOS" >&2; exit 1; }
[[ -x "$BREW" ]] || { echo "arm64 Homebrew not found at /opt/homebrew" >&2; exit 1; }

echo "==> Installing missing build tools (arm64 Homebrew)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1
missing=()
for f in mingw-w64 glslang; do
  "$BREW" list --formula --versions "$f" >/dev/null || missing+=("$f")
done
if (( ${#missing[@]} )); then "$BREW" install --quiet "${missing[@]}"; fi

mkdir -p "$WORK" "$OUT"
VENV="$WORK/venv-meson"
if [[ ! -x "$VENV/bin/meson" ]] || [[ "$("$VENV/bin/meson" --version)" != "$MESON_VERSION" ]]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "meson==$MESON_VERSION" "ninja==$NINJA_VERSION"
fi
export PATH="$VENV/bin:/opt/homebrew/bin:$PATH"

echo "==> Fetching DXVK-macOS $DXVK_TAG"
SRC="$WORK/dxvk-src"
rm -rf "$SRC"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$DXVK_TAG" \
  https://github.com/Gcenx/DXVK-macOS.git "$SRC"
got="$(git -C "$SRC" rev-parse HEAD)"
[[ "$got" == "$DXVK_COMMIT" ]] || { echo "DXVK $DXVK_TAG is $got, expected $DXVK_COMMIT" >&2; exit 1; }

PKG="$WORK/dxvk-pkg/dxvk"
rm -rf "$WORK/dxvk-pkg" && mkdir -p "$PKG"
cd "$SRC"
for bits in 64 32; do
  echo "==> Building DXVK win$bits"
  meson setup "build$bits" --cross-file "build-win$bits.txt" --buildtype release --strip \
    --prefix "$WORK/dxvk-install" --bindir "x$bits" --libdir "x$bits" -Dbuild_id=false
  meson compile -C "build$bits"
  meson install -C "build$bits" --quiet
  mkdir -p "$PKG/x$bits"
  cp "$WORK/dxvk-install/x$bits/"*.dll "$PKG/x$bits/"
  for d in d3d9 d3d10core d3d11 dxgi; do
    [[ -f "$PKG/x$bits/$d.dll" ]] || { echo "missing x$bits/$d.dll" >&2; exit 1; }
  done
done

echo "==> Packaging"
cp LICENSE "$PKG/LICENSE"
cp dxvk.conf "$PKG/dxvk.conf"
printf 'DXVK-macOS %s (%s)\nhttps://github.com/Gcenx/DXVK-macOS\n' "$DXVK_TAG" "$DXVK_COMMIT" > "$PKG/VERSION"
(cd "$PKG" && find . -type f | sort && file x64/*.dll x32/*.dll)

rm -f "$OUT"/dxvk-macos-*.tar.xz
tar -cJf "$OUT/dxvk-macos-$DXVK_VERSION.tar.xz" -C "$WORK/dxvk-pkg" dxvk
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "name=dxvk-macos-$DXVK_VERSION" >> "$GITHUB_OUTPUT"
echo "==> Done: $OUT/dxvk-macos-$DXVK_VERSION.tar.xz"
