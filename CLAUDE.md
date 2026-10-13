# SaneScan

SwiftUI-App (macOS 14+) für mehrseitige PDF-Scans mit jedem Scanner, den SANE
unterstützt. Entstanden für den Canon CanoScan LiDE 210, für den Canon keinen
Treiber für aktuelles macOS mehr liefert. Alles läuft über Homebrew-Tools, die
die App per `Process` aufruft.

## Architektur

- `Sources/SaneScan/SaneScanApp.swift` – App-Einstieg, Menü „Scannen“ mit den
  Tastenkürzeln (⌘R Seite/Stapel scannen, ⌘S PDF erstellen, ⌘N neues
  Dokument). Kürzel nur hier definieren, nicht zusätzlich an den Buttons.
- `Sources/SaneScan/ScanModel.swift` – `@MainActor ObservableObject`: Seiten,
  Einstellungen (UserDefaults), Geräteliste, Fähigkeiten, Scan und
  PDF-Erzeugung.
- `Sources/SaneScan/ScannerDevice.swift` – reine Parser ohne UI: `ScannerDevice`
  (aus `scanimage -L`), `ScannerCapabilities` (aus `scanimage -A`), `PaperSize`
  (Presets, auf Gerätefläche begrenzt), `ScanModeLabel` (deutsche Labels).
  Wird in `Tests/SaneScanTests` getestet.
- `Sources/SaneScan/ContentView.swift` – gesamte UI: Statusleiste mit
  Geräteauswahl, Seitenliste, Vorschau, Einstellungsleiste, Aktionsleiste,
  Alerts/Dialoge.
- `Sources/SaneScan/Tools.swift` – findet Binaries in `/opt/homebrew/bin` usw.
  und führt sie asynchron aus (stdout/stderr getrennt, PATH erweitert).

## Pipeline

1. `scanimage -L` → Geräteliste; `scanimage -d <sel> -A` → Modi, Auflösungen,
   Quellen, maximale Fläche (`-x`/`-y`).
2. `scanimage -d <sel> --resolution DPI --mode M [--source S] -x W -y H
   --format=png` → PNG je Seite im Arbeitsordner (`SaneScan-<UUID>`). Mit
   Einzug stattdessen `--batch=<dir>/page-%04d.png`; erfolgreich, sobald
   Dateien entstanden sind (Exit-Status am Ende des Stapels ist backendabhängig).
3. `magick <pngs> -units PixelsPerInch -density DPI -compress jpeg -quality 85 raw.pdf`
4. Optional `ocrmypdf -l deu+eng --quiet raw.pdf ziel.pdf`; schlägt OCR fehl,
   wird raw.pdf ohne Textebene gespeichert (kein Abbruch).

Das Shell-Pendant liegt in `~/.local/bin/scan` (gleiche Pipeline, interaktiv).

## Geräteauswahl (wichtig)

Das `genesys`-Backend (und evtl. andere) enumeriert das USB-Gerät bei jedem
Öffnen neu: `genesys:libusb:002:001` wird zu `002:002` und zurück. Der volle
String aus `-L` ist nach dem nächsten Öffnen ungültig („open of device …
failed: Invalid argument“). Deshalb übergibt die App an `-d` nur den
Backend-Namen (`genesys`), solange nur ein Gerät dieses Backends hängt
(`ScannerDevice.selector(in:)`). Gespeichert wird ebenfalls der Selektor, nicht
die volle Kennung. Nicht „vereinfachen“, indem wieder die volle ID verwendet
wird.

## Build

- Kein Xcode-Projekt. `swift build` (Package.swift, tools-version 5.10, Swift-5-
  Sprachmodus) plus `Info.plist`; das Makefile baut daraus `build/SaneScan.app`.
- `make run` baut und startet, `make install` kopiert nach `/Applications`,
  `swift test` führt die Parser-Tests aus (auch in GitHub Actions).
- Icon: `Assets/AppIcon.svg` ist die Quelle, `Assets/AppIcon.png` (1024 px) das
  eingecheckte Rendering. `make icon-png` rendert per `qlmanage` neu (QuickLook
  kann volles SVG, der ImageMagick-Renderer keine Gradienten/Gruppen). Der
  normale Build skaliert nur mit `sips` + `iconutil`, damit der CI-Runner kein
  Homebrew braucht. Nach SVG-Änderung PNG neu rendern und mit einchecken.
- `make dmg` baut `build/SaneScan.dmg`; `VERSION=1.2` setzt die Bundle-Version
  per PlistBuddy. `.github/workflows/release.yml` macht das bei Tags `v*` und
  hängt die DMG an ein GitHub-Release. Nur ad-hoc signiert, keine
  Notarisierung: Nutzer müssen Rechtsklick → Öffnen oder `xattr -d
  com.apple.quarantine` (steht im README).
- Lokalisierung: Englische Strings im Code sind die Schlüssel,
  `Resources/de.lproj/Localizable.strings` die deutsche Übersetzung. Kein
  `Bundle.module`, das Makefile kopiert die `.lproj`-Ordner nach
  `Contents/Resources`, damit `Bundle.main` sie findet. `LocalizationTests`
  schlägt fehl, wenn ein Schlüssel im Code keine deutsche Übersetzung hat.
  Interpolationen: `Int` → `%lld`, `String` → `%@` (Int32 vorher nach Int wandeln).
- Nur ad-hoc signiert, keine Sandbox (nötig für Process und libusb-Zugriff).
- Makefile-Rezepte brauchen echte Tabs (macOS-make 3.81, kein `.RECIPEPREFIX`).

## Abhängigkeiten

`brew install sane-backends imagemagick ocrmypdf tesseract-lang`

## Regeln

- UI-Texte englisch im Code (SwiftUI-Strings, `String(localized:)`), deutsche
  Übersetzung in `Resources/de.lproj/Localizable.strings` nachtragen. Code,
  Kommentare und README Englisch.
- Alle Bedienelemente per Tastatur erreichbar, Labels für VoiceOver setzen.
- Langlaufende Tool-Aufrufe nie auf dem Main Thread (`Tools.run` nutzt
  `Task.detached`).
- Öffentliches Repo: keine lokalen Pfade, Namen oder Scans in Commits.
- Nicht committen, pushen oder nach /Applications installieren ohne Rückfrage.
