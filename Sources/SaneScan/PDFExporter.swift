import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A recognized line in Vision's normalized, bottom-left image coordinates.
struct RecognizedLine {
    let text: String
    let bounds: CGRect
}

/// Creates image PDFs with a searchable, invisible text layer using macOS only.
enum PDFExporter {
    /// Returns true if any OCR request failed. The page images are still saved.
    static func write(
        pages: [URL], dpi: Int, performOCR: Bool, destination: URL,
        recognize: (CGImage) throws -> [RecognizedLine] = recognizeText
    ) throws -> Bool {
        guard !pages.isEmpty, dpi > 0 else { throw CocoaError(.fileWriteUnknown) }
        guard let context = CGContext(destination as CFURL, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var ocrIncomplete = false
        do {
            for url in pages {
                try autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
                    }
                    let bounds = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / Double(dpi),
                                        height: Double(image.height) * 72 / Double(dpi))
                    let pageInfo = [kCGPDFContextMediaBox: boxData(bounds)] as CFDictionary
                    context.beginPDFPage(pageInfo)
                    context.draw(try compressedImage(image), in: bounds)
                    if performOCR {
                        do {
                            for line in try recognize(image) { drawInvisible(line, on: bounds, in: context) }
                        } catch {
                            ocrIncomplete = true
                        }
                    }
                    context.endPDFPage()
                }
            }
            context.closePDF()
        } catch {
            context.closePDF()
            throw error
        }
        // Core Graphics has no throwing close/finalize API. Verify the completed
        // document before allowing the export transaction to replace any files.
        guard let result = CGPDFDocument(destination as CFURL), result.numberOfPages == pages.count else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        return ocrIncomplete
    }

    static func recognizeText(in image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["de-DE", "en-US"].filter { supported.contains($0) }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return RecognizedLine(text: candidate.string, bounds: observation.boundingBox)
        }
    }

    private static func compressedImage(_ image: CGImage) throws -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: data),
              let compressed = CGImage(jpegDataProviderSource: provider, decode: nil,
                                       shouldInterpolate: true, intent: .defaultIntent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return compressed
    }

    private static func boxData(_ box: CGRect) -> CFData {
        var value = box
        return Data(bytes: &value, count: MemoryLayout<CGRect>.size) as CFData
    }

    private static func drawInvisible(_ recognized: RecognizedLine, on page: CGRect, in context: CGContext) {
        let clipped = recognized.bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
        let bounds = CGRect(x: clipped.minX * page.width, y: clipped.minY * page.height,
                            width: clipped.width * page.width, height: clipped.height * page.height)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let string = NSAttributedString(string: recognized.text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        guard width > 0, ascent + descent > 0 else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / width, y: bounds.height / (ascent + descent))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: descent)
        context.setTextDrawingMode(.invisible)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
