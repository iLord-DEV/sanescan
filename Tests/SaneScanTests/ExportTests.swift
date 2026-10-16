import Combine
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import SaneScan

final class ExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(in directory: URL, name: String, width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent(name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor
    private func model(in directory: URL) throws -> ScanModel {
        let suite = "SaneScanExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = ScanModel(defaults: defaults, temporaryDirectory: directory)
        model.outputFolder = directory
        model.documentName = "Document"
        return model
    }

    func testFormatSwitchRemovesOldExtensionAndNamesImagePagesInOrder() throws {
        let folder = try directory()
        let name = ExportFormat.baseName("  Invoice.PDF  ", fallback: "Scan")
        XCTAssertEqual(name, "Invoice")
        XCTAssertEqual(ExportFormat.jpeg.targets(in: folder, baseName: name, pageCount: 3).map(\.lastPathComponent),
                       ["Invoice-001.jpg", "Invoice-002.jpg", "Invoice-003.jpg"])
        for format in [ExportFormat.pdf, .tiff] {
            XCTAssertEqual(format.targets(in: folder, baseName: name, pageCount: 3).count, 1)
        }
        XCTAssertEqual(ExportFormat.png.targets(in: folder, baseName: name, pageCount: 1).first?.lastPathComponent,
                       "Invoice.png")
        XCTAssertEqual(ExportFormat.baseName(" .tiff ", fallback: "Scan"), "Scan")
        XCTAssertEqual(ExportFormat.baseName("Folder/Name:Test.jpeg", fallback: "Scan"), "Folder-Name-Test")
    }

    func testPNGAndJPEGExportsAreReadableAndKeepPageDimensionsAndResolution() throws {
        let folder = try directory()
        let pages = [try image(in: folder, name: "first", width: 16, height: 12),
                     try image(in: folder, name: "second", width: 9, height: 7)]
        for format in [ExportFormat.png, .jpeg] {
            let targets = format.targets(in: folder, baseName: "Export", pageCount: 2)
            try ImageExporter.write(pages: pages, format: format, dpi: 300, destinations: targets)
            for (index, target) in targets.enumerated() {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetCount(source), 1)
                XCTAssertEqual(CGImageSourceGetType(source) as String?,
                               format == .png ? UTType.png.identifier : UTType.jpeg.identifier)
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, index == 0 ? 16 : 9)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, index == 0 ? 12 : 7)
                XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Double), 300, accuracy: 0.1)
            }
        }
    }

    func testTIFFContainsAllPagesInOrderWithLosslessCompression() throws {
        let folder = try directory()
        let pages = [try image(in: folder, name: "first", width: 16, height: 12),
                     try image(in: folder, name: "second", width: 9, height: 7)]
        let target = folder.appendingPathComponent("Export.tiff")
        try ImageExporter.write(pages: pages, format: .tiff, dpi: 300, destinations: [target])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        for index in 0..<2 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, index == 0 ? 16 : 9)
            let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFCompression] as? Int, 5)
        }
    }

    func testMonochromeScansCanBeExportedToEveryFormat() throws {
        let folder = try directory()
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 0xAA, count: 8) as CFData))
        let image = try XCTUnwrap(CGImage(width: 8, height: 8, bitsPerComponent: 1, bitsPerPixel: 1,
            bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = folder.appendingPathComponent("lineart.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for format in [ExportFormat.png, .jpeg, .tiff] {
            let targets = format.targets(in: folder, baseName: "Export", pageCount: 1)
            try ImageExporter.write(pages: [input], format: format, dpi: 300, destinations: targets)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(targets[0] as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let pdf = folder.appendingPathComponent("lineart.pdf")
        XCTAssertFalse(try PDFExporter.write(pages: [input], dpi: 300, performOCR: false, destination: pdf))
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: pdf)).pageCount, 1)
    }

    @MainActor
    func testPDFExportKeepsAllPages() async throws {
        let folder = try directory()
        let model = try model(in: folder)
        model.exportFormat = .pdf
        model.ocrEnabled = false
        model.pages = [ScannedPage(url: try image(in: folder, name: "first", width: 16, height: 12), thumbnail: nil),
                       ScannedPage(url: try image(in: folder, name: "second", width: 9, height: 7), thumbnail: nil)]
        await model.createOutput()
        XCTAssertNil(model.errorMessage)
        let document = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(model.savedFiles.first)))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertFalse(model.hasUnsavedPages)
    }

    func testFailedMultiFileCommitRestoresEveryOriginal() throws {
        let folder = try directory()
        let targets = ExportFormat.png.targets(in: folder, baseName: "Export", pageCount: 2)
        for target in targets { try Data("original".utf8).write(to: target) }
        let transaction = try ExportTransaction(targets: targets)
        for source in transaction.stagedFiles { try Data("new".utf8).write(to: source) }
        XCTAssertThrowsError(try transaction.commit(overwrite: true) { source, target in
            if source == transaction.stagedFiles[1] { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.moveItem(at: source, to: target)
        })
        for target in targets { XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8)) }
    }

    func testNewlyCreatedFileCannotBeOverwrittenWithoutConfirmation() throws {
        let folder = try directory()
        let target = folder.appendingPathComponent("Export.png")
        let transaction = try ExportTransaction(targets: [target])
        try Data("new".utf8).write(to: transaction.stagedFiles[0])
        try Data("other app's file".utf8).write(to: target)
        XCTAssertThrowsError(try transaction.commit(overwrite: false))
        XCTAssertEqual(try Data(contentsOf: target), Data("other app's file".utf8))
    }

    @MainActor
    func testImageExportMarksAllPagesSavedAndAllowsPendingUpdate() async throws {
        let folder = try directory()
        let model = try model(in: folder)
        model.exportFormat = .tiff
        model.ocrEnabled = true // Image formats must not invoke OCR.
        model.pages = [ScannedPage(url: try image(in: folder, name: "first", width: 16, height: 12), thumbnail: nil),
                       ScannedPage(url: try image(in: folder, name: "second", width: 9, height: 7), thumbnail: nil)]
        let updater = AppUpdater(model: model)
        let installed = expectation(description: "Update continues after image export")
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installed.fulfill() })
        await model.createOutput()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.hasUnsavedPages)
        XCTAssertEqual(model.savedFiles.map(\.lastPathComponent), ["Document.tiff"])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(model.savedFiles.first) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        await fulfillment(of: [installed], timeout: 1)
    }

    @MainActor
    func testUnreadablePageLeavesNoPartialExportsAndKeepsPagesUnsaved() async throws {
        let folder = try directory()
        let model = try model(in: folder)
        model.exportFormat = .png
        model.pages = [ScannedPage(url: try image(in: folder, name: "first", width: 16, height: 12), thumbnail: nil),
                       ScannedPage(url: folder.appendingPathComponent("missing.png"), thumbnail: nil)]
        await model.createOutput()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.hasUnsavedPages)
        XCTAssertTrue(model.savedFiles.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix("Document") || $0.hasPrefix(".SaneScan-export") })
    }

    @MainActor
    func testOverwriteConfirmationKeepsOriginalFormatNameAndFolder() async throws {
        let folder = try directory()
        let model = try model(in: folder)
        model.exportFormat = .png
        model.pages = [ScannedPage(url: try image(in: folder, name: "first", width: 16, height: 12), thumbnail: nil),
                       ScannedPage(url: try image(in: folder, name: "second", width: 9, height: 7), thumbnail: nil)]
        let existing = folder.appendingPathComponent("Document-002.png")
        try Data("original".utf8).write(to: existing)
        await model.createOutput()
        XCTAssertEqual(model.overwriteCandidates, [existing])
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
        model.exportFormat = .jpeg
        model.documentName = "Changed"
        model.outputFolder = folder.appendingPathComponent("elsewhere")
        let saved = expectation(description: "Confirmed export finished")
        let observation = model.$savedFiles.filter { !$0.isEmpty }.sink { _ in saved.fulfill() }
        let confirm = model.confirmExportOverwriteAction
        // Simulate SwiftUI dismissing the dialog before its action runs.
        model.cancelExportOverwrite()
        confirm()
        await fulfillment(of: [saved], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.savedFiles.map(\.lastPathComponent), ["Document-001.png", "Document-002.png"])
        XCTAssertEqual(model.savedFiles.first?.deletingLastPathComponent(), folder)
        XCTAssertNotNil(CGImageSourceCreateWithURL(existing as CFURL, nil))
    }

    @MainActor
    func testFolderCollisionIsNeverReplaced() async throws {
        let folder = try directory()
        let model = try model(in: folder)
        model.exportFormat = .png
        model.pages = [ScannedPage(url: try image(in: folder, name: "first", width: 16, height: 12), thumbnail: nil)]
        let collision = folder.appendingPathComponent("Document.png", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        await model.createOutput()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.overwriteCandidates.isEmpty)
        XCTAssertTrue(model.hasUnsavedPages)
        XCTAssertTrue(FileManager.default.fileExists(atPath: collision.path))
    }
}
