#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/ModuleCache
if [[ ! -f MacWindowHide/Resources/AppIcon.icns ]]; then
  xcrun swift -module-cache-path "$PWD/build/ModuleCache" scripts/create_icon.swift "$PWD"
  iconutil --convert icns build/AppIcon.iconset --output MacWindowHide/Resources/AppIcon.icns
fi
python3 scripts/generate_project.py
derived_data="${MWH_DERIVED_DATA_DIR:-/private/tmp/MacWindowHideBuild-$(id -u)}"
xcodebuild -project MacWindowHide.xcodeproj -scheme MacWindowHide -configuration Release \
  -derivedDataPath "$derived_data" -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="${MWH_SIGNING_IDENTITY:--}" build
mkdir -p build/Products
# Keep the actual bundle outside cloud-synced Documents. File Provider may attach
# forbidden Finder metadata again after a cleanup; a symlink avoids that race.
rm -rf build/Products/MacWindowHide.app
ln -s "$derived_data/Build/Products/Release/MacWindowHide.app" build/Products/MacWindowHide.app
codesign --verify --deep --strict "$derived_data/Build/Products/Release/MacWindowHide.app"
echo "App: $PWD/build/Products/MacWindowHide.app"
