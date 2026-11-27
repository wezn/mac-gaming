#!/usr/bin/env bash
# Build CrossOver's Wine tree (WoW64, x86_64 via Rosetta) on an Apple Silicon Mac.
#
# Prereqs (one-time, on the build Mac):
#   softwareupdate --install-rosetta --agree-to-license
#   xcode-select --install          # or full Xcode
#   # x86_64 Homebrew lives in /usr/local, separate from arm64 brew in /opt/homebrew:
#   arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#
# Usage: scripts/build-wine.sh <crossover-version>   e.g. 26.0.0
set -euo pipefail

CX_VERSION="${1:?usage: $0 <crossover-version, e.g. 26.0.0>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build}"
DIST="$WORK/dist/wine"
JOBS="$(sysctl -n hw.ncpu)"
BREW_X86=/usr/local/bin/brew

[[ "$(uname -s)" == Darwin ]] || { echo "must run on macOS" >&2; exit 1; }
[[ -x "$BREW_X86" ]] || { echo "x86_64 Homebrew not found at /usr/local (see prereqs)" >&2; exit 1; }

echo "==> Installing x86_64 build deps"
arch -x86_64 "$BREW_X86" install --quiet \
  bison gettext mingw-w64 pkgconf freetype gnutls molten-vk sdl2 \
  gstreamer gst-plugins-base

export PATH="/usr/local/opt/bison/bin:/usr/local/bin:$PATH"
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CFLAGS="-O3 -march=x86-64-v2 -mtune=generic"   # Rosetta 2 handles up to SSE4.2/AVX2 on macOS 15+
export CROSSCFLAGS="-O3"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../../ -Wl,-rpath,/usr/local/lib"
export MACOSX_DEPLOYMENT_TARGET=13.0

mkdir -p "$WORK"
cd "$WORK"
TARBALL="crossover-sources-$CX_VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  echo "==> Downloading CrossOver $CX_VERSION sources"
  curl -fL --retry 3 -o "$TARBALL" \
    "https://media.codeweavers.com/pub/crossover/source/$TARBALL"
fi
rm -rf src && mkdir src && tar -xzf "$TARBALL" -C src --strip-components=1

echo "==> Configuring Wine (WoW64)"
rm -rf obj && mkdir obj && cd obj
arch -x86_64 ../src/wine/configure \
  --prefix="" \
  --disable-tests \
  --enable-archs=i386,x86_64 \
  --with-mingw \
  --with-coreaudio --with-freetype --with-gnutls --with-gstreamer \
  --with-opencl --with-opengl --with-vulkan --with-sdl --with-pthread --with-unwind \
  --without-x --without-wayland --without-alsa --without-pulse --without-oss \
  --without-dbus --without-fontconfig --without-krb5 --without-gssapi \
  --without-sane --without-gphoto --without-v4l2 --without-udev --without-usb \
  --without-capi --without-netapi --without-inotify

echo "==> Building with $JOBS jobs"
arch -x86_64 make -j"$JOBS"

echo "==> Installing to $DIST"
rm -rf "$DIST"
arch -x86_64 make install-lib DESTDIR="$DIST"

cd "$WORK/dist"
tar -cJf "wine-crossover-$CX_VERSION-wow64.tar.xz" wine
echo "==> Done: $WORK/dist/wine-crossover-$CX_VERSION-wow64.tar.xz"
