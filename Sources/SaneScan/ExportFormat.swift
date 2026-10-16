import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, png, jpeg, tiff

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        default: return rawValue
        }
    }
    var supportsMultiplePages: Bool { self == .pdf || self == .tiff }
    var explanation: String {
        switch self {
        case .pdf: return String(localized: "All pages in one PDF file. OCR adds searchable text.")
        case .tiff: return String(localized: "All pages in one lossless TIFF file.")
        case .png, .jpeg: return String(localized: "One image per page. Multiple pages get numbered file names.")
        }
    }

    static func baseName(_ input: String, fallback: String) -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownExtensions = ["pdf", "png", "jpg", "jpeg", "tif", "tiff"]
        if let suffix = name.range(of: ".", options: .backwards),
           knownExtensions.contains(name[suffix.upperBound...].lowercased()) {
            name = String(name[..<suffix.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = fallback }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    func targets(in folder: URL, baseName: String, pageCount: Int) -> [URL] {
        guard pageCount > 0 else { return [] }
        if supportsMultiplePages || pageCount == 1 {
            return [folder.appendingPathComponent(baseName + "." + fileExtension)]
        }
        return (1...pageCount).map { index in
            folder.appendingPathComponent(baseName + String(format: "-%03d.", index) + fileExtension)
        }
    }
}
