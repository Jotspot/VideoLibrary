#!/usr/bin/env bash
# Packages VideoLibrary.app (built by ./build.sh) for release:
#   VideoLibrary.dmg  the app next to an Applications shortcut to drag it onto
#   VideoLibrary.zip  the same app, zipped
#   SHA256SUMS        checksums for both
# Used by .github/workflows/release.yml; run it locally to try the DMG:
#   ./build.sh && scripts/package.sh && open VideoLibrary.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d VideoLibrary.app ] || { echo "Build first: ./build.sh"; exit 1; }

codesign --force --deep --sign - VideoLibrary.app
codesign --verify VideoLibrary.app

rm -f VideoLibrary.zip VideoLibrary.dmg SHA256SUMS
ditto -c -k --sequesterRsrc --keepParent VideoLibrary.app VideoLibrary.zip

# The DMG window (background graphic, icon positions) is laid out by
# dmgbuild, kept in a private virtual environment in .build/.
if [ ! -x .build/venv/bin/dmgbuild ]; then
  python3 -m venv .build/venv
  .build/venv/bin/pip install --quiet dmgbuild
fi
.build/venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app=VideoLibrary.app -D background_dir=assets/dmg \
  VideoLibrary VideoLibrary.dmg

shasum -a 256 VideoLibrary.dmg VideoLibrary.zip | tee SHA256SUMS
