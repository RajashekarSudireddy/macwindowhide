#!/usr/bin/env python3
"""Check the real Quit path with empty, isolated app data and no switch mutations."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
executable = root / "build/Products/MacWindowHide.app/Contents/MacOS/MacWindowHide"
with tempfile.TemporaryDirectory(prefix="MacWindowHide-Quit-", dir="/private/tmp") as directory:
    environment = dict(os.environ, MACWINDOWHIDE_DATA_DIR=directory)
    try:
        result = subprocess.run(
            [str(executable), "--quit-smoke-test"],
            env=environment, capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        sys.exit("FAIL: Quit left the isolated app running for more than 10 seconds.")
    if result.returncode != 0:
        sys.exit(f"FAIL: Quit exited with status {result.returncode}.\n{result.stderr}")
print("PASS: Quit exited normally through the app lifecycle.")
