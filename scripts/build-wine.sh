#!/usr/bin/env bash
# Build CrossOver's Wine tree (WoW64, x86_64 via Rosetta) on an Apple Silicon Mac.
#
# Homebrew no longer installs on x86_64 macOS and publishes no Intel bottles, so build
# tools come from the normal arm64 Homebrew. Their host arch does not matter. The few
# x86_64 libraries Wine links against are built here or fetched as universal binaries,
# then shipped inside the artifact under lib/.
#
# Prereqs (one-time, on the build Mac):
#   softwareupdate --install-rosetta --agree-to-license
#   xcode-select --install          # or full Xcode
#   arm64 Homebrew in /opt/homebrew
#
# Usage: scripts/build-wine.sh <crossover-version>   e.g. 26.3.0
set -euo pipefail

CX_VERSION="${1:?usage: $0 <crossover-version, e.g. 26.3.0>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
CACHE="${CACHE:-$HOME/Library/Caches/mac-gaming}"
DEPS="$WORK/deps"
DIST="$WORK/dist/wine"
JOBS="$(sysctl -n hw.ncpu)"
BREW=/opt/homebrew/bin/brew
MVK_VERSION=1.4.2
MVK_SHA256=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e

[[ "$(uname -s)" == Darwin ]] || { echo "must run on macOS" >&2; exit 1; }
[[ -x "$BREW" ]] || { echo "arm64 Homebrew not found at /opt/homebrew" >&2; exit 1; }
arch -x86_64 /usr/bin/true || { echo "Rosetta 2 is not installed" >&2; exit 1; }

echo "==> Installing missing build tools (arm64 Homebrew)"
# This is the runner owner's personal Homebrew: install what is missing, upgrade nothing.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1
missing=()
for f in bison flex gettext mingw-w64 pkgconf cmake; do
  "$BREW" list --formula --versions "$f" >/dev/null || missing+=("$f")
done
if (( ${#missing[@]} )); then "$BREW" install --quiet "${missing[@]}"; fi

export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=13.0
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

mkdir -p "$WORK" "$CACHE"
TARBALL="$CACHE/crossover-sources-$CX_VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  echo "==> Downloading CrossOver $CX_VERSION sources"
  curl -fL --retry 3 -o "$TARBALL.part" \
    "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz"
  mv "$TARBALL.part" "$TARBALL"
fi
cd "$WORK"
rm -rf src deps && mkdir src deps
tar -xzf "$TARBALL" -C src --strip-components=1

echo "==> Building x86_64 freetype"
cmake -S src/freetype -B obj-freetype -G "Unix Makefiles" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_INSTALL_PREFIX="$DEPS" \
  -DCMAKE_INSTALL_NAME_DIR=@rpath \
  -DBUILD_SHARED_LIBS=ON \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake --build obj-freetype -j"$JOBS"
cmake --install obj-freetype

echo "==> Fetching universal MoltenVK $MVK_VERSION"
MVK_TAR="$CACHE/MoltenVK-macos-$MVK_VERSION.tar"
if [[ ! -f "$MVK_TAR" ]]; then
  curl -fL --retry 3 -o "$MVK_TAR.part" \
    "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MVK_VERSION/MoltenVK-macos.tar"
  mv "$MVK_TAR.part" "$MVK_TAR"
fi
echo "$MVK_SHA256  $MVK_TAR" | shasum -a 256 -c
tar -xf "$MVK_TAR" -C "$DEPS" MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
mv "$DEPS/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$DEPS/lib/"
rm -rf "$DEPS/MoltenVK"

export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CFLAGS="-O3 -march=x86-64-v2 -mtune=generic"   # Rosetta 2 handles up to SSE4.2/AVX2 on macOS 15+
export CROSSCFLAGS="-O3"
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../../"

echo "==> Configuring Wine (WoW64)"
rm -rf obj && mkdir obj && cd obj
arch -x86_64 ../src/wine/configure \
  --prefix="" \
  --disable-tests \
  --enable-archs=i386,x86_64 \
  --with-mingw \
  --with-coreaudio --with-freetype --with-opencl --with-vulkan \
  --with-pthread --with-unwind \
  --without-gnutls --without-gstreamer --without-sdl \
  --without-x --without-wayland --without-alsa --without-pulse --without-oss \
  --without-dbus --without-fontconfig --without-krb5 --without-gssapi \
  --without-sane --without-gphoto --without-v4l2 --without-udev --without-usb \
  --without-capi --without-netapi --without-inotify

echo "==> Building with $JOBS jobs"
arch -x86_64 make -j"$JOBS"

echo "==> Installing to $DIST"
rm -rf "$DIST"
arch -x86_64 make install-lib DESTDIR="$DIST"
mkdir -p "$DIST/lib"
cp -a "$DEPS"/lib/libfreetype*.dylib "$DEPS/lib/libMoltenVK.dylib" "$DIST/lib/"

cd "$WORK/dist"
rm -f wine-crossover-*-wow64.tar.xz
tar -cJf "wine-crossover-$CX_VERSION-wow64.tar.xz" wine
echo "==> Done: $WORK/dist/wine-crossover-$CX_VERSION-wow64.tar.xz"
