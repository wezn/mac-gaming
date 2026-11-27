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
#
# WINE_DEVEL=1 also writes wine-crossover-<v>-wow64-devel.tar.xz: headers, build tools
# (winebuild, winegcc, ...) and PE import libraries. Overlay it on the runtime tarball to
# build components against this Wine, e.g. DXMT's winemetal (see scripts/build-dxmt.sh).
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
# Install only what is missing and upgrade nothing, so a local Homebrew is left as it was.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1
missing=()
for f in autoconf bison flex gettext mingw-w64 pkgconf cmake; do
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

# GnuTLS is what Wine's schannel (secur32) and bcrypt use for TLS and crypto. Without it,
# every HTTPS request made through WinHTTP/WinINet fails, and Battle.net and Steam report
# "no internet". CrossOver's sources bundle GMP, nettle and GnuTLS; build them as x86_64
# dylibs and ship them in lib/. Wine dlopens libgnutls.30.dylib by name, and mg puts lib/
# on DYLD_FALLBACK_LIBRARY_PATH.
echo "==> Building x86_64 GMP, nettle and GnuTLS"
TLS_HOST=x86_64-apple-darwin
(cd "$WORK/src/gnutls/gmp" && arch -x86_64 ./configure --host=$TLS_HOST --build=$TLS_HOST --prefix="$DEPS" \
   --enable-shared --disable-static --disable-assembly \
 && arch -x86_64 make -j"$JOBS" && arch -x86_64 make install)
(cd "$WORK/src/gnutls/nettle" && autoconf && autoheader \
 && arch -x86_64 ./configure --host=$TLS_HOST --build=$TLS_HOST --prefix="$DEPS" --libdir="$DEPS/lib" \
   --enable-shared --disable-static --disable-documentation --disable-openssl \
 && arch -x86_64 make -j"$JOBS" && arch -x86_64 make install)
(cd "$WORK/src/gnutls/gnutls" && arch -x86_64 ./configure --host=$TLS_HOST --build=$TLS_HOST --prefix="$DEPS" \
   GMP_CFLAGS="-I$DEPS/include" GMP_LIBS="-L$DEPS/lib -lgmp" \
   --enable-shared --disable-static --disable-doc --disable-manpages --disable-tools \
   --disable-cxx --disable-tests --disable-nls --disable-libdane \
   --without-p11-kit --without-tpm --without-tpm2 --without-idn \
   --without-zlib --without-brotli --without-zstd \
   --with-included-libtasn1 --with-included-unistring \
 && arch -x86_64 make -j"$JOBS" && arch -x86_64 make install)
# Make the libraries relocatable: ids @rpath/<name>, links between them @loader_path/<name>.
TLS_LIBS=(libgmp.10.dylib libnettle.8.dylib libhogweed.6.dylib libgnutls.30.dylib)
for lib in "${TLS_LIBS[@]}"; do
  f="$DEPS/lib/$lib"
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
  install_name_tool -id "@rpath/$lib" "$f"
  for dep in $(otool -L "$f" | awk -v p="$DEPS/" 'NR>1 && index($1, p) == 1 {print $1}'); do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
  done
  codesign -f -s - "$f"
done
for lib in "${TLS_LIBS[@]}"; do
  if otool -L "$DEPS/lib/$lib" | tail -n +2 | grep -F "$WORK"; then
    echo "$lib still references the build directory" >&2; exit 1
  fi
done

echo "==> Configuring Wine (WoW64)"
rm -rf obj && mkdir obj && cd obj
# tools/sfnt2fon runs during the build and resolves freetype through @loader_path/../../, which is obj/.
ln -s ../deps/lib/libfreetype.6.dylib .
arch -x86_64 ../src/wine/configure \
  --prefix="" \
  --disable-tests \
  --enable-archs=i386,x86_64 \
  --with-mingw \
  --with-coreaudio --with-freetype --with-opencl --with-vulkan \
  --with-pthread --with-unwind \
  --with-gnutls --without-gstreamer --without-sdl \
  --without-x --without-wayland --without-alsa --without-pulse --without-oss \
  --without-dbus --without-fontconfig --without-krb5 --without-gssapi \
  --without-sane --without-gphoto --without-v4l2 --without-udev --without-usb \
  --without-capi --without-netapi --without-inotify

grep -q '^#define SONAME_LIBGNUTLS ' include/config.h \
  || { echo "Wine was configured without GnuTLS: HTTPS inside Wine would not work" >&2; exit 1; }

echo "==> Building with $JOBS jobs"
arch -x86_64 make -j"$JOBS"

echo "==> Installing to $DIST"
rm -rf "$DIST"
arch -x86_64 make install-lib DESTDIR="$DIST"
mkdir -p "$DIST/lib"
cp -a "$DEPS"/lib/libfreetype*.dylib "$DEPS/lib/libMoltenVK.dylib" "$DIST/lib/"
for lib in "${TLS_LIBS[@]}"; do cp "$DEPS/lib/$lib" "$DIST/lib/"; done
if [[ "${WINE_DEVEL:-0}" == 1 ]]; then
  echo "==> Installing development files to $WORK/dist/wine-devel"
  rm -rf "$WORK/dist/wine-devel"
  arch -x86_64 make install-dev DESTDIR="$WORK/dist/wine-devel/wine"
fi

cd "$WORK/dist"
rm -f wine-crossover-*-wow64.tar.xz wine-crossover-*-wow64-devel.tar.xz
tar -cJf "wine-crossover-$CX_VERSION-wow64.tar.xz" wine
if [[ "${WINE_DEVEL:-0}" == 1 ]]; then
  tar -cJf "wine-crossover-$CX_VERSION-wow64-devel.tar.xz" -C wine-devel wine
fi
echo "==> Done: $WORK/dist/wine-crossover-$CX_VERSION-wow64.tar.xz"
