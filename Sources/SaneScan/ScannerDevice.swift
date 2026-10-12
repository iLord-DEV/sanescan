import Foundation

/// A scanner as reported by `scanimage -L`.
struct ScannerDevice: Identifiable, Hashable {
    /// SANE device string, e.g. `genesys:libusb:002:002`.
    let id: String
    /// Human readable name, e.g. `Canon LiDE 210`.
    let name: String

    /// Backend part of the device string, e.g. `genesys`.
    var backend: String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }

    /// Value for `scanimage -d`. Some backends (genesys on macOS among them) re-enumerate the
    /// USB device after every open, so `libusb:002:001` becomes `libusb:002:002` and back. The
    /// bare backend name opens its first device and stays valid, so it is used whenever only
    /// one device of that backend is connected.
    func selector(in devices: [ScannerDevice]) -> String {
        devices.filter { $0.backend == backend }.count == 1 ? backend : id
    }

    /// Parses the output of `scanimage -L`.
    ///
    /// Each line looks like:
    /// ``device `genesys:libusb:002:001' is a Canon LiDE 210 flatbed scanner``
    static func parseList(_ output: String) -> [ScannerDevice] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard let open = line.range(of: "device `"),
                  let close = line.range(of: "' is a ", range: open.upperBound..<line.endIndex)
            else { return nil }
            let id = String(line[open.upperBound..<close.lowerBound])
            var name = String(line[close.upperBound...])
            for suffix in [" flatbed scanner", " multi-function peripheral", " scanner"]
            where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
            return ScannerDevice(id: id, name: name.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// What a scanner can do, parsed from `scanimage -A`.
struct ScannerCapabilities: Equatable {
    /// Values of `--mode`, in the order the backend lists them.
    var modes: [String] = []
    /// Values of `--source` (Flatbed, ADF, ...). Empty if the backend has no such option.
    var sources: [String] = []
    /// Selectable resolutions in dpi, ascending.
    var resolutions: [Int] = []
    /// Maximum scan width in millimetres (`-x`).
    var maxWidth: Double?
    /// Maximum scan height in millimetres (`-y`).
    var maxHeight: Double?

    /// Standard resolutions offered when the backend reports a range instead of a list.
    static let standardResolutions = [75, 100, 150, 200, 300, 400, 600, 1200, 2400, 4800]

    var hasFeeder: Bool { feederSource != nil }

    /// The first source that looks like an automatic document feeder.
    var feederSource: String? {
        sources.first(where: Self.isFeeder)
    }

    static func isFeeder(_ source: String) -> Bool {
        let lower = source.lowercased()
        return lower.contains("adf") || lower.contains("feeder") || lower.contains("automatic")
    }

    /// Parses the option listing printed by `scanimage -A` (or `--help`).
    ///
    /// Relevant lines look like:
    /// ```
    ///     --mode Color|Gray [Gray]
    ///     --source Flatbed|ADF [Flatbed]
    ///     --resolution 4800|2400|1200|600|300|150|100|75dpi [75]
    ///     --resolution 50..600dpi (in steps of 1) [300]
    ///     -x 0..216.7mm [216.7]
    ///     -y 0..297.5mm [297.5]
    /// ```
    static func parse(_ output: String) -> ScannerCapabilities {
        var caps = ScannerCapabilities()
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") else { continue }
            // Split "--option VALUES [default] ..." into option and the value spec.
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let option = String(parts[0])
            let spec = String(parts[1])
            switch option {
            case "--mode":
                caps.modes = choices(in: spec)
            case "--source":
                caps.sources = choices(in: spec)
            case "--resolution":
                caps.resolutions = resolutions(in: spec)
            case "-x":
                caps.maxWidth = rangeMaximum(in: spec)
            case "-y":
                caps.maxHeight = rangeMaximum(in: spec)
            default:
                continue
            }
        }
        return caps
    }

    /// `Color|Gray [Gray]` -> `["Color", "Gray"]`
    private static func choices(in spec: String) -> [String] {
        valueSpec(spec).split(separator: "|").map { String($0) }.filter { !$0.isEmpty }
    }

    /// `4800|2400|...|75dpi [75]` or `50..600dpi (in steps of 1) [300]` -> ascending dpi values.
    private static func resolutions(in spec: String) -> [Int] {
        var value = valueSpec(spec)
        if value.hasSuffix("dpi") { value = String(value.dropLast(3)) }
        if let range = numericRange(value) {
            let lower = Int(range.lowerBound.rounded(.up))
            let upper = Int(range.upperBound.rounded(.down))
            let standard = standardResolutions.filter { $0 >= lower && $0 <= upper }
            return standard.isEmpty ? [max(lower, 1)] : standard
        }
        let values = value.split(separator: "|").compactMap { Double($0) }.map { Int($0.rounded()) }
        return Array(Set(values)).sorted()
    }

    /// `0..216.7mm [216.7]` -> 216.7
    private static func rangeMaximum(in spec: String) -> Double? {
        var value = valueSpec(spec)
        for unit in ["mm", "pel"] where value.hasSuffix(unit) {
            value = String(value.dropLast(unit.count))
        }
        return numericRange(value)?.upperBound
    }

    /// The value part of the spec without the `[default]`, `(in steps of n)` and
    /// `[advanced]` decorations. Choices may contain spaces ("ADF Duplex").
    private static func valueSpec(_ spec: String) -> String {
        var value = spec
        if let bracket = value.range(of: " [") {
            value = String(value[..<bracket.lowerBound])
        }
        if let steps = value.range(of: " (in steps of") {
            value = String(value[..<steps.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// `0..216.7` -> 0...216.7
    private static func numericRange(_ value: String) -> ClosedRange<Double>? {
        let bounds = value.components(separatedBy: "..")
        guard bounds.count == 2, let lower = Double(bounds[0]), let upper = Double(bounds[1]),
              lower <= upper
        else { return nil }
        return lower...upper
    }
}

/// Scan area presets. The effective size is clamped to what the device supports.
enum PaperSize: String, CaseIterable, Identifiable {
    case a4, a5, letter, legal, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .full: return String(localized: "Full bed")
        }
    }

    /// Nominal size in millimetres; nil means "use the device maximum".
    var millimetres: (width: Double, height: Double)? {
        switch self {
        case .a4: return (210, 297)
        case .a5: return (148, 210)
        case .letter: return (215.9, 279.4)
        case .legal: return (215.9, 355.6)
        case .full: return nil
        }
    }

    /// Width and height to pass to `scanimage -x/-y`, limited to the device area.
    func scanArea(for caps: ScannerCapabilities) -> (width: Double, height: Double)? {
        let maxWidth = caps.maxWidth
        let maxHeight = caps.maxHeight
        guard let nominal = millimetres else {
            // Full bed: only pass explicit values when the device told us its limits.
            if let maxWidth, let maxHeight { return (maxWidth, maxHeight) }
            return nil
        }
        return (
            min(nominal.width, maxWidth ?? nominal.width),
            min(nominal.height, maxHeight ?? nominal.height)
        )
    }
}

/// Readable labels for the mode names SANE backends commonly use.
enum ScanModeLabel {
    enum Kind: Int {
        case gray = 0, color, lineart, halftone, other
    }

    static func kind(of mode: String) -> Kind {
        switch mode.lowercased() {
        case "gray", "grayscale", "grey", "greyscale", "true gray": return .gray
        case "color", "colour", "24bit color", "24bit color (fast)": return .color
        case "lineart", "line art", "black & white", "binary": return .lineart
        case "halftone": return .halftone
        default: return .other
        }
    }

    static func label(for mode: String) -> String {
        switch kind(of: mode) {
        case .gray: return String(localized: "Grayscale")
        case .color: return String(localized: "Color")
        case .lineart: return String(localized: "Black & White")
        case .halftone: return String(localized: "Halftone")
        case .other: return mode
        }
    }

    /// Preference order when picking a default mode for documents: gray, color, lineart.
    static func preferredMode(from modes: [String]) -> String? {
        modes.min { kind(of: $0).rawValue < kind(of: $1).rawValue }
    }
}
