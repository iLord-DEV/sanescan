import Foundation

/// Result of an external command.
struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum ToolError: LocalizedError {
    case missing(String)
    case failed(tool: String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .missing(let tool):
            let hint = Tools.installHints[tool] ?? "brew install \(tool)"
            return String(localized: "\(tool) was not found. Install it with: \(hint)")
        case .failed(let tool, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = String(localized: "\(tool) failed with status \(Int(status)).")
            return detail.isEmpty ? message : message + "\n" + detail
        }
    }
}

/// Locates and runs the Homebrew command line tools the app depends on.
enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static let installHints: [String: String] = [
        "scanimage": "brew install sane-backends",
        "magick": "brew install imagemagick",
        "ocrmypdf": "brew install ocrmypdf tesseract-lang",
    ]

    static func locate(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func isAvailable(_ name: String) -> Bool {
        locate(name) != nil
    }

    /// Runs a tool off the main thread and returns its output.
    static func run(_ name: String, _ arguments: [String]) async throws -> CommandResult {
        guard let executable = locate(name) else { throw ToolError.missing(name) }
        return try await Task.detached(priority: .userInitiated) {
            try runSync(executable: executable, arguments: arguments)
        }.value
    }

    /// Runs a tool and throws if it exits with a non-zero status.
    @discardableResult
    static func runChecked(_ name: String, _ arguments: [String]) async throws -> CommandResult {
        let result = try await run(name, arguments)
        guard result.succeeded else {
            throw ToolError.failed(tool: name, status: result.status, stderr: result.stderr)
        }
        return result
    }

    private static func runSync(executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // The app bundle starts with a minimal PATH; ocrmypdf needs tesseract and gs on it.
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (searchPaths + existing).joined(separator: ":")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain stderr concurrently so neither pipe can fill up and block the child.
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
