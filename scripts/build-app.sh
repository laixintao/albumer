#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -quiet -project Albumer.xcodeproj -scheme Albumer -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/ReleaseDerivedData clean build
stage=$(mktemp -d build/release-stage.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto build/ReleaseDerivedData/Build/Products/Release/Albumer.app "$stage/Albumer.app"
# Linker debug-map symbols also contain absolute object-file paths, independently of Swift prefix maps.
xcrun strip -S -x "$stage/Albumer.app/Contents/MacOS/Albumer"
codesign --force --sign - --options runtime "$stage/Albumer.app"
codesign --verify --strict "$stage/Albumer.app"
python3 scripts/audit-release.py --app "$stage/Albumer.app"
# Replace the generated bundle instead of merging deleted resources into an old build.
rm -rf build/Albumer.app
mv "$stage/Albumer.app" build/Albumer.app
codesign --verify --strict build/Albumer.app
printf 'Built %s/build/Albumer.app\n' "$PWD"

