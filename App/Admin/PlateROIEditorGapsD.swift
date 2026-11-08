import SwiftUI
import UIKit

/// Plate-detection area editor (Bambuddy: Printers page > plate check > Detection Area). Shows a fresh camera
/// frame with a draggable, resizable rectangle. Saves `plate_detection_roi` {x, y, w, h} as 0...1 fractions of
/// the frame through PATCH /printers/{id} (printers:update), and tests it with GET /printers/{id}/camera/check-plate
/// (camera:view). The server runs the check against the *saved* area, so save first.
struct PlateROIEditorView: View {
    let printerId: Int
    let printerName: String

    @ObservedObject private var session = AdminSession.shared
    @State private var image: UIImage?
    @State private var imageFailed = false
    @State private var loadingImage = false
    @State private var roi = PlateROI.standard
    @State private var saved: PlateROI?
    @State private var hasSaved = false
    @State private var loadedROI = false
    @State private var saving = false
    @State private var checking = false
    @State private var result: PlateCheckResult?
    @State private var checkError: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var dragStart: PlateROI?

    private static let minSize = 0.05
    private var dirty: Bool { roi != (saved ?? .standard) || (saved == nil && hasSaved) }
    private var canSave: Bool { session.can("printers:update") }
    private var canCheck: Bool { session.can("camera:view") }

