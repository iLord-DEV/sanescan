import Foundation

/// A rectangle on the glass, measured from its top-left corner in millimetres.
struct ScanArea: Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double
    var height: Double

    var arguments: [String] {
        ["-l", Self.format(x), "-t", Self.format(y),
         "-x", Self.format(width), "-y", Self.format(height)]
    }

    private static func format(_ value: Double) -> String {
        // Round down so a selection touching the glass edge cannot exceed it.
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
               floor((value + 1e-9) * 1000) / 1000)
    }
}

/// Resolution-independent selection in top-left image coordinates (0...1).
struct ScanSelection: Equatable {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }

        var label: String {
            switch self {
            case .topLeft: return String(localized: "Top left")
            case .topRight: return String(localized: "Top right")
            case .bottomLeft: return String(localized: "Bottom left")
            case .bottomRight: return String(localized: "Bottom right")
            }
        }
    }

    private(set) var rect: CGRect
    static let minimumSpan = 0.01
    static let full = ScanSelection(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    init(rect: CGRect) {
        let left = min(max(rect.minX, 0), 1 - Self.minimumSpan)
        let top = min(max(rect.minY, 0), 1 - Self.minimumSpan)
        let right = min(max(rect.maxX, left + Self.minimumSpan), 1)
        let bottom = min(max(rect.maxY, top + Self.minimumSpan), 1)
        self.rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    init(area: ScanArea, bed: ScanArea) {
        self.init(rect: CGRect(x: area.x / bed.width, y: area.y / bed.height,
                              width: area.width / bed.width, height: area.height / bed.height))
    }

    func point(for corner: Corner) -> CGPoint {
        CGPoint(x: corner.isLeft ? rect.minX : rect.maxX,
                y: corner.isTop ? rect.minY : rect.maxY)
    }

    mutating func move(_ corner: Corner, to point: CGPoint) {
        let left = corner.isLeft ? min(max(point.x, 0), rect.maxX - Self.minimumSpan) : rect.minX
        let right = corner.isLeft ? rect.maxX : max(min(point.x, 1), rect.minX + Self.minimumSpan)
        let top = corner.isTop ? min(max(point.y, 0), rect.maxY - Self.minimumSpan) : rect.minY
        let bottom = corner.isTop ? rect.maxY : max(min(point.y, 1), rect.minY + Self.minimumSpan)
        rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func area(on bed: ScanArea) -> ScanArea {
        ScanArea(x: rect.minX * bed.width, y: rect.minY * bed.height,
                 width: rect.width * bed.width, height: rect.height * bed.height)
    }
}
