# PageScan

Small SwiftUI app for multi-page PDF scanning with the Canon CanoScan LiDE 210
on macOS (Apple Silicon). Canon no longer ships a driver for current macOS, so
the app drives the scanner through SANE and uses ImageMagick and ocrmypdf for
the PDF.

## Requirements

```
brew install sane-backends imagemagick ocrmypdf tesseract-lang
```

Xcode (or the Swift toolchain) for building.

## Build & run

```
make run        # build release, assemble build/PageScan.app, open it
make install    # copy to /Applications
make clean
```

The bundle is built without an Xcode project: `swift build` plus `Info.plist`
and a generated icon (see Makefile).

## Usage

1. Put a page on the glass, press ⌘R (or "Seite scannen").
2. Repeat for every page. Pages can be reordered by dragging, removed with ⌫.
3. Set file name, resolution, colour mode, OCR and target folder in the bar.
4. ⌘S creates `<Zielordner>/<Dateiname>.pdf` (A4, JPEG quality 85, searchable
   text layer in German + English when OCR is enabled).

Settings are remembered between launches. Scanned pages live in a temporary
folder and are discarded when a new document is started.
