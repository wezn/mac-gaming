#!/bin/bash
# Builds the SwiftUI app and wraps it into MacGaming.app (macOS only).
#
#   Scripts/make_app.sh            # release build → build/MacGaming.app
#   CONFIG=debug OUT=/tmp Scripts/make_app.sh
#
# The bundle is ad-hoc signed, which is enough to run it on the Mac that built it or after
# removing the quarantine flag (xattr -dr com.apple.quarantine MacGaming.app).
#
# TODO(release): sign with the owner's Developer ID and notarize, e.g.
#   codesign --force --options runtime --timestamp --sign "Developer ID Application: …" MacGaming.app
#   ditto -c -k --keepParent MacGaming.app MacGaming.zip
#   xcrun notarytool submit MacGaming.zip --keychain-profile <profile> --wait
#   xcrun stapler staple MacGaming.app
# The hardened runtime may need entitlements for spawning Wine (com.apple.security.cs.disable-library-validation
# is not needed by the app itself: Wine runs as a separate process). Not done here because it needs the
# owner's certificate and Apple ID; CI must never hold those secrets for pull requests.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
OUT=${OUT:-build}
APP="$OUT/MacGaming.app"
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/MGCore/Paths.swift)
BUILD=${BUILD_NUMBER:-1}

swift build -c "$CONFIG" --product MacGamingApp
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacGamingApp" "$APP/Contents/MacOS/MacGaming"
# Licenses of everything the app and its runtimes ship (Acknowledgements window, `mgx licenses`).
cp ../THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

ICON_KEY=""
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
if swift Scripts/render_icon.swift ../assets/icon.svg "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "warning: could not build the app icon; continuing without one" >&2
fi
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MacGaming</string>
  <key>CFBundleIdentifier</key><string>io.github.wezn.mac-gaming</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Mac Gaming</string>
  <key>CFBundleDisplayName</key><string>Mac Gaming</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  ${ICON_KEY}
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# Ad-hoc signature (no identity). See the TODO above for Developer ID signing.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($VERSION)"
