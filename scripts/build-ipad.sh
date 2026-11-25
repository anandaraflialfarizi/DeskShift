#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project iPad/PadBridgeiPad.xcodeproj -scheme PadBridgeiPad \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ipad CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build -quiet
print "Build simulator: $PWD/.build/ipad/Build/Products/Debug-iphonesimulator/PadBridge.app"
print 'Untuk iPad fisik, buka project iPad/PadBridgeiPad.xcodeproj di Xcode dan pilih Signing Team milikmu.'
