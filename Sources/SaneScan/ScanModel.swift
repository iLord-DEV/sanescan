import AppKit
import Foundation
import ImageIO

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
    /// Offered until a device has reported its own list.
    static let fallbackResolutions = [150, 200, 300, 400, 600]
    static let fallbackModes = ["Gray", "Color"]

    @Published var pages: [ScannedPage] = []
    @Published var selection: UUID?
    @Published var documentName = ""
    @Published var customScanArea: ScanArea?
    @Published var selectingScanArea = false
    @Published private(set) var savedPageIDs: [UUID] = []

    var hasUnsavedPages: Bool { !pages.isEmpty && pages.map(\.id) != savedPageIDs }

    @Published private(set) var devices: [ScannerDevice] = []
    @Published private(set) var capabilities: ScannerCapabilities?
    @Published private(set) var scannerSearching = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""

    @Published var errorMessage: String?
    @Published var savedPDF: URL?
    @Published var overwriteCandidate: URL?
    @Published var confirmNewDocument = false

    /// SANE device string of the scanner in use. Changing it reloads the capabilities.
    @Published var selectedDeviceID: String? {
        didSet {
            defaults.set(deviceSelector, forKey: "deviceSelector")
            guard selectedDeviceID != oldValue else { return }
            customScanArea = nil
            capabilities = nil
            guard selectedDeviceID != nil else { return }
            Task { await loadCapabilities() }
        }
    }
    @Published var dpi: Int {
        didSet { defaults.set(dpi, forKey: "dpi") }
    }
    @Published var colorMode: String {
        didSet { defaults.set(colorMode, forKey: "colorMode") }
    }
    @Published var source: String? {
        didSet {
            defaults.set(source, forKey: "source")
            if source != oldValue { customScanArea = nil }
        }
    }
    @Published var paperSize: PaperSize {
        didSet {
            defaults.set(paperSize.rawValue, forKey: "paperSize")
            customScanArea = nil
        }
    }
    @Published var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") }
    }
    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: "outputFolder") }
    }

    let ocrAvailable = Tools.isAvailable("ocrmypdf")

    private let defaults: UserDefaults
    private let workDirectory: URL

    init(defaults: UserDefaults = .standard, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        let storedDPI = defaults.integer(forKey: "dpi")
        dpi = storedDPI > 0 ? storedDPI : 300
        colorMode = defaults.string(forKey: "colorMode") ?? "Gray"
        source = defaults.string(forKey: "source")
        paperSize = PaperSize(rawValue: defaults.string(forKey: "paperSize") ?? "") ?? .a4
        ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true
        selectedDeviceID = nil

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let stored = defaults.string(forKey: "outputFolder"),
           FileManager.default.fileExists(atPath: stored) {
            outputFolder = URL(fileURLWithPath: stored)
        } else {
            outputFolder = desktop
        }

        let tmp = temporaryDirectory
        Self.removeStaleWorkDirectories(in: tmp)
        workDirectory = tmp.appendingPathComponent("SaneScan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Scanner

    var selectedDevice: ScannerDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var scannerName: String? { selectedDevice?.name }

    /// Argument for `scanimage -d`, see `ScannerDevice.selector(in:)`.
    var deviceSelector: String? {
        selectedDevice?.selector(in: devices)
    }

    /// Resolutions to offer in the UI.
    var dpiOptions: [Int] {
        let list = capabilities?.resolutions ?? []
        return list.isEmpty ? Self.fallbackResolutions : list
    }

    /// Modes to offer in the UI.
    var modeOptions: [String] {
        let list = capabilities?.modes ?? []
        return list.isEmpty ? Self.fallbackModes : list
    }

    var sourceOptions: [String] { capabilities?.sources ?? [] }

    /// True when the selected source is an automatic document feeder.
    var usesFeeder: Bool {
        guard let source else { return false }
        return ScannerCapabilities.isFeeder(source)
    }

    /// Human readable maximum scan area, e.g. "216 × 297 mm".
    var scanAreaDescription: String? {
        guard let caps = capabilities, let w = caps.maxWidth, let h = caps.maxHeight else { return nil }
        return "\(Int(w.rounded())) × \(Int(h.rounded())) mm"
    }

    var fullScanArea: ScanArea? {
        guard let caps = capabilities, let width = caps.maxWidth, let height = caps.maxHeight,
              width > 0, height > 0 else { return nil }
        return ScanArea(width: width, height: height)
    }

    var canSelectScanArea: Bool {
        !isBusy && !scannerSearching && selectedDevice != nil && !usesFeeder && fullScanArea != nil
    }

    var effectiveScanArea: ScanArea? {
        if !usesFeeder, let customScanArea { return customScanArea }
        guard let size = paperSize.scanArea(for: capabilities ?? ScannerCapabilities()) else { return nil }
        return ScanArea(width: size.width, height: size.height)
    }

    /// Lists the connected scanners and selects the stored or first one.
    func detectScanner() async {
        guard !scannerSearching, !isBusy, !selectingScanArea else { return }
        scannerSearching = true
        customScanArea = nil
        defer { scannerSearching = false }
        do {
            let result = try await Tools.run("scanimage", ["-L"])
            let found = ScannerDevice.parseList(result.stdout)
            let wanted = deviceSelector ?? defaults.string(forKey: "deviceSelector")
            devices = found
            capabilities = nil
            let match = found.first { $0.selector(in: found) == wanted } ?? found.first
            if match?.id == selectedDeviceID {
                // didSet does not fire for an unchanged id, reload explicitly.
                await loadCapabilities()
            } else {
                selectedDeviceID = match?.id
            }
        } catch {
            devices = []
            capabilities = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Queries `scanimage -A` for the selected device and fits the settings to it.
    func loadCapabilities() async {
        guard let deviceID = selectedDeviceID, let selector = deviceSelector else { return }
        do {
            let result = try await Tools.runChecked("scanimage", ["-d", selector, "-A"])
            let caps = ScannerCapabilities.parse(result.stdout)
            guard deviceID == selectedDeviceID else { return }
            capabilities = caps
            applyCapabilities(caps)
        } catch {
            capabilities = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps the stored settings only if the device supports them.
    private func applyCapabilities(_ caps: ScannerCapabilities) {
        if !caps.resolutions.isEmpty, !caps.resolutions.contains(dpi) {
            dpi = caps.resolutions.min { abs($0 - 300) < abs($1 - 300) } ?? 300
        }
        if !caps.modes.isEmpty, !caps.modes.contains(colorMode) {
            colorMode = ScanModeLabel.preferredMode(from: caps.modes) ?? caps.modes[0]
        }
        if caps.sources.isEmpty {
            source = nil
        } else if source == nil || !caps.sources.contains(source!) {
            source = caps.sources[0]
        }
    }

    // MARK: - Pages

    /// A low-resolution full-bed scan for area selection; never becomes a document page.
    func scanAreaPreview() async throws -> NSImage? {
        guard canSelectScanArea, let selector = deviceSelector, let bed = fullScanArea else { return nil }
        isBusy = true
        statusText = String(localized: "Scanning preview…")
        defer {
            isBusy = false
            statusText = ""
        }
        let url = workDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let resolution = dpiOptions.min { abs($0 - 75) < abs($1 - 75) } ?? 75
        var arguments = ["-d", selector, "--resolution", "\(resolution)", "--mode", colorMode,
                         "--format=png"]
        if let source { arguments += ["--source", source] }
        arguments += bed.arguments + ["-o", url.path]
        try await Tools.runChecked("scanimage", arguments)
        guard let image = await Task.detached(operation: { NSImage(contentsOf: url) }).value else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    /// Scans one page from the flatbed, or every page in the feeder.
    func scanPage() async {
        guard !isBusy, !selectingScanArea, let selector = deviceSelector else { return }
        isBusy = true
        defer { isBusy = false }

        let batchDirectory = workDirectory.appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
        do {
            var arguments = [
                "-d", selector,
                "--resolution", "\(dpi)",
                "--mode", colorMode,
                "--format=png",
            ]
            if let source {
                arguments += ["--source", source]
            }
            if let area = effectiveScanArea {
                // Preserve compatibility with backends without offset options for presets.
                if customScanArea != nil && !usesFeeder {
                    arguments += area.arguments
                } else {
                    arguments += ["-x", Self.millimetres(area.width), "-y", Self.millimetres(area.height)]
                }
            }

            let scanned: [URL]
            if usesFeeder {
                statusText = String(localized: "Scanning stack from the feeder…")
                try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
                let pattern = batchDirectory.appendingPathComponent("page-%04d.png").path
                arguments.append("--batch=\(pattern)")
                scanned = try await runBatch(arguments, in: batchDirectory)
            } else {
                statusText = String(localized: "Scanning page \(pages.count + 1)…")
                let url = workDirectory.appendingPathComponent("page-\(UUID().uuidString).png")
                do {
                    try await Tools.runChecked("scanimage", arguments + ["-o", url.path])
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                scanned = [url]
            }

            for url in scanned {
                let thumbnail = await Task.detached { ScannedPage.makeThumbnail(for: url) }.value
                let page = ScannedPage(url: url, thumbnail: thumbnail)
                pages.append(page)
                selection = page.id
            }
            if scanned.count == 1 {
                statusText = String(localized: "Page \(pages.count) scanned")
            } else {
                statusText = String(localized: "\(scanned.count) pages scanned, \(pages.count) in total")
            }
        } catch {
            try? FileManager.default.removeItem(at: batchDirectory)
            statusText = ""
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a `--batch` scan. scanimage stops when the feeder is empty, which some
    /// backends report as an error, so the produced files decide about success.
    private func runBatch(_ arguments: [String], in directory: URL) async throws -> [URL] {
        let result = try await Tools.run("scanimage", arguments)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        if files.isEmpty {
            throw ToolError.failed(tool: "scanimage", status: result.status, stderr: result.stderr)
        }
        return files
    }

    private static func millimetres(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
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
        savedPageIDs = []
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
        guard !pages.isEmpty, !isBusy, !selectingScanArea else { return }

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
            statusText = String(localized: "Creating PDF with \(pages.count) page(s)…")
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
                statusText = String(localized: "Recognizing text…")
                let result = try await Tools.run("ocrmypdf", ["-l", "deu+eng", "--quiet", raw.path, target.path])
                if !result.succeeded {
                    ocrNote = String(localized: " (no text layer, OCR failed)")
                    try replaceFile(at: target, with: raw)
                }
            } else {
                try replaceFile(at: target, with: raw)
            }

            statusText = String(localized: "Saved: \(target.lastPathComponent)\(ocrNote)")
            savedPageIDs = pages.map(\.id)
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
        for entry in entries where entry.lastPathComponent.hasPrefix("SaneScan-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
