#!/usr/bin/env bash
# Build DXMT (Direct3D 10/11 -> Metal, https://github.com/3Shain/dxmt) against our Wine.
#
# Produces build/dist/dxmt-<version>.tar.xz:
#   dxmt/x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll   (64-bit PE, Wine builtin-marked)
#   dxmt/i386-windows/{d3d11,dxgi,d3d10core,winemetal}.dll     (32-bit PE, Wine builtin-marked)
#   dxmt/x86_64-unix/winemetal.so                              (x86_64 Mach-O unixlib)
#   dxmt/LICENSE, dxmt/VERSION, dxmt/dxmt.conf
# See docs/ARTIFACTS.md for how to install it.
#
# Follows DXMT's docs/DEVELOPMENT.md "Cross Build" (meson + llvm-mingw + LLVM 15 + Xcode
# Metal toolchain), using -Dwine_install_path like DXMT's own CI ("clang-release" jobs).
#
# Usage: scripts/build-dxmt.sh <wine-dir>
#   <wine-dir>: our Wine runtime tree with the -devel tarball extracted over it, i.e. it has
#   bin/winebuild, lib/wine/{x86_64,i386}-windows/lib{winecrt0,ntdll,dbghelp}.a and
#   lib/wine/x86_64-unix/{ntdll,winemac}.so. Build it with WINE_DEVEL=1 scripts/build-wine.sh.
# Env: LLVM_PREFIX (default: $CACHE/llvm-15.0.7-x86_64, built by scripts/build-llvm.sh if absent)
#      WINE_LABEL  (recorded in dxmt/VERSION, e.g. "wine-crossover-26.3.0-wow64")
set -euo pipefail

DXMT_TAG=v0.80
DXMT_COMMIT=589adb780354b461645b29999cefaf533594ee99
DXMT_VERSION="${DXMT_TAG#v}"
MESON_VERSION=1.10.0
NINJA_VERSION=1.13.0
# Windows cross toolchain: the llvm-mingw release DXMT's own CI uses. Homebrew's mingw-w64
# GCC moves faster than DXMT does (its newer libstdc++ breaks v0.80 on missing includes).
LLVM_MINGW_VERSION=20251216
LLVM_MINGW_SHA256=38bb5e48ec3e0ce95fb901f4efff0bd6ffa966d1b32539a6510af816a959d160

WINE_DIR="$(cd "${1:?usage: $0 <wine-dir>}" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
CACHE="${CACHE:-$HOME/Library/Caches/mac-gaming}"
LLVM_PREFIX="${LLVM_PREFIX:-$CACHE/llvm-15.0.7-x86_64}"
OUT="$WORK/dist"

[[ "$(uname -s)" == Darwin ]] || { echo "must run on macOS" >&2; exit 1; }
arch -x86_64 /usr/bin/true || { echo "Rosetta 2 is not installed (winebuild is x86_64)" >&2; exit 1; }
for f in bin/winebuild \
         lib/wine/x86_64-windows/libwinecrt0.a lib/wine/x86_64-windows/libntdll.a \
         lib/wine/i386-windows/libwinecrt0.a lib/wine/i386-windows/libntdll.a \
         lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-unix/winemac.so; do
  [[ -e "$WINE_DIR/$f" ]] || { echo "missing $WINE_DIR/$f (extract the -devel tarball over the runtime tree)" >&2; exit 1; }
done
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
  || { echo "Metal toolchain not found; select an Xcode 16 that ships it (xcode-select -s)" >&2; exit 1; }

mkdir -p "$WORK" "$CACHE" "$OUT"
LLVM_MINGW="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
if [[ ! -x "$WORK/toolchains/$LLVM_MINGW/bin/x86_64-w64-mingw32-g++" ]]; then
  echo "==> Fetching $LLVM_MINGW"
  if [[ ! -f "$CACHE/$LLVM_MINGW.tar.xz" ]]; then
    curl -fL --retry 3 -o "$CACHE/$LLVM_MINGW.tar.xz.part" \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW.tar.xz"
    mv "$CACHE/$LLVM_MINGW.tar.xz.part" "$CACHE/$LLVM_MINGW.tar.xz"
  fi
  echo "$LLVM_MINGW_SHA256  $CACHE/$LLVM_MINGW.tar.xz" | shasum -a 256 -c
  rm -rf "$WORK/toolchains/$LLVM_MINGW" && mkdir -p "$WORK/toolchains"
  tar -xJf "$CACHE/$LLVM_MINGW.tar.xz" -C "$WORK/toolchains"
