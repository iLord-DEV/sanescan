import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO exports run off the main thread and need no external image tools.
enum ImageExporter {
    static func write(pages: [URL], format: ExportFormat, dpi: Int, destinations: [URL]) throws {
        guard !pages.isEmpty, format != .pdf,
              destinations.count == (format.supportsMultiplePages ? 1 : pages.count) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let type: CFString
        switch format {
        case .png: type = UTType.png.identifier as CFString
        case .jpeg: type = UTType.jpeg.identifier as CFString
        case .tiff: type = UTType.tiff.identifier as CFString
        case .pdf: throw CocoaError(.fileWriteUnknown)
        }
        for (index, url) in destinations.enumerated() {
            let sources = format.supportsMultiplePages ? pages : [pages[index]]
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, sources.count, nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            for sourceURL in sources {
                try autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
                    }
                    var properties: [CFString: Any] = [
                        kCGImagePropertyDPIWidth: dpi,
                        kCGImagePropertyDPIHeight: dpi,
                    ]
                    if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
                    if format == .tiff {
                        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
                    }
                    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(destination) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
    }
}
