#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/Headroom.app/Contents/MacOS
mkdir -p build/Headroom.app/Contents/Resources
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 Sources/*.swift -o build/Headroom.app/Contents/MacOS/Headroom
cp Info.plist build/Headroom.app/Contents/Info.plist
cp Resources/Claude.svg build/Headroom.app/Contents/Resources/Claude.svg
cp LICENSE build/Headroom.app/Contents/Resources/LICENSE.txt
cp THIRD_PARTY_NOTICES.md build/Headroom.app/Contents/Resources/THIRD_PARTY_NOTICES.md
codesign --force --sign - --identifier com.divyanshgolyan.headroom build/Headroom.app
codesign --verify --strict build/Headroom.app
echo "Built $PWD/build/Headroom.app"