fi
VENV="$WORK/venv-meson"
if [[ ! -x "$VENV/bin/meson" ]] || [[ "$("$VENV/bin/meson" --version)" != "$MESON_VERSION" ]]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "meson==$MESON_VERSION" "ninja==$NINJA_VERSION"
fi
export PATH="$WORK/toolchains/$LLVM_MINGW/bin:$VENV/bin:/opt/homebrew/bin:$PATH"
x86_64-w64-mingw32-g++ --version | head -1

[[ -f "$LLVM_PREFIX/lib/cmake/llvm/LLVMConfig.cmake" ]] || "$ROOT/scripts/build-llvm.sh" "$LLVM_PREFIX"

echo "==> Fetching DXMT $DXMT_TAG"
SRC="$WORK/dxmt-src"
rm -rf "$SRC"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$DXMT_TAG" \
  --recurse-submodules --shallow-submodules https://github.com/3Shain/dxmt.git "$SRC"
got="$(git -C "$SRC" rev-parse HEAD)"
[[ "$got" == "$DXMT_COMMIT" ]] || { echo "DXMT $DXMT_TAG is $got, expected $DXMT_COMMIT" >&2; exit 1; }

cd "$SRC"
echo "==> Building DXMT x86_64 (PE DLLs + winemetal.so)"
meson setup build64 --cross-file build-win64.txt --buildtype release --strip \
  --prefix "$WORK/dxmt-install" \
  -Dnative_llvm_path="$LLVM_PREFIX" -Dwine_install_path="$WINE_DIR"
meson compile -C build64
meson install -C build64 --quiet

echo "==> Building DXMT i386 (PE DLLs)"
meson setup build32 --cross-file build-win32.txt --buildtype release --strip \
  --prefix "$WORK/dxmt-install" \
  -Dwine_install_path="$WINE_DIR"
meson compile -C build32
meson install -C build32 --quiet

echo "==> Packaging"
PKG="$WORK/dxmt-pkg/dxmt"
rm -rf "$WORK/dxmt-pkg" && mkdir -p "$PKG"/{x86_64-windows,i386-windows,x86_64-unix}
for a in x86_64-windows i386-windows; do
  cp "$WORK/dxmt-install/$a/"*.dll "$PKG/$a/"
  for d in d3d11 dxgi d3d10core winemetal; do
    [[ -f "$PKG/$a/$d.dll" ]] || { echo "missing $a/$d.dll" >&2; exit 1; }
  done
done
cp "$WORK/dxmt-install/x86_64-unix/winemetal.so" "$PKG/x86_64-unix/"
file "$PKG/x86_64-unix/winemetal.so" | grep -q 'x86_64' || { echo "winemetal.so is not x86_64" >&2; exit 1; }
cp LICENSE "$PKG/LICENSE"
cp dxmt.conf "$PKG/dxmt.conf"
printf 'DXMT %s (%s)\nhttps://github.com/3Shain/dxmt\nBuilt against Wine: %s\n' \
  "$DXMT_TAG" "$DXMT_COMMIT" "${WINE_LABEL:-$("$WINE_DIR/bin/winebuild" --version 2>/dev/null | head -1 || echo unknown)}" \
  > "$PKG/VERSION"
(cd "$PKG" && find . -type f | sort && file x86_64-windows/*.dll i386-windows/*.dll x86_64-unix/*.so)

rm -f "$OUT"/dxmt-*.tar.xz
tar -cJf "$OUT/dxmt-$DXMT_VERSION.tar.xz" -C "$WORK/dxmt-pkg" dxmt
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "name=dxmt-$DXMT_VERSION" >> "$GITHUB_OUTPUT"
echo "==> Done: $OUT/dxmt-$DXMT_VERSION.tar.xz"
