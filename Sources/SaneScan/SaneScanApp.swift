import SwiftUI

@main
struct SaneScanApp: App {
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup("SaneScan") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 960, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.requestNewDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.isBusy || model.selectingScanArea)
            }
            CommandMenu("Scan") {
                Button(model.usesFeeder ? "Scan Stack" : "Scan Page") { Task { await model.scanPage() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.selectingScanArea || model.selectedDevice == nil)
                Button("Select Scan Area") { model.selectingScanArea = true }
                    .disabled(!model.canSelectScanArea || model.selectingScanArea)
                Button("Create PDF") { Task { await model.createPDF() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.pages.isEmpty || model.isBusy || model.selectingScanArea)
                Divider()
                Button("Find Scanner") { Task { await model.detectScanner() } }
                    .disabled(model.scannerSearching || model.isBusy || model.selectingScanArea)
            }
        }
    }
}
