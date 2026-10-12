#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
staging=$(mktemp -d "$PWD/build/dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto build/Headroom.app "$staging/Headroom.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Headroom -srcfolder "$staging" -ov -format UDZO build/Headroom.dmg
ditto -c -k --sequesterRsrc --keepParent build/Headroom.app build/Headroom.zip
cd build
shasum -a 256 Headroom.dmg Headroom.zip > SHA256SUMS
echo "Release files: build/Headroom.dmg, build/Headroom.zip, build/SHA256SUMS"
