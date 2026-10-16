import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import SaneScan

final class PDFExporterTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(in directory: URL) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 600, bitsPerComponent: 8,
            bytesPerRow: 1600 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.textPosition = CGPoint(x: 80, y: 350)
        let text = NSAttributedString(string: "RECHNUNG 12345",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String):
                         CTFontCreateWithName("Helvetica" as CFString, 110, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let url = directory.appendingPathComponent("fixture.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixels(_ url: URL) throws -> Data {
        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(pdf.page(at: 1))
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 300, bitsPerComponent: 8,
            bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.concatenate(page.getDrawingTransform(.mediaBox,
            rect: CGRect(x: 0, y: 0, width: 800, height: 300), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return Data(bytes: try XCTUnwrap(context.data), count: 800 * 300 * 4)
    }

    func testNativePDFHasCorrectPageCountPhysicalSizeAndJPEGCompression() throws {
        let folder = try directory()
        let image = try fixture(in: folder)
        let output = folder.appendingPathComponent("plain.pdf")
        XCTAssertFalse(try PDFExporter.write(pages: [image, image], dpi: 300, performOCR: false,
            destination: output, recognize: { _ in XCTFail("OCR must be disabled"); return [] }))
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 384, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 144, accuracy: 0.01)
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: Data("/DCTDecode".utf8)))
    }

    func testSearchableTextIsInvisibleAndPositionedOverItsImageRegion() throws {
        let folder = try directory()
        let image = try fixture(in: folder)
        let plain = folder.appendingPathComponent("plain.pdf")
        let searchable = folder.appendingPathComponent("searchable.pdf")
        _ = try PDFExporter.write(pages: [image], dpi: 300, performOCR: false, destination: plain)
        _ = try PDFExporter.write(pages: [image], dpi: 300, performOCR: true, destination: searchable) { _ in
            [RecognizedLine(text: "Grüße aus Berlin 98765", bounds: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.15))]
        }
        let document = try XCTUnwrap(PDFDocument(url: searchable))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Grüße aus Berlin 98765"))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("Berlin", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        XCTAssertGreaterThan(bounds.minX, 0)
        XCTAssertLessThan(bounds.maxY, page.bounds(for: .mediaBox).height / 2)
        XCTAssertEqual(try pixels(plain), try pixels(searchable))
    }

    func testOCRFailureKeepsEveryPageAndReportsAnIncompleteTextLayer() throws {
        let folder = try directory()
        let image = try fixture(in: folder)
        let output = folder.appendingPathComponent("fallback.pdf")
        let incomplete = try PDFExporter.write(pages: [image, image], dpi: 300, performOCR: true,
            destination: output, recognize: { _ in throw CocoaError(.featureUnsupported) })
        XCTAssertTrue(incomplete)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: output)).pageCount, 2)
    }

    func testVisionRecognizesTextWithoutExternalPrograms() throws {
        let folder = try directory()
        let image = try fixture(in: folder)
        let output = folder.appendingPathComponent("vision.pdf")
        XCTAssertFalse(try PDFExporter.write(pages: [image], dpi: 300, performOCR: true, destination: output))
        let text = try XCTUnwrap(PDFDocument(url: output)?.string)
        XCTAssertTrue(text.contains("RECHNUNG"), text)
        XCTAssertTrue(text.contains("12345"), text)
    }
}
