import SwiftUI

@main
struct SaneScanApp: App {
    @StateObject private var model: ScanModel
    @StateObject private var updater: AppUpdater

    init() {
        let model = ScanModel()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: AppUpdater(model: model))
    }

    var body: some Scene {
        WindowGroup("SaneScan") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .disabled(updater.isInstallingUpdate)
                .task { updater.start() }
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 960, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates || model.isBusy || model.selectingScanArea || updater.isInstallingUpdate)
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.requestNewDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.isBusy || model.selectingScanArea || updater.isInstallingUpdate)
            }
            CommandMenu("Scan") {
                Button(model.usesFeeder ? "Scan Stack" : "Scan Page") { Task { await model.scanPage() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.selectingScanArea || updater.isInstallingUpdate || model.selectedDevice == nil)
                Button("Select Scan Area") { model.selectingScanArea = true }
                    .disabled(!model.canSelectScanArea || model.selectingScanArea || updater.isInstallingUpdate)
                Button("Create PDF") { Task { await model.createPDF() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.pages.isEmpty || model.isBusy || model.selectingScanArea || updater.isInstallingUpdate)
                Divider()
                Button("Find Scanner") { Task { await model.detectScanner() } }
                    .disabled(model.scannerSearching || model.isBusy || model.selectingScanArea || updater.isInstallingUpdate)
            }
        }
    }
}
