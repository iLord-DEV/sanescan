#!/usr/bin/env python3
"""Verify the local update key and optionally configure GitHub's release secret."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
KEY_TOOL = ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_keys"
ACCOUNT = "de.webdesign-heim.sanescan"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upload-secret", action="store_true")
    args = parser.parse_args()
    public_key = subprocess.check_output([str(KEY_TOOL), "--account", ACCOUNT, "-p"], text=True).strip()
    info = plistlib.loads((ROOT / "Info.plist").read_bytes())
    if public_key != info["SUPublicEDKey"]:
        raise SystemExit("The local signing key does not match Info.plist. Restore the original key before releasing.")
    print("Local signing key matches the app's public key.", flush=True)
    if not args.upload_secret:
        return
    # The private export lives only inside a temporary directory with mode 0700.
    # It is never printed or passed as a process argument and is deleted on exit.
    with tempfile.TemporaryDirectory(prefix="sanescan-signing-") as directory:
        private_file = Path(directory) / "private-key"
        subprocess.run([str(KEY_TOOL), "--account", ACCOUNT, "-x", str(private_file)],
                       check=True, capture_output=True)
        private_file.chmod(0o600)
        subprocess.run(["gh", "secret", "set", "SPARKLE_PRIVATE_KEY", "--repo", "iLord-DEV/sanescan"],
                       input=private_file.read_bytes(), check=True)
    print("SPARKLE_PRIVATE_KEY configured for iLord-DEV/sanescan.")


if __name__ == "__main__":
    main()
