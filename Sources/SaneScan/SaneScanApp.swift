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
            }
            CommandMenu("Scan") {
                Button(model.usesFeeder ? "Scan Stack" : "Scan Page") { Task { await model.scanPage() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.selectedDevice == nil)
                Button("Create PDF") { Task { await model.createPDF() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.pages.isEmpty || model.isBusy)
                Divider()
                Button("Find Scanner") { Task { await model.detectScanner() } }
                    .disabled(model.scannerSearching)
            }
        }
    }
}
