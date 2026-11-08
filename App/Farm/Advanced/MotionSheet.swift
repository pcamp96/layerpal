import SwiftUI

/// "Move & home": auto-home, XY jog, bed/Z jog and extruder jog.
///
/// Server behavior: every move is sent as relative G-code over MQTT and nothing clamps it,
/// because Bambu firmware ignores soft endstops for remote G-code. XY and Z are limited to
/// 200 mm and the extruder to 100 mm per call; we cap steps far below that. Home always runs a full G28.
struct MotionSheet: View {
    let printerId: Int
    let model: String?
    let printing: Bool
    let nozzleTemp: Double?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("advanced.motionAcknowledged") private var acknowledged = false
    @State private var step: Double = 1
    @State private var extruderStep: Double = 5
    @State private var busy = false
    @State private var error: String?
    @State private var confirmHome = false
    @State private var pendingZ: Double?

    private static let steps: [Double] = [0.1, 1, 10, 50]
    private static let extruderSteps: [Double] = [1, 5, 10, 50]
    /// Z moves at or above this need a confirmation (a crash risk).
    private static let zConfirmStep: Double = 50

    private var toolheadMoves: Bool { AdvModels.zMovesToolhead(model) }

    var body: some View {
        NavigationStack {
            Group {
                if !acknowledged { gate } else { controls }
            }
            .background(Color.bgPrimary)
            .navigationTitle("Move & home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .alert("Couldn't do that", isPresented: .constant(error != nil), presenting: error) { _ in
            Button("OK") { error = nil }
        } message: { Text($0) }
        .confirmationDialog("Home all axes?", isPresented: $confirmHome, titleVisibility: .visible) {
            Button("Home all axes") { send { try await APIClient.shared.homeAxes(printerId) } }
        } message: {
            Text("The printer runs its full auto-home: parks the toolhead, homes X and Y, then Z. Make sure nothing is in the way.")
        }
        .confirmationDialog("Move Z by \(Self.format(pendingZ.map(abs) ?? 0)) mm?", isPresented: Binding(
            get: { pendingZ != nil }, set: { if !$0 { pendingZ = nil } }
        ), titleVisibility: .visible) {
            Button("Move") { if let gap = pendingZ { send { try await APIClient.shared.bedJog(printerId, distance: gap) } } }
        } message: {
            Text("A large Z move can drive the nozzle into the bed. The printer does not stop at its travel limits.")
        }
    }

    // MARK: First-use gate

    private var gate: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Color.statusWarning)
                Text("Manual moves are not limited").font(.title3.weight(.semibold))
                Text("Bambu firmware ignores its travel limits for moves sent from an app, so a jog can drive the toolhead or bed past the end of its range and cause a collision. Check the printer before every move, and keep everything clear.")
                    .foregroundStyle(Color.textSecondary)
                Button {
                    acknowledged = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } label: {
                    Text("I understand").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
            }
            .padding()
        }
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if printing {
                    InfoRow(symbol: "lock", text: "Moves are disabled while a print is running.")
                }
                InfoRow(symbol: "exclamationmark.triangle",
                        text: "Travel limits are not enforced during manual moves. Move carefully to avoid a collision.")

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Step (mm)")
                    stepPicker($step, Self.steps)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Toolhead X / Y")
                    Card {
                        VStack(spacing: 8) {
                            arrow("arrow.up", "Move Y positive, \(Self.format(step)) millimetres") { xy(0, step) }
                            HStack(spacing: 8) {
                                arrow("arrow.left", "Move X left, \(Self.format(step)) millimetres") { xy(-step, 0) }
                                Button { confirmHome = true } label: {
                                    Image(systemName: "house.fill").frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.bordered).tint(.accentTeal)
                                .accessibilityLabel("Auto home all axes")
                                arrow("arrow.right", "Move X right, \(Self.format(step)) millimetres") { xy(step, 0) }
                            }
                            arrow("arrow.down", "Move Y negative, \(Self.format(step)) millimetres") { xy(0, -step) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: toolheadMoves ? "Z (moves the toolhead)" : "Z (moves the bed)")
                    Card {
                        HStack(spacing: 8) {
                            arrow("arrow.up.to.line", toolheadMoves ? "Raise toolhead, \(Self.format(step)) millimetres" : "Raise bed, \(Self.format(step)) millimetres") { z(up: true) }
                            arrow("arrow.down.to.line", toolheadMoves ? "Lower toolhead, \(Self.format(step)) millimetres" : "Lower bed, \(Self.format(step)) millimetres") { z(up: false) }
                        }
                        Text(toolheadMoves ? "Up lifts the toolhead away from the plate." : "Up raises the plate toward the nozzle.")
                            .font(.caption).foregroundStyle(Color.textMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Extruder (mm of filament)")
                    stepPicker($extruderStep, Self.extruderSteps)
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                arrow("arrow.up.circle", "Retract filament, \(Self.format(extruderStep)) millimetres") { extrude(-extruderStep) }
                                arrow("arrow.down.circle", "Extrude filament, \(Self.format(extruderStep)) millimetres") { extrude(extruderStep) }
                            }
                            Text(nozzleTemp.map { "Nozzle is \(Int($0.rounded()))°. The printer refuses to extrude below its minimum temperature." }
                                ?? "The printer refuses to extrude below its minimum temperature.")
                                .font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                }
            }
            .padding()
        }
        .disabled(busy || printing)
    }

    private func stepPicker(_ selection: Binding<Double>, _ values: [Double]) -> some View {
        Picker("Step", selection: selection) {
            ForEach(values, id: \.self) { Text(Self.format($0)).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.statusFinished)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func xy(_ x: Double, _ y: Double) {
        send { try await APIClient.shared.xyJog(printerId, x: x, y: y) }
    }

    /// The bed-jog endpoint takes a signed nozzle-to-bed gap (positive opens it). On printers whose Z axis
    /// moves the toolhead, "up" opens the gap; on the others the plate rises and "up" closes it.
    private func z(up: Bool) {
        let opensGap = toolheadMoves ? up : !up
        let distance = opensGap ? step : -step
        if step >= Self.zConfirmStep { pendingZ = distance } else { send { try await APIClient.shared.bedJog(printerId, distance: distance) } }
    }

    private func extrude(_ distance: Double) {
        send { try await APIClient.shared.extruderJog(printerId, distance: distance) }
    }

    private func send(_ action: @escaping () async throws -> Void) {
        guard !printing, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
