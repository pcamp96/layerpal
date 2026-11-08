import SwiftUI

/// Starts calibration routines (`POST /printers/{id}/calibration`, printers:control) and shows
/// the live stage (`stg_cur_name`) while the printer works. Bambuddy's web UI has no calibration
/// screen in 1.3.0, so the option list comes straight from the endpoint.
struct CalibrationSheet: View {
    let printerId: Int
    let status: PrinterStatus
    let isDualNozzle: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<AdvCalibration> = []
    @State private var confirm = false
    @State private var busy = false
    @State private var started = false
    @State private var error: String?

    private var options: [AdvCalibration] { AdvCalibration.allCases.filter { $0 != .nozzleOffset || isDualNozzle } }
    private var printing: Bool { status.isPrinting }
    /// stg_cur: -1 idle, 0 "Printing", 255 unknown.
    private var activeStage: String? {
        guard let stg = status.stgCur, stg > 0, stg != 255, let name = status.stgCurName, !name.isEmpty else { return nil }
        return name
    }

    var body: some View {
        NavigationStack {
            List {
                if let stage = activeStage {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stage).font(.subheadline.weight(.semibold))
                                Text("Current printer stage").font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else if started {
                    Section { Label("Command sent. The stage appears here once the printer starts.", systemImage: "checkmark.circle").foregroundStyle(Color.accentTeal) }
                }
                if printing {
                    Section { Label("Calibration is disabled while a print is running.", systemImage: "lock").foregroundStyle(Color.textSecondary) }
                }
                Section {
                    ForEach(options) { option in
                        Toggle(isOn: Binding(
                            get: { selected.contains(option) },
                            set: { on in if on { selected.insert(option) } else { selected.remove(option) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(option.title, systemImage: option.symbol)
                                Text(option.detail).font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                        .tint(.accentTeal)
                    }
                } header: {
                    Text("Routines")
                } footer: {
                    Text("Printers skip routines their hardware doesn't support. Keep the build plate clear and the door closed.")
                }
                Section {
                    Button {
                        confirm = true
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Start calibration").fontWeight(.semibold) }; Spacer() }
                    }
                    .disabled(selected.isEmpty || busy || printing)
                }
            }
            .farmBackground()
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .confirmationDialog("Start calibration?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Start \(selected.count == 1 ? "1 routine" : "\(selected.count) routines")") { start() }
        } message: {
            Text("The printer will heat up and move its bed and toolhead for several minutes. Remove anything from the plate and keep clear.")
        }
        .alert("Couldn't do that", isPresented: .constant(error != nil), presenting: error) { _ in
            Button("OK") { error = nil }
        } message: { Text($0) }
    }

    private func start() {
        guard !selected.isEmpty, !printing else { return }
        busy = true
        let chosen = selected
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.startCalibration(printerId, options: chosen)
                started = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
