#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mount_dir=$(mktemp -d /private/tmp/macwindowhide-verify.XXXXXX)
mwh_attached=0
cleanup() {
  if [[ "$mwh_attached" == 1 ]]; then hdiutil detach "$mount_dir" >/dev/null 2>&1 || true; fi
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil verify build/Products/MacWindowHide.dmg
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" build/Products/MacWindowHide.dmg
mwh_attached=1
codesign --verify --deep --strict "$mount_dir/MacWindowHide.app"
lipo -info "$mount_dir/MacWindowHide.app/Contents/MacOS/MacWindowHide"
[[ -f "$mount_dir/MacWindowHide.app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ ! -e "$mount_dir/MacWindowHide.app/Contents/Resources/Focus" ]]
[[ ! -e "$mount_dir/docs/FOCUS_SETUP.md" ]]
python3 - "$mount_dir/MacWindowHide.app/Contents/Resources/Metadata.appintents/extract.actionsdata" <<'PY'
import json
from pathlib import Path
import sys
metadata = json.loads(Path(sys.argv[1]).read_text())
controls = next(item for item in metadata["enums"] if item["identifier"] == "SwitchID")
assert all(item["identifier"] != "doNotDisturb" for item in controls["cases"]), "Removed control is still exported"
print(f'Shortcuts metadata verified: {len(controls["cases"])} controls, no retired DND control.')
PY
shasum -a 256 -c build/Products/SHA256SUMS.txt
hdiutil detach "$mount_dir"
mwh_attached=0
echo 'Package verified: image, mounted app signature, architectures, notices and checksum.'
