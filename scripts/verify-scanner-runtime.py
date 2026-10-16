#!/usr/bin/env python3
"""Check scanner dependencies, then scan with Homebrew and build paths denied."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile


def verify_links(root):
    root = root.resolve()
    manifest = json.loads((root / "manifest.json").read_text())
    for package in manifest["packages"]:
        archive = root / "share/sources" / package["url"].split("/")[-1]
        if hashlib.sha256(archive.read_bytes()).hexdigest() != package["sha256"]:
            raise RuntimeError("Missing or mismatched corresponding source: " + package["name"])
        notices = root / "share/licenses" / package["name"]
        if not notices.is_dir() or not any(notices.iterdir()):
            raise RuntimeError("Missing license notices: " + package["name"])
    for name in ("REBUILD.md", "build-scanner-runtime.py", "scanner-runtime.lock.json"):
        if not (root / "share/sources" / name).is_file():
            raise RuntimeError("Missing source build instructions: " + name)
    maximum = tuple(map(int, manifest["deployment_target"].split(".")))
    files = [root / "bin/scanimage"]
    files += [p for p in (root / "lib").rglob("*") if p.is_file() and not p.is_symlink()]
    for path in (root / "lib").rglob("*"):
        if path.is_symlink():
            path.resolve(strict=True).relative_to(root)
    for path in files:
        ids = subprocess.check_output(["otool", "-D", str(path)], text=True).splitlines()[1:]
        dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (compatibility version", 1)[0]
            if dependency in ids or dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if not dependency.startswith("@loader_path/"):
                raise RuntimeError(f"External dependency in {path.name}: {dependency}")
            target = path.parent / dependency.removeprefix("@loader_path/")
            target.resolve(strict=True).relative_to(root)
        commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
        minimum = re.search(r"\bminos (\d+\.\d+)", commands)
        if minimum is None or tuple(map(int, minimum[1].split("."))) > maximum:
            raise RuntimeError("Incompatible macOS deployment target: " + path.name)
        subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True, capture_output=True)
    print(f"Verified {len(files)} bundled Mach-O files: relative dependencies, macOS {manifest['deployment_target']}, valid signatures")


def smoke_test(root):
    with tempfile.TemporaryDirectory(prefix="SaneScan Portable Test ") as directory:
        temporary = Path(directory)
        moved = temporary / "Moved App With Spaces.app/Contents/Resources/ScannerRuntime"
        shutil.copytree(root, moved, symlinks=True)
        config = temporary / "test-configuration"
        config.mkdir()
        (config / "dll.conf").write_text("test\n")
        shutil.copy2(moved / "etc/sane.d/test.conf", config / "test.conf")
        environment = {"PATH": "/usr/bin:/bin", "HOME": directory, "TMPDIR": directory,
                       "LC_ALL": "C", "SANE_CONFIG_DIR": str(config),
                       "LD_LIBRARY_PATH": str(moved / "lib/sane")}
        denied = ["/opt/homebrew", "/usr/local", str(root.resolve()),
                  str(Path(__file__).resolve().parent.parent / "build/native"), "/sanescan-runtime"]
        profile = "(version 1)(allow default)" + "".join(
            "(deny file-read* (subpath " + json.dumps(path) + "))" for path in denied)
        prefix = ["/usr/bin/sandbox-exec", "-p", profile, str(moved / "bin/scanimage"), "-d", "test:0"]
        options = subprocess.run(prefix + ["-A"], env=environment, capture_output=True, text=True, check=True)
        if "--resolution" not in options.stdout:
            raise RuntimeError("The relocated scanner could not query its test backend")
        output = temporary / "scan.png"
        subprocess.run(prefix + ["--resolution", "75", "--mode", "Gray", "--source", "Flatbed",
            "-l", "2", "-t", "3", "-x", "30", "-y", "40", "--format=png", "-o", str(output)],
            env=environment, capture_output=True, text=True, check=True)
        data = output.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("The relocated scanner did not produce a PNG")
        width, height = struct.unpack(">II", data[16:24])
        if abs(width - 30 / 25.4 * 75) > 1 or abs(height - 40 / 25.4 * 75) > 1:
            raise RuntimeError("Unexpected scan dimensions")
        print(f"Relocated scanner produced {width} × {height} PNG; Homebrew and original build paths were denied")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    verify_links(args.runtime)
    smoke_test(args.runtime)


if __name__ == "__main__":
    main()
