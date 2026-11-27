#!/usr/bin/env bash
# Build the x86_64 LLVM 15 static libraries DXMT's shader compiler (airconv) links into
# winemetal.so. DXMT requires LLVM 15 exactly; this mirrors the configuration in
# docs/DEVELOPMENT.md of 3Shain/dxmt.
#
# The x86_64 tablegen tools run under Rosetta 2 during the build.
#
# Usage: scripts/build-llvm.sh [install-dir]
#   default install dir: $CACHE/llvm-<version>-x86_64
set -euo pipefail

LLVM_VERSION=15.0.7
LLVM_SHA256=8b5fcb24b4128cf04df1b0b9410ce8b1a729cb3c544e6da885d234280dedeac6
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
CACHE="${CACHE:-$HOME/Library/Caches/mac-gaming}"
PREFIX="${1:-$CACHE/llvm-$LLVM_VERSION-x86_64}"
BREW=/opt/homebrew/bin/brew

[[ "$(uname -s)" == Darwin ]] || { echo "must run on macOS" >&2; exit 1; }
[[ -x "$BREW" ]] || { echo "arm64 Homebrew not found at /opt/homebrew" >&2; exit 1; }
arch -x86_64 /usr/bin/true || { echo "Rosetta 2 is not installed" >&2; exit 1; }

if [[ -f "$PREFIX/lib/cmake/llvm/LLVMConfig.cmake" ]]; then
  echo "==> LLVM $LLVM_VERSION already installed in $PREFIX"
  exit 0
fi

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1
missing=()
for f in cmake ninja; do
  "$BREW" list --formula --versions "$f" >/dev/null || missing+=("$f")
done
if (( ${#missing[@]} )); then "$BREW" install --quiet "${missing[@]}"; fi
export PATH="/opt/homebrew/bin:$PATH"

mkdir -p "$WORK" "$CACHE"
TARBALL="$CACHE/llvm-project-$LLVM_VERSION.src.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
  echo "==> Downloading LLVM $LLVM_VERSION sources"
  curl -fL --retry 3 -o "$TARBALL.part" \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$LLVM_SHA256  $TARBALL" | shasum -a 256 -c

SRC="$WORK/llvm-src"
BLD="$WORK/llvm-build"
rm -rf "$SRC" "$BLD" && mkdir -p "$SRC"
tar -xJf "$TARBALL" -C "$SRC" --strip-components=1 \
  "llvm-project-$LLVM_VERSION.src/llvm" "llvm-project-$LLVM_VERSION.src/cmake" \
  "llvm-project-$LLVM_VERSION.src/third-party"

echo "==> Building LLVM $LLVM_VERSION (x86_64, no targets, static)"
cmake -S "$SRC/llvm" -B "$BLD" -G Ninja \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
  -DLLVM_ENABLE_ASSERTIONS=On \
  -DLLVM_ENABLE_ZSTD=Off \
  -DLLVM_ENABLE_ZLIB=Off \
  -DLLVM_ENABLE_LIBXML2=Off \
  -DLLVM_ENABLE_TERMINFO=Off \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD="" \
  -DLLVM_BUILD_TOOLS=Off \
  -DLLVM_INCLUDE_TESTS=Off \
  -DLLVM_INCLUDE_BENCHMARKS=Off \
  -DLLVM_INCLUDE_EXAMPLES=Off \
  -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
cmake --build "$BLD"
rm -rf "$PREFIX"
cmake --install "$BLD"
rm -rf "$SRC" "$BLD"
echo "==> Done: $PREFIX"
