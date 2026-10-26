#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/generate_project.py
xcodebuild -project MacWindowHide.xcodeproj -scheme MacWindowHide -configuration Debug \
  -derivedDataPath "${MWH_TEST_DERIVED_DATA_DIR:-/private/tmp/MacWindowHideTests-$(id -u)}" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- test "$@"
