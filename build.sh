#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/Headroom.app/Contents/MacOS
mkdir -p build/Headroom.app/Contents/Resources
read -r -a architectures <<< "${ARCHS:-arm64 x86_64}"
binaries=()
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
    binary="build/Headroom-$architecture"
    swiftc -O -swift-version 5 -target "$architecture-apple-macosx13.0" Sources/*.swift -o "$binary"
    binaries+=("$binary")
done
if [ "${#binaries[@]}" -eq 1 ]; then
    cp "${binaries[0]}" build/Headroom.app/Contents/MacOS/Headroom
else
    lipo -create "${binaries[@]}" -output build/Headroom.app/Contents/MacOS/Headroom
fi
cp Info.plist build/Headroom.app/Contents/Info.plist
cp Resources/Claude.svg build/Headroom.app/Contents/Resources/Claude.svg
cp LICENSE build/Headroom.app/Contents/Resources/LICENSE.txt
cp THIRD_PARTY_NOTICES.md build/Headroom.app/Contents/Resources/THIRD_PARTY_NOTICES.md
codesign --force --sign - --identifier com.divyanshgolyan.headroom build/Headroom.app
codesign --verify --strict build/Headroom.app
echo "Built $PWD/build/Headroom.app"
