import SwiftUI

@main
struct PageScanApp: App {
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup("PageScan") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 960, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neues Dokument") { model.requestNewDocument() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Scannen") {
                Button("Seite scannen") { Task { await model.scanPage() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.scannerName == nil)
                Button("PDF erstellen") { Task { await model.createPDF() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.pages.isEmpty || model.isBusy)
                Divider()
                Button("Scanner suchen") { Task { await model.detectScanner() } }
                    .disabled(model.scannerSearching)
            }
        }
    }
}
