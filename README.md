<img src="docs/icon.png" width="128" height="128" alt="" align="right">

# SaneScan

*Honey, I scanned the docs.*

A small, native macOS app that turns any scanner supported by
[SANE](http://www.sane-project.org/) into a multi-page PDF scanner with a
searchable text layer. Built for scanners whose manufacturers stopped shipping
macOS drivers, such as the Canon CanoScan LiDE series.

Put a page on the glass, press ⌘R, repeat, press ⌘S. Out comes one PDF with
all pages, OCR'd in German and English.

![SaneScan main window](docs/screenshot.png)

## What it does

- Lists every scanner SANE can see and lets you pick one if there are several.
- Reads the chosen scanner's capabilities (`scanimage -A`) and offers exactly
  the colour modes and resolutions the device supports.
- Scans page by page from a flatbed, or a whole stack at once from an
  automatic document feeder (ADF) when the scanner has one.
- Scan area presets (A4, A5, Letter, Legal, full bed), clamped to what the
  device can actually scan.
- Pages can be reordered by dragging and removed with ⌫ before the PDF is
  written.
- Produces a JPEG-compressed PDF via ImageMagick and adds a searchable text
  layer with ocrmypdf (Tesseract). If OCR fails the PDF is saved without it
  rather than aborting.
- Remembers scanner, resolution, mode, paper size, OCR setting and output
  folder between launches.
- Fully keyboard operable, labelled for VoiceOver.
- UI in English and German, following the system language.

## Tested with

| Component | Version |
|---|---|
| Scanner | Canon CanoScan LiDE 210 (USB, SANE `genesys` backend) |
| macOS | 27.0.1 on Apple Silicon |
| sane-backends | 1.4.0 |
| ImageMagick | 7.1.2 |
| ocrmypdf / Tesseract | 17.13 / 5.5 |

Any other scanner with a SANE backend should work as long as `scanimage -L`
lists it. The [SANE supported devices list](http://www.sane-project.org/sane-supported-devices.html)
tells you whether yours does. Reports of other models, working or not, are
welcome as issues.

## Requirements

- macOS 14 or newer.
- [Homebrew](https://brew.sh) with the command line tools the app drives:

```sh
brew install sane-backends imagemagick ocrmypdf tesseract-lang
```

`tesseract-lang` provides the German language data for OCR. ocrmypdf is
optional: without it the OCR toggle is disabled and plain image PDFs are
written.

- Xcode or the Swift toolchain (Swift 5.10 or newer) to build.

Check that SANE sees your scanner before blaming the app:

```sh
scanimage -L
# device `genesys:libusb:002:001' is a Canon LiDE 210 flatbed scanner
```

## Build and run

There is no Xcode project. The Makefile wraps `swift build`, assembles the
`.app` bundle from `Info.plist` and a generated icon, and ad-hoc signs it.

```sh
make run        # build release, assemble build/SaneScan.app, launch it
make install    # copy the bundle to /Applications
make clean
swift test      # unit tests for the scanimage output parsers
```

The app is not sandboxed because it needs to launch Homebrew binaries and let
them talk to USB through libusb.

## Usage

1. Start the app. The status bar shows the detected scanner and its maximum
   scan area. With several scanners connected a popup lets you choose.
2. Put a page on the glass and press ⌘R ("Seite scannen"). With an ADF
   selected as source, ⌘R scans every page in the feeder.
3. Repeat for every page. Drag pages to reorder, ⌫ removes the selected one.
4. Pick file name, resolution, mode, paper size, OCR and output folder in the
   settings bar.
5. ⌘S ("PDF erstellen") writes `<folder>/<name>.pdf`. ⌘N starts a new document
   and discards the scanned pages.

Scanned pages live in a temporary folder until the PDF is written or a new
document is started.

## How it works

Everything runs through three command line tools, launched as child
processes off the main thread:

1. `scanimage -L` to list devices, `scanimage -d <device> -A` to read the
   device's option list. The modes, resolutions and `-x`/`-y` limits are
   parsed from that output (`Sources/SaneScan/ScannerDevice.swift`).
2. `scanimage -d <device> --resolution N --mode M --source S -x W -y H --format=png`
   for each page, or the same with `--batch=` for a feeder. One PNG per page.
3. `magick <pages> -units PixelsPerInch -density N -compress jpeg -quality 85 raw.pdf`
4. `ocrmypdf -l deu+eng --quiet raw.pdf final.pdf` when OCR is enabled.

### A note on device names

Some backends (the `genesys` backend on macOS among them) re-enumerate the USB
device every time it is opened, so the address in `genesys:libusb:002:001`
flips to `002:002` and back. Passing that full string to `scanimage -d` then
fails with "Invalid argument". SaneScan therefore addresses a scanner by its
bare backend name (`-d genesys`) whenever only one device of that backend is
connected, and only falls back to the full device string when it has to tell
two scanners of the same backend apart.

### Localization

English strings in the sources are the keys; `Resources/de.lproj/Localizable.strings`
holds the German translation and the Makefile copies the `.lproj` folders into
the bundle. A unit test fails when a string used in the sources has no German
entry. To add a language, add `Resources/<lang>.lproj/Localizable.strings` and
list the language in `Info.plist` under `CFBundleLocalizations`.

To try the other language without changing the system setting:

```sh
open build/SaneScan.app --args -AppleLanguages "(de)"
```

### Icon

`Assets/AppIcon.svg` is the source. The Makefile renders it with QuickLook
(`qlmanage`), scales it with ImageMagick and packs it with `iconutil`.

## Limitations

- One scanner is used at a time; there is no duplex handling beyond what the
  backend's source option offers.
- The scan area is always anchored at the top-left corner of the glass.
- OCR languages are fixed to German and English.
- Only tested with the hardware listed above.

## License

[MIT](LICENSE)
