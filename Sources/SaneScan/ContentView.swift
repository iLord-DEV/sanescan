import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var updater: AppUpdater

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
        .sheet(isPresented: $model.selectingScanArea) {
            if let bed = model.fullScanArea {
                ScanAreaSheet(bed: bed, initialArea: model.effectiveScanArea ?? bed)
                    .environmentObject(model)
            }
        }
        .alert("Update ready", isPresented: $updater.showsPostponedUpdateNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The update will be installed after the current scan finishes and your pages are saved as a PDF or a new document is started.")
        }
        .alert("Error", isPresented: errorPresented, presenting: model.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("PDF saved", isPresented: savedPresented, presenting: model.savedPDF) { url in
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("New Document") { model.newDocument() }
            Button("OK", role: .cancel) {}
        } message: { url in
            Text(url.path)
        }
        .confirmationDialog(
            "Replace file?",
            isPresented: overwritePresented,
            presenting: model.overwriteCandidate
        ) { url in
            Button("Replace", role: .destructive) {
                Task { await model.createPDF(overwrite: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().lastPathComponent).")
        }
        .confirmationDialog(
            "Discard all scanned pages?",
            isPresented: $model.confirmNewDocument
        ) {
            Button("Discard", role: .destructive) { model.newDocument() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pages have not been saved as a PDF yet.")
        }
    }

    // MARK: - Sections

    private var scannerStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.selectedDevice != nil ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            if model.devices.count > 1 {
                Picker("Scanner", selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .fixedSize()
                .disabled(model.isBusy)
                Text("connected")
            } else {
                Text(scannerStatusText)
            }
            if let area = model.scanAreaDescription {
                Text("· Scan area \(area)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Search Again") {
                Task { await model.detectScanner() }
            }
            .disabled(model.scannerSearching || model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var scannerStatusText: String {
        if let name = model.scannerName { return String(localized: "\(name) connected") }
        return model.scannerSearching
            ? String(localized: "Searching for scanner…")
            : String(localized: "No scanner found")
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
                    Text("Page \(index + 1)")
                }
                .padding(.vertical, 2)
                .accessibilityLabel(Text("Page \(index + 1)"))
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
                Text("No pages yet")
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
                    if model.usesFeeder {
                        Text("Load pages into the feeder and press “Scan Stack”")
                    } else {
                        Text("Place a page on the glass and press “Scan Page”")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                TextField("File name", text: $model.documentName, prompt: Text(model.resolvedFileName))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Toggle("Text layer (OCR)", isOn: $model.ocrEnabled)
                    .disabled(!model.ocrAvailable)
                    .help(model.ocrAvailable ? "Embed searchable text" : "ocrmypdf is not installed")

                Spacer()

                Button {
                    chooseOutputFolder()
                } label: {
                    Label(model.outputFolder.lastPathComponent, systemImage: "folder")
                }
                .help("Output folder: \(model.outputFolder.path)")
                .accessibilityLabel(Text("Choose output folder, currently \(model.outputFolder.lastPathComponent)"))
            }

            HStack(spacing: 16) {
                Picker("Resolution", selection: $model.dpi) {
                    ForEach(model.dpiOptions, id: \.self) { value in
                        Text("\(value) dpi").tag(value)
                    }
                }
                .fixedSize()

                Picker("Mode", selection: $model.colorMode) {
                    ForEach(model.modeOptions, id: \.self) { mode in
                        Text(ScanModeLabel.label(for: mode)).tag(mode)
                    }
                }
                .fixedSize()

                Picker("Paper", selection: paperSelection) {
                    if model.customScanArea != nil {
                        Text("Custom").tag(Optional<PaperSize>.none)
                    }
                    ForEach(PaperSize.allCases) { size in
                        Text(size.label).tag(Optional(size))
                    }
                }
                .fixedSize()
                .help("Scan area, limited to what the scanner can cover")

                Button("Select Area…") { model.selectingScanArea = true }
                    .disabled(!model.canSelectScanArea)
                    .help("Scan a preview and select an area using four corners")

                if model.sourceOptions.count > 1 {
                    Picker("Source", selection: $model.source) {
                        ForEach(model.sourceOptions, id: \.self) { source in
                            Text(source).tag(Optional(source))
                        }
                    }
                    .fixedSize()
                    .help("The flatbed scans one page, the feeder every page loaded")
                }

                Spacer()
            }
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
                if model.usesFeeder {
                    Label("Scan Stack", systemImage: "scanner")
                } else {
                    Label("Scan Page \(model.pages.count + 1)", systemImage: "scanner")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy || model.selectedDevice == nil)

            Button("Remove Page") { model.removeSelected() }
                .disabled(model.selection == nil || model.isBusy)

            Button("New Document") { model.requestNewDocument() }
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
                Label("Create PDF", systemImage: "doc.richtext")
            }
            .disabled(model.pages.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Bindings

    private var paperSelection: Binding<PaperSize?> {
        Binding(
            get: { model.customScanArea == nil ? model.paperSize : nil },
            set: { if let size = $0 { model.paperSize = size } }
        )
    }

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
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Folder for the finished PDFs")
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
                    .accessibilityLabel(Text("Preview of the scanned page"))
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
