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
            return String(localized: "\(tool) is missing from the app. Reinstall SaneScan.")
        case .failed(let tool, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = String(localized: "\(tool) failed with status \(Int(status)).")
            return detail.isEmpty ? message : message + "\n" + detail
        }
    }
}

/// The scanner process and its private configuration and library directories.
struct ScannerRuntime {
    let root: URL
    var userConfiguration: URL?

    static var current: ScannerRuntime {
        let root: URL
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            root = resources.appendingPathComponent("ScannerRuntime", isDirectory: true)
        } else {
            // SwiftPM development runs use the same portable runtime as app builds.
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/scanner-runtime", isDirectory: true)
        }
        let configuration = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("SaneScan/sane.d", isDirectory: true)
        return ScannerRuntime(root: root, userConfiguration: configuration)
    }

    func executable(_ name: String) -> URL? {
        guard name == "scanimage" else { return nil }
        let url = root.appendingPathComponent("bin/scanimage")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func environment(base: [String: String]) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("DYLD_") && $0.key != "LD_PRELOAD" }
        environment["PATH"] = [root.appendingPathComponent("bin").path, "/usr/bin", "/bin"].joined(separator: ":")
        environment["LD_LIBRARY_PATH"] = root.appendingPathComponent("lib/sane").path
        var directories = [root.appendingPathComponent("etc/sane.d").path]
        if let userConfiguration, FileManager.default.fileExists(atPath: userConfiguration.path) {
            directories.insert(userConfiguration.path, at: 0)
        }
        // No trailing colon: that would re-enable SANE's compiled-in defaults.
        environment["SANE_CONFIG_DIR"] = directories.joined(separator: ":")
        return environment
    }
}

/// Runs only the scanner bundled with the app; never falls back to Homebrew.
enum Tools {
    static func locate(_ name: String, runtime: ScannerRuntime = .current) -> URL? {
        runtime.executable(name)
    }

    /// Runs a tool off the main thread and returns its output.
    static func run(_ name: String, _ arguments: [String], runtime: ScannerRuntime = .current) async throws -> CommandResult {
        guard let executable = locate(name, runtime: runtime) else { throw ToolError.missing(name) }
        let environment = runtime.environment(base: ProcessInfo.processInfo.environment)
        return try await Task.detached(priority: .userInitiated) {
            try runSync(executable: executable, arguments: arguments, environment: environment)
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

    private static func runSync(executable: URL, arguments: [String], environment: [String: String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

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
