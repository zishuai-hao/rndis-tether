"""Reproduce moving a running .app after Foundation cached its old resource URL."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="resource-move-", dir=binary.parent) as temporary:
    root = Path(temporary)
    original = root / "Original App.app"
    moved = root / "Moved App.app"
    executable = original / "Contents/MacOS/ResourcePathProbe"
    resources = original / "Contents/Resources"
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(binary, executable)
    (original / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "test.rndis-tether.resource-move",
        "CFBundleExecutable": "ResourcePathProbe",
        "CFBundlePackageType": "APPL",
    }))
    helper = resources / "rndis-tether-gui-helper"
    helper.write_text('#!/bin/sh\nprintf "probe-ok\\n"\n')
    helper.chmod(0o755)
    process = subprocess.Popen(
        [str(executable), str(moved / "Contents/Resources")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert process.stdout.readline() == "ready\n", "Probe did not initialize"
        shutil.move(original, moved)
        output, error = process.communicate("\n", timeout=10)
        print(output, end="")
        assert process.returncode == 0, error
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
