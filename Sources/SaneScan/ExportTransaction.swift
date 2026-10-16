import Foundation

enum ExportError: LocalizedError {
    case folderAtTarget(URL)
    case recoveryNeeded(URL)

    var errorDescription: String? {
        switch self {
        case .folderAtTarget(let url):
            return String(localized: "A folder already exists at \(url.path). Choose another file name.")
        case .recoveryNeeded(let url):
            return String(localized: "The export could not be restored completely. Your original files are kept in \(url.path).")
        }
    }
}

/// Prepare every file before changing the destination. Keep originals for rollback.
final class ExportTransaction {
    let targets: [URL]
    let directory: URL
    let stagedFiles: [URL]
    private let backupDirectory: URL
    private var keepsRecoveryFiles = false

    static func existingTargets(_ targets: [URL]) throws -> [URL] {
        try targets.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue { throw ExportError.folderAtTarget(url) }
            return exists
        }
    }

    init(targets: [URL]) throws {
        guard let first = targets.first else { throw CocoaError(.fileWriteUnknown) }
        self.targets = targets
        directory = first.deletingLastPathComponent()
            .appendingPathComponent(".SaneScan-export-\(UUID().uuidString)", isDirectory: true)
        let newDirectory = directory.appendingPathComponent("new", isDirectory: true)
        backupDirectory = directory.appendingPathComponent("originals", isDirectory: true)
        stagedFiles = targets.map { newDirectory.appendingPathComponent($0.lastPathComponent) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        if !keepsRecoveryFiles { try? FileManager.default.removeItem(at: directory) }
    }

    func commit(
        overwrite: Bool,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let existing = try Self.existingTargets(targets)
        if !overwrite, let first = existing.first {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: first.path])
        }
        for source in stagedFiles where !FileManager.default.fileExists(atPath: source.path) {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        var installed: [URL] = []
        var originals: [(target: URL, backup: URL)] = []
        do {
            for (source, target) in zip(stagedFiles, targets) {
                if FileManager.default.fileExists(atPath: target.path) {
                    // Recheck each file: another app could have created one during export.
                    guard overwrite else { throw CocoaError(.fileWriteFileExists) }
                    _ = try Self.existingTargets([target])
                    let backup = backupDirectory.appendingPathComponent(target.lastPathComponent)
                    try move(target, backup)
                    originals.append((target, backup))
                }
                try move(source, target)
                installed.append(target)
            }
        } catch {
            var recoveryFailed = false
            for target in installed.reversed() {
                do { try FileManager.default.removeItem(at: target) } catch { recoveryFailed = true }
            }
            for original in originals.reversed() {
                do { try move(original.backup, original.target) } catch { recoveryFailed = true }
            }
            if recoveryFailed {
                keepsRecoveryFiles = true
                throw ExportError.recoveryNeeded(directory)
            }
            throw error
        }
    }
}
