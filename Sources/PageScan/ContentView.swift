import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(spacing: 0) {
            scannerStatusBar
            Divider()
            HSplitView {
                pageList
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 300, maxHeight: .infinity)
                preview
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            settingsBar
            Divider()
            actionBar
        }
        .task { await model.detectScanner() }
        .alert("Fehler", isPresented: errorPresented, presenting: model.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("PDF gespeichert", isPresented: savedPresented, presenting: model.savedPDF) { url in
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Neues Dokument") { model.newDocument() }
            Button("OK", role: .cancel) {}
        } message: { url in
            Text(url.path)
        }
        .confirmationDialog(
            "Datei ersetzen?",
            isPresented: overwritePresented,
            presenting: model.overwriteCandidate
        ) { url in
            Button("Ersetzen", role: .destructive) {
                Task { await model.createPDF(overwrite: true) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { url in
            Text("\(url.lastPathComponent) existiert bereits in \(url.deletingLastPathComponent().lastPathComponent).")
        }
        .confirmationDialog(
            "Alle gescannten Seiten verwerfen?",
            isPresented: $model.confirmNewDocument
        ) {
            Button("Verwerfen", role: .destructive) { model.newDocument() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Seiten wurden noch nicht als PDF gespeichert.")
        }
    }

    // MARK: - Sections

    private var scannerStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.scannerName != nil ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(scannerStatusText)
            Spacer()
            Button("Erneut suchen") {
                Task { await model.detectScanner() }
            }
            .disabled(model.scannerSearching)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var scannerStatusText: String {
        if let name = model.scannerName { return "\(name) verbunden" }
        return model.scannerSearching ? "Suche Scanner …" : "Kein Scanner gefunden"
    }

    private var pageList: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                HStack(spacing: 12) {
                    Group {
                        if let thumbnail = page.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "doc")
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                        }
                    }
                    .frame(width: 56, height: 72)
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
                    Text("Seite \(index + 1)")
                }
                .padding(.vertical, 2)
                .accessibilityLabel("Seite \(index + 1)")
                .tag(page.id)
            }
            .onMove { source, destination in
                model.movePages(from: source, to: destination)
            }
            .onDelete { indices in
                for index in indices.sorted(by: >) {
                    model.selection = model.pages[index].id
                    model.removeSelected()
                }
            }
        }
        .onDeleteCommand { model.removeSelected() }
        .overlay {
            if model.pages.isEmpty {
                Text("Noch keine Seiten")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preview: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let page = model.pages.first(where: { $0.id == model.selection }) {
                PagePreview(url: page.url)
                    .padding(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "scanner")
                        .font(.system(size: 48))
                    Text("Seite einlegen und „Seite scannen“ drücken")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 16) {
            TextField("Dateiname", text: $model.documentName, prompt: Text(model.resolvedFileName))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("Auflösung", selection: $model.dpi) {
                ForEach(ScanModel.dpiOptions, id: \.self) { value in
                    Text("\(value) dpi").tag(value)
                }
            }
            .fixedSize()

            Picker("Modus", selection: $model.colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .fixedSize()

            Toggle("Textebene (OCR)", isOn: $model.ocrEnabled)
                .disabled(!model.ocrAvailable)
                .help(model.ocrAvailable ? "Durchsuchbaren Text einbetten" : "ocrmypdf ist nicht installiert")

            Spacer()

            Button {
                chooseOutputFolder()
            } label: {
                Label(model.outputFolder.lastPathComponent, systemImage: "folder")
            }
            .help("Zielordner: \(model.outputFolder.path)")
            .accessibilityLabel("Zielordner wählen, aktuell \(model.outputFolder.lastPathComponent)")
        }
        .disabled(model.isBusy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.scanPage() }
            } label: {
                Label("Seite \(model.pages.count + 1) scannen", systemImage: "scanner")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.scannerName == nil)

            Button("Seite entfernen") { model.removeSelected() }
                .disabled(model.selection == nil || model.isBusy)

            Button("Neues Dokument") { model.requestNewDocument() }
                .disabled(model.pages.isEmpty || model.isBusy)

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                Task { await model.createPDF() }
            } label: {
                Label("PDF erstellen", systemImage: "doc.richtext")
            }
            .disabled(model.pages.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Bindings

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var savedPresented: Binding<Bool> {
        Binding(
            get: { model.savedPDF != nil },
            set: { if !$0 { model.savedPDF = nil } }
        )
    }

    private var overwritePresented: Binding<Bool> {
        Binding(
            get: { model.overwriteCandidate != nil },
            set: { if !$0 { model.overwriteCandidate = nil } }
        )
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.outputFolder
        panel.prompt = "Auswählen"
        panel.message = "Ordner für die fertigen PDFs"
        if panel.runModal() == .OK, let url = panel.url {
            model.outputFolder = url
        }
    }
}

/// Loads the full-size scan off the main thread and shows it scaled to fit.
private struct PagePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .shadow(radius: 4)
                    .accessibilityLabel("Vorschau der gescannten Seite")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            image = loaded
        }
    }
}
