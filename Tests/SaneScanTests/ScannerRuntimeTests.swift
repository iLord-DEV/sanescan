import XCTest
@testable import SaneScan

final class ScannerRuntimeTests: XCTestCase {
    private func runtime() throws -> ScannerRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Scanner Runtime \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ScannerRuntime(root: root, userConfiguration: nil)
    }

    func testMissingBundleNeverFallsBackToInstalledHomebrewTools() throws {
        let runtime = try runtime()
        XCTAssertNil(Tools.locate("scanimage", runtime: runtime))
        XCTAssertNil(Tools.locate("magick", runtime: runtime))
        XCTAssertNil(Tools.locate("ocrmypdf", runtime: runtime))
    }

    func testChildEnvironmentUsesOnlyPrivateScannerPaths() throws {
        let runtime = try runtime()
        let environment = runtime.environment(base: ["PATH": "/opt/homebrew/bin", "SANE_CONFIG_DIR": "/old/config",
            "LD_LIBRARY_PATH": "/old/lib", "DYLD_LIBRARY_PATH": "/old/dyld", "LANG": "de_DE.UTF-8"])
        XCTAssertEqual(environment["PATH"], runtime.root.appendingPathComponent("bin").path + ":/usr/bin:/bin")
        XCTAssertEqual(environment["SANE_CONFIG_DIR"], runtime.root.appendingPathComponent("etc/sane.d").path)
        XCTAssertEqual(environment["LD_LIBRARY_PATH"], runtime.root.appendingPathComponent("lib/sane").path)
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        XCTAssertEqual(environment["LANG"], "de_DE.UTF-8")
    }

    func testUserConfigCanOverrideDefaultsWithoutACompiledInFallback() throws {
        var runtime = try runtime()
        let configuration = runtime.root.appendingPathComponent("user-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        runtime.userConfiguration = configuration
        let directories = try XCTUnwrap(runtime.environment(base: [:])["SANE_CONFIG_DIR"])
        XCTAssertEqual(directories, configuration.path + ":" + runtime.root.appendingPathComponent("etc/sane.d").path)
        XCTAssertFalse(directories.hasSuffix(":"))
    }

    func testBundledExecutableRunsWithSpacesInItsPath() async throws {
        let runtime = try runtime()
        let executable = runtime.root.appendingPathComponent("bin/scanimage")
        try "#!/bin/sh\n/usr/bin/printf '%s' \"$SANE_CONFIG_DIR\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let result = try await Tools.run("scanimage", [], runtime: runtime)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, runtime.root.appendingPathComponent("etc/sane.d").path)
    }
}
