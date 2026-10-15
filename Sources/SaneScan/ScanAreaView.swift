import AppKit
import SwiftUI

struct ScanAreaSheet: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    let bed: ScanArea
    @State private var selection: ScanSelection
    @State private var image: NSImage?
    @State private var errorMessage: String?

    init(bed: ScanArea, initialArea: ScanArea) {
        self.bed = bed
        _selection = State(initialValue: ScanSelection(area: initialArea, bed: bed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Scan Area")
                .font(.title2.bold())
            Text("Drag the four corners to select the scan area. Use the arrow keys to adjust a focused corner.")
                .foregroundStyle(.secondary)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    ScanSelectionView(image: image, selection: $selection)
                        .padding(20)
                        .disabled(model.isBusy)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                if model.isBusy {
                    ProgressView("Scanning preview…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Scan area: \(areaDescription)")
                .monospacedDigit()

            HStack {
                Button("Scan Preview") { Task { await refreshPreview() } }
                    .disabled(model.isBusy)
                Button("Full bed") { selection = .full }
                    .disabled(model.isBusy || image == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(model.isBusy)
                Button("Use Scan Area") {
                    model.customScanArea = selection.area(on: bed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || image == nil)
            }
        }
        .padding(24)
        .frame(width: 760, height: 680)
        .interactiveDismissDisabled(model.isBusy)
        .task { await refreshPreview() }
    }

    private var areaDescription: String {
        let area = selection.area(on: bed)
        return String(format: "%.1f × %.1f mm · x: %.1f mm · y: %.1f mm",
                      locale: Locale.current, area.width, area.height, area.x, area.y)
    }

    private func refreshPreview() async {
        errorMessage = nil
        do {
            image = try await model.scanAreaPreview()
        } catch {
            errorMessage = error.localizedDescription
            image = nil
        }
    }
}

private struct ScanSelectionView: View {
    private enum CoordinateSpaceID: Hashable { case preview }

    let image: NSImage
    @Binding var selection: ScanSelection
    @State private var dragStart: ScanSelection?
    @FocusState private var focusedCorner: ScanSelection.Corner?

    var body: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            let rect = CGRect(x: selection.rect.minX * size.width,
                              y: selection.rect.minY * size.height,
                              width: selection.rect.width * size.width,
                              height: selection.rect.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel(Text("Preview of the scanner glass"))
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                ForEach(ScanSelection.Corner.allCases, id: \.self) { corner in
                    handle(corner, size: size)
                        .position(x: selection.point(for: corner).x * size.width,
                                  y: selection.point(for: corner).y * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: CoordinateSpaceID.preview)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return available }
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func handle(_ corner: ScanSelection.Corner, size: CGSize) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .padding(7)
            .contentShape(Rectangle())
            .overlay {
                if focusedCorner == corner {
                    Circle().stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .focusable()
            .focused($focusedCorner, equals: corner)
            .onTapGesture { focusedCorner = corner }
            .gesture(
                // The handle moves during a drag; measure against the stationary image
                // so its changing local origin cannot feed back into the translation.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(CoordinateSpaceID.preview))
                    .onChanged { value in
                        if dragStart == nil {
                            focusedCorner = corner
                            dragStart = selection
                        }
                        guard let start = dragStart, size.width > 0, size.height > 0 else { return }
                        let point = start.point(for: corner)
                        var updated = start
                        updated.move(corner, to: CGPoint(
                            x: point.x + value.translation.width / size.width,
                            y: point.y + value.translation.height / size.height
                        ))
                        if selection != updated { selection = updated }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onKeyPress(.leftArrow) { nudge(corner, dx: -0.005); return .handled }
            .onKeyPress(.rightArrow) { nudge(corner, dx: 0.005); return .handled }
            .onKeyPress(.upArrow) { nudge(corner, dy: -0.005); return .handled }
            .onKeyPress(.downArrow) { nudge(corner, dy: 0.005); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(corner.label))
            .accessibilityValue(Text(coordinates(for: corner)))
            .accessibilityAction(named: Text("Move left")) { nudge(corner, dx: -0.005) }
            .accessibilityAction(named: Text("Move right")) { nudge(corner, dx: 0.005) }
            .accessibilityAction(named: Text("Move up")) { nudge(corner, dy: -0.005) }
            .accessibilityAction(named: Text("Move down")) { nudge(corner, dy: 0.005) }
    }

    private func nudge(_ corner: ScanSelection.Corner, dx: Double = 0, dy: Double = 0) {
        let point = selection.point(for: corner)
        selection.move(corner, to: CGPoint(x: point.x + dx, y: point.y + dy))
    }

    private func coordinates(for corner: ScanSelection.Corner) -> String {
        let point = selection.point(for: corner)
        return String(format: "x: %.1f%%, y: %.1f%%", locale: Locale.current,
                      point.x * 100, point.y * 100)
    }
}
