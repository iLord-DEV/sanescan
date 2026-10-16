# Integrated updates

SaneScan uses [Sparkle 2](https://sparkle-project.org/documentation/) to check,
download, verify and install updates from GitHub Releases. The app menu offers
**Check for Updates…** and a toggle for automatic checks. Checks default to once
a day; installation always requires the user's choice in Sparkle's dialog.

An update waits while a scan or area selection is active or the current page
list differs from the last successful export (PDF, PNG, JPEG or TIFF). Exporting or
starting a new document allows a pending update to finish. New scan actions
are disabled once installation starts.

## Build integration

`Package.swift` pins Sparkle; `Package.resolved` records the source revision and
SwiftPM verifies the downloaded binary's checksum. `make app` embeds the full
framework, preserving its symlinks and helper tools, includes its license and
adds the runtime framework search path. The existing ad-hoc app signing remains
in use; Apple Developer ID signing and notarization are separate from Sparkle's
Ed25519 update signatures.

Each app and update also contains the private scanner runtime, its licenses and
complete matching source archives. The release workflow builds it from pinned
upstream sources and verifies library paths, deployment targets, signatures and
a relocated virtual scan before packaging. PDF creation and OCR use macOS
frameworks and need no separately installed software. See
[scanner runtime details](scanner-runtime.md).

When `VERSION` is supplied, the Makefile sets **both** `CFBundleVersion` and
`CFBundleShortVersionString`. Use increasing stable numeric versions such as
`1.1`, `1.2` or `1.2.1`. The release workflow rejects prerelease tags; those must
not replace the stable update feed.

## Signing key

`Info.plist` contains the public Ed25519 key. Its private key is stored in the
macOS login Keychain under the Sparkle account `de.webdesign-heim.sanescan`.
Never commit an exported private key or replace the public key on an existing
release without planning a supported key rotation.

After `swift package resolve`, check that the local key matches the app:

```sh
python3 scripts/configure-update-signing.py
```

Configure GitHub Actions once, with GitHub CLI authenticated for the repository:

```sh
python3 scripts/configure-update-signing.py --upload-secret
```

This exports the existing key inside a private temporary directory, uploads it
as the repository's `SPARKLE_PRIVATE_KEY` Actions secret via stdin and deletes
the export. It does not publish a release. Back up the key separately in secure
storage. Sparkle's `generate_keys --account de.webdesign-heim.sanescan -x <path>`
exports it and `-f <path>` restores it on another Mac. A fresh key will not be
able to update apps already distributed with the current public key.

## Publishing

Pushing a stable tag such as `v1.2` runs `.github/workflows/release.yml`. It:

1. Validates the version and requires the signing secret.
2. Builds and verifies the bundled scanner runtime, runs the app and release
   tooling tests, then builds the DMG.
3. Generates an appcast with Sparkle, signing the DMG with the Actions secret
   passed over stdin. No private key is written into the repository or logs.
4. Verifies the feed's version, download URL and file size, then independently
   checks the archive's Ed25519 signature against the app's public key using
   CryptoKit. Missing signatures and mismatched keys stop the release.
5. Publishes `SaneScan-<version>.dmg` and `appcast.xml` together as the latest
   stable GitHub release.

The app's fixed feed URL is:

```text
https://github.com/iLord-DEV/sanescan/releases/latest/download/appcast.xml
```

The feed points to the versioned DMG URL. No additional server or GitHub Pages
deployment is needed. Only publish increasing stable versions as **Latest**;
marking an older release latest would also switch this feed back to it.

## Testing locally

```sh
swift test
python3 -m unittest discover -s Tests/ReleaseTests
make dmg VERSION=1.2
mkdir -p build/updates
cp build/SaneScan.dmg build/updates/SaneScan-1.2.dmg
python3 scripts/generate-appcast.py 1.2
```

Use a clean `build/updates` directory containing only the DMG being tested.
Without `SPARKLE_PRIVATE_KEY` in the environment, signing uses the Keychain.
These commands generate and verify the update artifacts without uploading
anything. A complete installation test needs two app versions and a reachable
feed; use Sparkle's [testing instructions](https://sparkle-project.org/documentation/#6-test-sparkle-out).

The first Sparkle-enabled version must be installed manually once. Earlier
versions have no updater. The production feed becomes available when the first
release containing `appcast.xml` is published. Install the app into Applications
before testing installation; updates cannot replace an app running from a
read-only DMG.
