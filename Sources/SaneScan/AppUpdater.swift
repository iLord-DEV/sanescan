import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle and postpones installation until the current document is safe.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isInstallingUpdate = false
    @Published var showsPostponedUpdateNotice = false

    private let model: ScanModel
    private var started = false
    private var pendingInstall: (() -> Void)?
    private var documentObservation: AnyCancellable?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )

    init(model: ScanModel) {
        self.model = model
        super.init()
        documentObservation = model.objectWillChange.sink { [weak self] _ in
            // ObservableObject emits before the properties change.
            Task { @MainActor [weak self] in self?.resumeInstallationIfPossible() }
        }
    }

    func start() {
        guard !started, Bundle.main.bundleURL.pathExtension == "app" else { return }
        started = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates, !model.isBusy, !model.selectingScanArea else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        pendingInstall = nil
        isInstallingUpdate = false
        showsPostponedUpdateNotice = false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Sparkle asks its postponement delegate only once per installation.
        // A second install request must not bypass the pending document check.
        pendingInstall == nil || canInstallUpdate
    }

    var canInstallUpdate: Bool {
        !model.isBusy && !model.selectingScanArea && !model.hasUnsavedPages
    }

    /// Kept separate from Sparkle's callback so document protection can be tested.
    func postponeInstallationIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard !canInstallUpdate else {
            isInstallingUpdate = true
            return false
        }
        pendingInstall = installHandler
        showsPostponedUpdateNotice = true
        return true
    }

    private func resumeInstallationIfPossible() {
        guard canInstallUpdate, let install = pendingInstall else { return }
        pendingInstall = nil
        isInstallingUpdate = true
        showsPostponedUpdateNotice = false
        install()
    }
}
