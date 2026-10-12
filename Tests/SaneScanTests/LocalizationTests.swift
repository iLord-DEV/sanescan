import Foundation
import XCTest

/// Every user-facing string literal in the sources must have a German translation.
/// Keys are the English source strings; interpolations become %lld / %@ placeholders.
final class LocalizationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func germanStrings() throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Resources/de.lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    func testGermanTableLoads() throws {
        let strings = try germanStrings()
        XCTAssertGreaterThan(strings.count, 40)
        XCTAssertEqual(strings["Scan Page"], "Seite scannen")
    }

    func testEveryKeyInSourcesIsTranslated() throws {
        let strings = try germanStrings()
        let sources = repoRoot.appendingPathComponent("Sources/SaneScan")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for key in Self.localizedKeys(in: text) {
                let pattern = "^" + NSRegularExpression.escapedPattern(for: key)
                    .replacingOccurrences(of: "\u{0}", with: "%(lld|@|d)") + "$"
                let matches = strings.keys.contains { $0.range(of: pattern, options: .regularExpression) != nil }
                if !matches { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "Missing German translations:\n" + missing.joined(separator: "\n"))
    }

    /// Finds string literals passed to SwiftUI views and `String(localized:)`. Interpolations
    /// are replaced by a NUL placeholder that becomes a format specifier pattern above.
    static func localizedKeys(in source: String) -> Set<String> {
        let prefixes = [
            "Text(\"", "Button(\"", "Label(\"", "Picker(\"", "Toggle(\"", "TextField(\"",
            ".help(\"", ".alert(\"", ".confirmationDialog(\"", "CommandMenu(\"",
            "String(localized: \"", "? \"", ": \"",
        ]
        var keys = Set<String>()
        for prefix in prefixes {
            // Ternary branches (`? "…" : "…"`) also match defaults and parser literals,
            // so only multi-word literals count for them.
            let ternary = prefix == "? \"" || prefix == ": \""
            var searchRange = source.startIndex..<source.endIndex
            while let found = source.range(of: prefix, range: searchRange) {
                if let literal = Self.literal(startingAt: found.upperBound, in: source),
                   Self.looksUserFacing(literal), !ternary || literal.contains(" ") {
                    keys.insert(literal)
                }
                searchRange = found.upperBound..<source.endIndex
            }
        }
        return keys
    }

    /// Filters out SF Symbol names, format strings, defaults keys and tool names.
    private static func looksUserFacing(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        if key.hasPrefix("%.") { return false }
        if key.hasPrefix(" (") { return key.hasSuffix(")") }
        return first.isUppercase || key.hasPrefix("%") || key.hasPrefix("·")
    }

    private static func literal(startingAt start: String.Index, in source: String) -> String? {
        var result = ""
        var index = start
        while index < source.endIndex {
            let char = source[index]
            if char == "\\" {
                let next = source.index(after: index)
                guard next < source.endIndex else { return nil }
                if source[next] == "(" {
                    // Skip the interpolation, honouring nested parentheses.
                    var depth = 0
                    var cursor = next
                    repeat {
                        if source[cursor] == "(" { depth += 1 }
                        if source[cursor] == ")" { depth -= 1 }
                        cursor = source.index(after: cursor)
                    } while depth > 0 && cursor < source.endIndex
                    result.append("\u{0}")
                    index = cursor
                    continue
                }
                result.append(source[next])
                index = source.index(after: next)
                continue
            }
            if char == "\"" { return result }
            result.append(char)
            index = source.index(after: index)
        }
        return nil
    }
}
