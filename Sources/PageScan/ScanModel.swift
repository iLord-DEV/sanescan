import AppKit
import Foundation
import ImageIO

enum ColorMode: String, CaseIterable, Identifiable {
    case gray = "Gray"
    case color = "Color"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gray: return "Graustufen"
        case .color: return "Farbe"
        }
    }
}

struct ScannedPage: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage?

    static func makeThumbnail(for url: URL, maxPixelSize: Int = 240) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Holds the scanned pages, the settings and drives the external tools.
@MainActor
final class ScanModel: ObservableObject {
    static let dpiOptions = [150, 200, 300, 400, 600]

    @Published var pages: [ScannedPage] = []
    @Published var selection: UUID?
    @Published var documentName = ""

    @Published private(set) var scannerName: String?
    @Published private(set) var scannerSearching = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""

    @Published var errorMessage: String?
    @Published var savedPDF: URL?
    @Published var overwriteCandidate: URL?
    @Published var confirmNewDocument = false

    @Published var dpi: Int {
        didSet { defaults.set(dpi, forKey: "dpi") }
    }
    @Published var colorMode: ColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: "colorMode") }
    }
    @Published var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") }
    }
    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: "outputFolder") }
    }

    let ocrAvailable = Tools.isAvailable("ocrmypdf")

    private let defaults = UserDefaults.standard
    private let workDirectory: URL

    init() {
        let storedDPI = defaults.integer(forKey: "dpi")
        dpi = Self.dpiOptions.contains(storedDPI) ? storedDPI : 300
        colorMode = ColorMode(rawValue: defaults.string(forKey: "colorMode") ?? "") ?? .gray
        ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let stored = defaults.string(forKey: "outputFolder"),
           FileManager.default.fileExists(atPath: stored) {
            outputFolder = URL(fileURLWithPath: stored)
        } else {
            outputFolder = desktop
        }

        let tmp = FileManager.default.temporaryDirectory
        Self.removeStaleWorkDirectories(in: tmp)
        workDirectory = tmp.appendingPathComponent("PageScan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Scanner

    func detectScanner() async {
        scannerSearching = true
        defer { scannerSearching = false }
        do {
            let result = try await Tools.run("scanimage", ["-L"])
            // Example: device `genesys:libusb:002:001' is a Canon LiDE 210 flatbed scanner
            let line = result.stdout
                .components(separatedBy: .newlines)
                .first { $0.contains(" is a ") }
            if let line, let range = line.range(of: " is a ") {
                scannerName = String(line[range.upperBound...])
                    .replacingOccurrences(of: " flatbed scanner", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                scannerName = nil
            }
        } catch {
            scannerName = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pages

    func scanPage() async {
        guard !isBusy else { return }
        isBusy = true
        statusText = "Scanne Seite \(pages.count + 1) …"
        defer { isBusy = false }

        let url = workDirectory.appendingPathComponent("page-\(UUID().uuidString).png")
        do {
            try await Tools.runChecked("scanimage", [
                "--resolution", "\(dpi)",
                "--mode", colorMode.rawValue,
                "-x", "210", "-y", "297",
                "--format=png",
                "-o", url.path,
            ])
            let thumbnail = await Task.detached { ScannedPage.makeThumbnail(for: url) }.value
            let page = ScannedPage(url: url, thumbnail: thumbnail)
            pages.append(page)
            selection = page.id
            statusText = "Seite \(pages.count) gescannt"
        } catch {
            try? FileManager.default.removeItem(at: url)
            statusText = ""
            errorMessage = error.localizedDescription
        }
    }

    func removeSelected() {
        guard let selection, let index = pages.firstIndex(where: { $0.id == selection }) else { return }
        let page = pages.remove(at: index)
        try? FileManager.default.removeItem(at: page.url)
        let next = min(index, pages.count - 1)
        self.selection = next >= 0 ? pages[next].id : nil
    }

    func movePages(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    func requestNewDocument() {
        if pages.isEmpty {
            newDocument()
        } else {
            confirmNewDocument = true
        }
    }

    func newDocument() {
        for page in pages {
            try? FileManager.default.removeItem(at: page.url)
        }
        pages = []
        selection = nil
        documentName = ""
        statusText = ""
    }

    // MARK: - PDF

    var resolvedFileName: String {
        var name = documentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HHmm"
            name = "Scan \(formatter.string(from: Date()))"
        }
        if name.lowercased().hasSuffix(".pdf") {
            name = String(name.dropLast(4))
        }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    func createPDF(overwrite: Bool = false) async {
        guard !pages.isEmpty, !isBusy else { return }

        let target = outputFolder.appendingPathComponent(resolvedFileName + ".pdf")
        if !overwrite, FileManager.default.fileExists(atPath: target.path) {
            overwriteCandidate = target
            return
        }

        isBusy = true
        defer { isBusy = false }

        let raw = workDirectory.appendingPathComponent("raw-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: raw) }

        do {
            statusText = "Erzeuge PDF mit \(pages.count) Seite\(pages.count == 1 ? "" : "n") …"
            var arguments = pages.map(\.url.path)
            arguments += [
                "-units", "PixelsPerInch",
                "-density", "\(dpi)",
                "-compress", "jpeg",
                "-quality", "85",
                raw.path,
            ]
            try await Tools.runChecked("magick", arguments)

            var ocrNote = ""
            if ocrEnabled && ocrAvailable {
                statusText = "Texterkennung …"
                let result = try await Tools.run("ocrmypdf", ["-l", "deu+eng", "--quiet", raw.path, target.path])
                if !result.succeeded {
                    ocrNote = " (ohne Textebene, OCR fehlgeschlagen)"
                    try replaceFile(at: target, with: raw)
                }
            } else {
                try replaceFile(at: target, with: raw)
            }

            statusText = "Gespeichert: \(target.lastPathComponent)\(ocrNote)"
            savedPDF = target
        } catch {
            statusText = ""
            errorMessage = error.localizedDescription
        }
    }

    private func replaceFile(at target: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    // MARK: - Helpers

    private static func removeStaleWorkDirectories(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("PageScan-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
