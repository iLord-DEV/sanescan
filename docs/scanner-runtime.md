# Standalone scanner runtime

The app embeds `Contents/Resources/ScannerRuntime/`. It contains `scanimage`,
SANE backends, libusb, libpng, libjpeg-turbo and libtiff. All are built from
upstream source for macOS 14 and the build machine's architecture. System
frameworks, zlib, libcurl and libxml2 come from macOS. No Homebrew binaries,
developer scanner settings or host libraries are copied into the app.

`ScannerRuntime` in `Tools.swift` selects the bundled executable and sets a
private backend and configuration search path. It removes inherited dynamic
loader overrides. It never falls back to an installed `scanimage`. A missing
runtime produces a reinstall message. SwiftPM development runs use
`build/scanner-runtime/`; run `make scanner-runtime` before scanning from one.

PDFs use CoreGraphics with JPEG-compressed page images, and CoreText for an
invisible text layer. Apple's Vision framework recognizes text on the device,
preferring German and English. Image exports use ImageIO. No ImageMagick,
ocrmypdf, Python OCR environment or language packs are needed by users.

## Scanner support and configuration

All backends produced by this build are enabled by default, except the virtual
`test` backend. USB access uses libusb. eSCL uses macOS libcurl and libxml2.
Optional Avahi, SNMP, gphoto2, Video4Linux and Poppler integration are disabled;
support must be checked for each scanner rather than inferred from SANE's
overall device list. Third-party proprietary backends are not bundled.

For a scanner that needs custom settings, create:

```text
~/Library/Application Support/SaneScan/sane.d/
```

Files there take precedence over the shipped SANE configuration. Keep all
settings specific to your scanner outside the signed app. Some models need
proprietary firmware that cannot be distributed with SANE. Obtain that from the
device vendor and configure an absolute firmware path in the relevant backend's
configuration file. Network scanners may also require their address to be set
explicitly. Firmware and automatic discovery behavior depend on the backend.

## Build and verification

The development machine needs Xcode command line tools, Python 3, CMake and
pkg-config. `scripts/scanner-runtime.lock.json` records source versions, URLs
and SHA-256 checksums. The builder verifies each archive before extracting it.

```sh
make scanner-runtime
make verify-runtime
make app
```

The builder uses `build/runtime-downloads/` for archives and `build/native/`
for objects. Detailed compiler output goes to `build/scanner-runtime-build.log`.
It sets a macOS 14 deployment target, replaces internal library references with
relative `@loader_path` references and signs the executable and libraries.
Unexpected external library dependencies stop packaging.

The verification script checks every binary's dependencies, minimum OS version
and signature. It then copies the runtime into an app-shaped path containing
spaces and queries and scans through SANE's virtual test backend. A sandbox
denies reads from Homebrew, the original runtime and the build prefix during
that test. This checks relocation and independence from installed packages.
It does not replace testing real devices or running on the oldest supported OS.

CI performs this check and the native PDF/OCR tests. Every packaged app repeats
runtime verification. Release DMGs include the same runtime as local builds.

## Licenses and corresponding source

`ScannerRuntime/share/licenses/` contains upstream notices. SANE's frontend is
GPL-licensed; SANE backends have the upstream linking exception, while bundled
dependencies retain their own licenses. The app's MIT license does not replace
these licenses.

`ScannerRuntime/share/sources/` contains every matching upstream source archive,
the exact build script and lock file, and `REBUILD.md`. These files travel with
the app and its updates, so rebuilding the scanner components does not depend
on a separate source download. The build script records the configuration,
installation, relocation and signing steps. No private firmware is included.