    var body: some View {
        Form {
            Section {
                preview
                HStack {
                    Button { Task { await loadImage() } } label: { Label("New snapshot", systemImage: "camera.rotate") }
                        .disabled(loadingImage)
                    Spacer()
                    if loadingImage { ProgressView() }
                }
            } footer: {
                Text("Drag the box to move it, drag a corner to resize it. Cover the build plate and keep the rest of the view out. Turn the chamber light on for a clear snapshot.")
            }
            Section("Area") {
                readout
                DisclosureGroup("Fine tune") {
                    slider("Left", value: $roi.x, range: 0 ... max(0, 1 - roi.w))
                    slider("Top", value: $roi.y, range: 0 ... max(0, 1 - roi.h))
                    slider("Width", value: $roi.w, range: Self.minSize ... max(Self.minSize, 1 - roi.x))
                    slider("Height", value: $roi.h, range: Self.minSize ... max(Self.minSize, 1 - roi.y))
                }
                Button("Reset to Bambuddy's default area") { roi = .standard; OpsHaptics.tap() }
                    .disabled(roi == .standard)
            }
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            if let notice { Section { OpsBanner(kind: .success, text: notice) } }
            if canSave {
                Section {
                    OpsActionButton(title: "Save area", systemImage: "square.and.arrow.down", busy: saving, disabled: !dirty) { Task { await save() } }
                    if hasSaved {
                        OpsActionButton(title: "Clear saved area", systemImage: "xmark.circle", role: .destructive, busy: saving) { Task { await clear() } }
                    }
                } footer: {
                    Text("Without a saved area, Bambuddy uses its default (the lower middle of the frame).")
                }
            }
            if canCheck {
                Section {
                    OpsActionButton(title: "Check plate now", systemImage: "checkmark.viewfinder", busy: checking, disabled: dirty) { Task { await check() } }
                    if dirty { Text("Save the area first. The check uses the saved one.").font(.footnote).foregroundStyle(Color.textMuted) }
                    if let checkError { OpsBanner(kind: .error, text: checkError) }
                    if let result { resultView(result) }
                } header: {
                    Text("Test")
                } footer: {
                    Text("Compares the live camera to the reference photos taken of the empty plate. Needs plate detection set up and calibrated in Bambuddy.")
                }
            }
        }
        .farmBackground()
        .navigationTitle("Detection area")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadROI()
            await loadImage()
        }
    }

    // MARK: Preview with draggable box

    @ViewBuilder private var preview: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(image.size, contentMode: .fit)
                .overlay { GeometryReader { geo in box(in: geo.size) } }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Camera snapshot with the detection area outlined")
                .accessibilityValue(readoutText)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.bgRaised)
                if loadingImage {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.title2)
                        Text(imageFailed ? "No snapshot. The camera may be off, busy or offline." : "Loading snapshot…").font(.footnote)
                    }
                    .foregroundStyle(Color.textMuted).multilineTextAlignment(.center).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    private func box(in size: CGSize) -> some View {
        let rect = CGRect(x: roi.x * size.width, y: roi.y * size.height, width: roi.w * size.width, height: roi.h * size.height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.accentTeal.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentTeal, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? roi
                        dragStart = start
                        roi.x = clamp(start.x + value.translation.width / size.width, 0, 1 - start.w)
                        roi.y = clamp(start.y + value.translation.height / size.height, 0, 1 - start.h)
                    }
                    .onEnded { _ in dragStart = nil; OpsHaptics.tap() })
            ForEach(Corner.allCases, id: \.self) { corner in
                Circle().fill(Color.accentTeal).overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(corner.point(in: rect))
                    .gesture(DragGesture()
                        .onChanged { value in
                            let start = dragStart ?? roi
                            dragStart = start
                            resize(from: start, corner: corner, dx: value.translation.width / size.width, dy: value.translation.height / size.height)
                        }
                        .onEnded { _ in dragStart = nil; OpsHaptics.tap() })
                    .accessibilityHidden(true)
            }
        }
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private func resize(from start: PlateROI, corner: Corner, dx: Double, dy: Double) {
        var left = start.x, top = start.y, right = start.x + start.w, bottom = start.y + start.h
        switch corner {
        case .topLeft: left += dx; top += dy
        case .topRight: right += dx; top += dy
        case .bottomLeft: left += dx; bottom += dy
        case .bottomRight: right += dx; bottom += dy
        }
        left = clamp(left, 0, right - Self.minSize)
        top = clamp(top, 0, bottom - Self.minSize)
        right = clamp(right, left + Self.minSize, 1)
        bottom = clamp(bottom, top + Self.minSize, 1)
        roi = PlateROI(x: left, y: top, w: right - left, h: bottom - top)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), max(lo, hi)) }

    // MARK: Readout, sliders, result

    private var readoutText: String {
        "Left \(Int((roi.x * 100).rounded())) percent, top \(Int((roi.y * 100).rounded())) percent, width \(Int((roi.w * 100).rounded())) percent, height \(Int((roi.h * 100).rounded())) percent"
    }

    private var readout: some View {
        HStack {
            ForEach([("X", roi.x), ("Y", roi.y), ("W", roi.w), ("H", roi.h)], id: \.0) { label, value in
                VStack {
                    Text("\(Int((value * 100).rounded()))%").font(.subheadline.monospacedDigit().weight(.semibold))
                    Text(label).font(.caption2).foregroundStyle(Color.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Detection area")
        .accessibilityValue(readoutText)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let upper = max(range.lowerBound + 0.01, range.upperBound)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(Int((value.wrappedValue * 100).rounded()))%").font(.footnote)
            Slider(value: value, in: range.lowerBound ... upper, step: 0.01)
        }
        .padding(.vertical, 2)
    }

    private func resultView(_ r: PlateCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = r.failureReason, !reason.isEmpty {
                OpsBanner(kind: .error, text: r.message.isEmpty ? reason : r.message)
            } else if r.needsCalibration {
                OpsBanner(kind: .warning, text: r.message.isEmpty ? "Calibrate with a photo of the empty plate first." : r.message)
            } else {
                OpsBanner(kind: r.isEmpty ? .success : .warning, text: r.isEmpty ? "Plate looks empty." : "Something is on the plate.")
                if !r.message.isEmpty { Text(r.message).font(.footnote).foregroundStyle(Color.textSecondary) }
            }
            if r.lightWarning { OpsBanner(kind: .warning, text: "The chamber light is off, so this reading may be unreliable.") }
            OpsValueRow(label: "Difference from reference", value: String(format: "%.1f%%", r.differencePercent))
            OpsValueRow(label: "Confidence", value: "\(Int((r.confidence * 100).rounded()))%")
            OpsValueRow(label: "Reference photos", value: "\(r.referenceCount)")
        }
    }

    // MARK: Actions

    private func loadROI() async {
        guard !loadedROI else { return }
        do {
            let current = try await session.perform { try await APIClient.shared.plateROI(printerId, bearer: $0) }
            saved = current
            hasSaved = current != nil
            roi = current ?? .standard
            loadedROI = true
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func loadImage() async {
        loadingImage = true
        imageFailed = false
        defer { loadingImage = false }
        if let data = await APIClient.shared.cameraSnapshot(printerId), let frame = UIImage(data: data) {
            image = frame
        } else if image == nil {
            imageFailed = true
        }
    }

    private func save() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        let area = PlateROI(x: roi.x, y: roi.y, w: roi.w, h: roi.h)
        do {
            try await session.perform { try await APIClient.shared.setPlateROI(printerId, roi: area, bearer: $0) }
            saved = area
            hasSaved = true
            result = nil
            notice = "Detection area saved."
            OpsHaptics.success()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func clear() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            try await session.perform { try await APIClient.shared.setPlateROI(printerId, roi: nil, bearer: $0) }
            saved = nil
            hasSaved = false
            roi = .standard
            result = nil
            notice = "Saved area cleared. Bambuddy uses its default."
            OpsHaptics.warning()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func check() async {
        checking = true
        checkError = nil
        result = nil
        defer { checking = false }
        do {
            result = try await session.perform { try await APIClient.shared.checkPlate(printerId, bearer: $0) }
            result?.isEmpty == true ? OpsHaptics.success() : OpsHaptics.warning()
        } catch {
            checkError = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }
}
