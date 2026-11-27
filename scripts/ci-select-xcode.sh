#!/usr/bin/env bash
# CI helper: select an Xcode 16 that ships the Metal toolchain DXMT compiles its shaders with.
# DXMT's own CI uses Xcode 16.1; Xcode 26 no longer bundles Metal (it is a separate download),
# so prefer 16.1, then the newest 16.x on the runner.
set -euo pipefail
for v in 16.1 16.4 16.3 16.2 16.0; do
  app="/Applications/Xcode_$v.app"
  if [[ -d "$app" ]]; then
    sudo xcode-select -s "$app"
    break
  fi
done
xcode-select -p
xcrun -sdk macosx metal --version
