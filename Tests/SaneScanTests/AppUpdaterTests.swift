import XCTest
@testable import SaneScan

final class AppUpdaterTests: XCTestCase {
    @MainActor
    private func makeModel() throws -> ScanModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "SaneScanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        return ScanModel(defaults: defaults, temporaryDirectory: directory)
    }

    @MainActor
    func testEmptyDocumentCanInstallWithoutPostponing() async throws {
        let model = try makeModel()
        let updater = AppUpdater(model: model)
        XCTAssertTrue(updater.canInstallUpdate)
        XCTAssertFalse(updater.postponeInstallationIfNeeded { XCTFail("Sparkle owns immediate installation") })
        XCTAssertFalse(updater.showsPostponedUpdateNotice)
    }

    @MainActor
    func testUnsavedPagesPostponeRestartUntilDocumentIsCleared() async throws {
        let model = try makeModel()
        let page = ScannedPage(url: URL(fileURLWithPath: "/unused-test-page.png"), thumbnail: nil)
        model.pages = [page]
        let updater = AppUpdater(model: model)
        let installed = expectation(description: "Install after document is cleared")
        installed.assertForOverFulfill = true
        XCTAssertTrue(model.hasUnsavedPages)
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installed.fulfill() })
        XCTAssertTrue(updater.showsPostponedUpdateNotice)
        model.pages = []
        await fulfillment(of: [installed], timeout: 1)
        XCTAssertFalse(updater.showsPostponedUpdateNotice)
        model.documentName = "Another document"
        await Task.yield()
    }

    @MainActor
    func testPreviewSelectionPostponesRestartEvenWithoutPages() async throws {
        let model = try makeModel()
        let updater = AppUpdater(model: model)
        model.selectingScanArea = true
        let installed = expectation(description: "Install after area selection closes")
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installed.fulfill() })
        model.selectingScanArea = false
        await fulfillment(of: [installed], timeout: 1)
    }

    @MainActor
    func testUnrelatedChangesCannotRestartWithUnsavedPages() async throws {
        let model = try makeModel()
        model.pages = [ScannedPage(url: URL(fileURLWithPath: "/unused-test-page.png"), thumbnail: nil)]
        let updater = AppUpdater(model: model)
        let installed = expectation(description: "Must not restart")
        installed.isInverted = true
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installed.fulfill() })
        model.documentName = "Unfinished scan"
        model.selectingScanArea = false
        await fulfillment(of: [installed], timeout: 0.05)
        XCTAssertFalse(updater.canInstallUpdate)
    }

    @MainActor
    func testSparkleRecognizesTheInstallationProtectionDelegate() async throws {
        let updater = AppUpdater(model: try makeModel())
        XCTAssertTrue(updater.responds(to: NSSelectorFromString(
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:"
        )))
        XCTAssertTrue(updater.responds(to: NSSelectorFromString("updater:didAbortWithError:")))
    }
}
