# PageScan

SwiftUI-App (macOS 14+, Apple Silicon) für mehrseitige PDF-Scans mit dem Canon
CanoScan LiDE 210. Canon liefert keinen Treiber mehr für aktuelles macOS, daher
läuft alles über Homebrew-Tools, die die App per `Process` aufruft.

## Architektur

- `Sources/PageScan/PageScanApp.swift` – App-Einstieg, Menü „Scannen“ mit den
  Tastenkürzeln (⌘R Seite scannen, ⌘S PDF erstellen, ⌘N neues Dokument).
  Kürzel nur hier definieren, nicht zusätzlich an den Buttons.
- `Sources/PageScan/ScanModel.swift` – `@MainActor ObservableObject`: Seiten,
  Einstellungen (UserDefaults), Scanner-Erkennung, Scan und PDF-Erzeugung.
- `Sources/PageScan/ContentView.swift` – gesamte UI: Statusleiste, Seitenliste,
  Vorschau, Einstellungsleiste, Aktionsleiste, Alerts/Dialoge.
- `Sources/PageScan/Tools.swift` – findet Binaries in `/opt/homebrew/bin` usw.
  und führt sie asynchron aus (stdout/stderr getrennt, PATH erweitert).

## Pipeline

1. `scanimage --resolution DPI --mode Gray|Color -x 210 -y 297 --format=png`
   → PNG je Seite im temporären Arbeitsordner (`PageScan-<UUID>`).
2. `magick <pngs> -units PixelsPerInch -density DPI -compress jpeg -quality 85 raw.pdf`
3. Optional `ocrmypdf -l deu+eng --quiet raw.pdf ziel.pdf`; schlägt OCR fehl,
   wird raw.pdf ohne Textebene gespeichert (kein Abbruch).

Das Shell-Pendant liegt in `~/.local/bin/scan` (gleiche Pipeline, interaktiv).

## Build

- Kein Xcode-Projekt. `swift build` (Package.swift, tools-version 5.10, Swift-5-
  Sprachmodus) plus `Info.plist`; das Makefile baut daraus `build/PageScan.app`.
- `make run` baut und startet, `make install` kopiert nach `/Applications`.
- Icon wird im Makefile mit ImageMagick + `iconutil` generiert.
- Nur ad-hoc signiert, keine Sandbox (nötig für Process und libusb-Zugriff).
- Makefile-Rezepte brauchen echte Tabs (macOS-make 3.81, kein `.RECIPEPREFIX`).

## Abhängigkeiten

`brew install sane-backends imagemagick ocrmypdf tesseract-lang`

## Regeln

- UI-Texte Deutsch, Code und Kommentare Englisch.
- Alle Bedienelemente per Tastatur erreichbar, Labels für VoiceOver setzen.
- Langlaufende Tool-Aufrufe nie auf dem Main Thread (`Tools.run` nutzt
  `Task.detached`).
- Nicht committen, pushen oder nach /Applications installieren ohne Rückfrage.
