#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -d build/Products/MacWindowHide.app ]] || scripts/build.sh
stage=$(mktemp -d /private/tmp/macwindowhide-dmg.XXXXXX)
trap 'rm -rf "$stage"' EXIT
source_app=$(python3 -c 'from pathlib import Path; print(Path("build/Products/MacWindowHide.app").resolve())')
ditto "$source_app" "$stage/MacWindowHide.app"
xattr -r -d com.apple.FinderInfo "$stage/MacWindowHide.app" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "$stage/MacWindowHide.app" 2>/dev/null || true
ln -s /Applications "$stage/Applications"
cp README.md "$stage/Read Me.md"
cp THIRD_PARTY_NOTICES.md "$stage/Third Party Notices.md"
ditto docs "$stage/docs"
hdiutil create -volname MacWindowHide -srcfolder "$stage" -format UDZO -ov build/Products/MacWindowHide.dmg
shasum -a 256 build/Products/MacWindowHide.dmg > build/Products/SHA256SUMS.txt
echo "Installer: $PWD/build/Products/MacWindowHide.dmg"
