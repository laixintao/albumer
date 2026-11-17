#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -quiet -project Albumer.xcodeproj -scheme Albumer -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
ditto build/DerivedData/Build/Products/Release/Albumer.app build/Albumer.app
codesign --verify --strict build/Albumer.app
printf 'Built %s/build/Albumer.app\n' "$PWD"

