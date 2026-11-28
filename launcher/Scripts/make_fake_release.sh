#!/bin/bash
# Builds a fake release (manifest.json + files) for testing `mgx runtime update`, `mgx self-update` and the
# app's update check without GitHub. Serve the folder and point MG_UPDATE_URL at it:
#
#   Scripts/make_fake_release.sh /tmp/release 9.9.9 [MacGaming.app]
#   python3 -m http.server --bind 127.0.0.1 8765 --directory /tmp/release &
#   MG_UPDATE_URL=http://127.0.0.1:8765/ mgx runtime update     # or MG_UPDATE_URL=/tmp/release
#
# The runtime is a stub (wine/bin/wine is a shell script); the "mgx" is a script that prints the version.
# With an app bundle, it is copied, its version set to VERSION, ad-hoc re-signed and zipped (macOS only).
set -euo pipefail

OUT=${1:?usage: make_fake_release.sh OUT VERSION [App.app]}
VERSION=${2:?usage: make_fake_release.sh OUT VERSION [App.app]}
APP=${3:-}
WINE_VERSION=${WINE_VERSION:-26.3.0}
DXMT_VERSION=${DXMT_VERSION:-0.80}

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

# Runtime components, laid out like the CI artifacts (docs/ARTIFACTS.md).
wine_dir="wine-crossover-$WINE_VERSION-wow64"
rt="$work/rt"
mkdir -p "$rt/wine/bin" "$rt/wine/lib/wine/x86_64-windows" "$rt/wine/lib/wine/x86_64-unix" \
         "$rt/dxmt/x86_64-windows" "$rt/dxmt/i386-windows" "$rt/dxmt/x86_64-unix" "$rt/dxvk/x64" "$rt/dxvk/x32"
printf '#!/bin/sh\nexit 0\n' > "$rt/wine/bin/wine"
cp "$rt/wine/bin/wine" "$rt/wine/bin/wineserver"
chmod +x "$rt/wine/bin/wine" "$rt/wine/bin/wineserver"
touch "$rt/wine/lib/libMoltenVK.dylib" "$rt/wine/lib/libgnutls.30.dylib" "$rt/wine/lib/wine/x86_64-windows/d3d11.dll"
for f in d3d11 dxgi d3d10core winemetal; do
  echo "dxmt $f" > "$rt/dxmt/x86_64-windows/$f.dll"
  echo "dxmt32 $f" > "$rt/dxmt/i386-windows/$f.dll"
done
echo unix > "$rt/dxmt/x86_64-unix/winemetal.so"
printf 'DXMT v%s\nBuilt against Wine: %s\n' "$DXMT_VERSION" "$wine_dir" > "$rt/dxmt/VERSION"
for f in d3d9 d3d10core d3d11 dxgi; do echo "dxvk $f" > "$rt/dxvk/x64/$f.dll"; echo "dxvk32 $f" > "$rt/dxvk/x32/$f.dll"; done

wine_file="$wine_dir.tar.xz"
dxmt_file="dxmt-$DXMT_VERSION.tar.xz"
dxvk_file="dxvk-macos-1.10.3-20230507-repack.tar.xz"
tar -cJf "$OUT/$wine_file" -C "$rt" wine
tar -cJf "$OUT/$dxmt_file" -C "$rt" dxmt
tar -cJf "$OUT/$dxvk_file" -C "$rt" dxvk

# "mgx": prints the release version, like `mgx --version`.
mkdir -p "$work/mgx"
printf '#!/bin/sh\necho %s\n' "$VERSION" > "$work/mgx/mgx"
chmod +x "$work/mgx/mgx"
mgx_file="mgx-$VERSION-macos-arm64.tar.gz"
tar -czf "$OUT/$mgx_file" -C "$work/mgx" mgx

app_json=""
if [[ -n "$APP" ]]; then
  app_file="MacGaming-$VERSION.zip"
  cp -R "$APP" "$work/MacGaming.app"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$work/MacGaming.app/Contents/Info.plist"
  codesign --force --sign - "$work/MacGaming.app"
  ditto -c -k --keepParent "$work/MacGaming.app" "$OUT/$app_file"
  app_json="\"app\": {\"file\": \"$app_file\", \"sha256\": \"$(sha "$OUT/$app_file")\"},"
fi

cat > "$OUT/manifest.json" <<JSON
{
  "version": "$VERSION",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  $app_json
  "mgx": {"file": "$mgx_file", "sha256": "$(sha "$OUT/$mgx_file")"},
  "runtime": [
    {"kind": "wine", "file": "$wine_file", "version": "crossover-$WINE_VERSION-wow64", "sha256": "$(sha "$OUT/$wine_file")"},
    {"kind": "dxmt", "file": "$dxmt_file", "version": "$DXMT_VERSION", "sha256": "$(sha "$OUT/$dxmt_file")"},
    {"kind": "dxvk", "file": "$dxvk_file", "version": "1.10.3-20230507-repack", "sha256": "$(sha "$OUT/$dxvk_file")"}
  ]
}
JSON
echo "fake release $VERSION in $OUT"
