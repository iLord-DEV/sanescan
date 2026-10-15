#!/usr/bin/env python3
"""Generate and verify the signed update feed before publishing a GitHub release."""

import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/iLord-DEV/sanescan"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
KEYCHAIN_ACCOUNT = "de.webdesign-heim.sanescan"


def validate_version(version):
    # Stable numeric tags only; both bundle version keys use this value.
    if not re.fullmatch(r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]{0,3})){0,2}", version):
        raise ValueError("Use a stable numeric release version, for example 1.2 or 1.2.3")
    return version


def validate_feed(feed, archive, version, info):
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The release feed must contain exactly one update")
    item = items[0]
    if item.findtext(f"{{{SPARKLE}}}version") != version:
        raise ValueError("The appcast build version does not match the release tag")
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") != version:
        raise ValueError("The appcast display version does not match the release tag")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Missing update download")
    expected_url = f"{REPOSITORY}/releases/download/v{version}/{archive.name}"
    if enclosure.get("url") != expected_url:
        raise ValueError("The update download must point to this GitHub release")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("The signed archive size does not match the feed")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing or invalid Ed25519 signature")
    public_key = info["SUPublicEDKey"]
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("Invalid public update key")
    return signature, public_key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", type=validate_version)
    parser.add_argument("--validate-version", action="store_true")
    args = parser.parse_args()
    if args.validate_version:
        return

    directory = ROOT / "build/updates"
    archive = directory / f"SaneScan-{args.version}.dmg"
    feed = directory / "appcast.xml"
    info = plistlib.loads((ROOT / "build/SaneScan.app/Contents/Info.plist").read_bytes())
    if any(info[key] != args.version for key in ("CFBundleVersion", "CFBundleShortVersionString")):
        raise ValueError("Build the release with make dmg VERSION=" + args.version)
    if not archive.is_file():
        raise ValueError("Missing release archive: " + archive.name)
    if list(directory.glob("*.dmg")) != [archive]:
        raise ValueError("Use a clean build/updates directory containing only this release")

    command = [
        str(ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"),
        "--maximum-deltas", "0",
        "--download-url-prefix", f"{REPOSITORY}/releases/download/v{args.version}/",
        "--full-release-notes-url", f"{REPOSITORY}/releases/tag/v{args.version}",
        "--link", REPOSITORY,
    ]
    # Send CI secrets only over stdin, never in arguments, log output or files.
    environment = dict(os.environ)
    private_key = environment.pop("SPARKLE_PRIVATE_KEY", None)
    if private_key is not None:
        if not private_key.strip():
            raise ValueError("SPARKLE_PRIVATE_KEY is empty")
        command += ["--ed-key-file", "-"]
    else:
        command += ["--account", KEYCHAIN_ACCOUNT]
    feed.unlink(missing_ok=True)
    subprocess.run(command + [str(directory)], input=private_key, text=True,
                   env=environment, check=True)
    signature, public_key = validate_feed(feed, archive, args.version, info)
    subprocess.run(["swift", str(ROOT / "scripts/verify-update.swift"),
                    str(archive), signature, public_key], env=environment, check=True)
    print("Signed update feed verified: " + str(feed.relative_to(ROOT)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
