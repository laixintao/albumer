#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift test
if [[ "${1:-}" == "--ui" ]]; then
  xcodebuild -quiet -project Albumer.xcodeproj -scheme Albumer -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
    -resultBundlePath "build/UI-$(date +%Y%m%d-%H%M%S).xcresult" \
    -only-testing:AlbumerUITests test
fi
