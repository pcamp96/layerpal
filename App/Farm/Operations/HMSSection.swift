import SwiftUI

/// Runs a printer action with the screen's shared busy state, haptics and error alert.
typealias OpsRun = (@escaping () async throws -> Void) -> Void

/// Button titles for the HMS action keys the printer offers. Keys are the printer's own,
/// misspellings included (PROBELM, CANCLE).
enum HMSActionLabel {
    static let labels: [String: String] = [
        "RESUME_PRINTING": "Resume",
        "RESUME_PRINTING_DEFECTS": "Resume anyway",
        "RESUME_PRINTING_PROBELM_SOLVED": "Fixed, resume",
        "STOP_PRINTING": "Stop print",
        "CHECK_ASSISTANT": "Show help on printer",
        "FILAMENT_EXTRUDED": "Filament is out, continue",
        "RETRY_FILAMENT_EXTRUDED": "No filament yet, retry",
        "CONTINUE": "Continue",
        "LOAD_VIRTUAL_TRAY": "Load external spool",
        "OK_BUTTON": "OK",
        "FILAMENT_LOAD_RESUME": "Loaded, resume",
        "JUMP_TO_LIVEVIEW": "Open camera",
        "NO_REMINDER_NEXT_TIME": "Don't show again",
        "REFRESH_NOZZLE": "Recheck nozzle",
        "IGNORE_NO_REMINDER_NEXT_TIME": "Ignore, don't show again",
        "IGNORE_RESUME": "Ignore and resume",
        "PROBLEM_SOLVED_RESUME": "Fixed, resume",
        "TURN_OFF_FIRE_ALARM": "Silence fire alarm",
        "RETRY_PROBLEM_SOLVED": "Fixed, retry",
        "CANCLE": "Cancel",
        "STOP_DRYING": "Stop drying",
        "PROCEED": "Go ahead",
        "OK_JUMP_RACK": "OK",
        "ABORT": "Abort print",
        "DISABLE_PURIFICATION": "Skip air filtering this print",
        "DONT_REMIND_NEXT_TIME": "Don't remind me",
        "DBL_CHECK_CANCEL": "Cancel",
        "DBL_CHECK_DONE": "Done",
        "DBL_CHECK_RETRY": "Retry",
        "DBL_CHECK_RESUME": "Resume",
        "DBL_CHECK_OK": "Confirm",
        "REMOVE_CLOSE_BTN": "Close",
    ]

    /// The table's title, else the key as words ("SOME_KEY" -> "Some Key").
    static func label(_ key: String) -> String {
        if let title = labels[key] { return title }
        return key.split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }

    static func isStop(_ key: String) -> Bool { key == "STOP_PRINTING" || key == "ABORT" }
}

/// Printer alerts with the one-tap actions the printer offers for each fault.
struct HMSAlertsSection: View {
    let printerId: Int
    let problems: [HMSError]
    let canControl: Bool
    let run: OpsRun

    private struct Pending: Identifiable {
        let error: HMSError
        let action: String
        var id: String { (error.fullCode ?? error.code ?? "") + action }
    }

    @State private var pending: Pending?
    @State private var confirmClear = false

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Alerts", trailing: "\(problems.count)")
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                            alertRow(problem)
                        }
                        if canControl {
                            Button { confirmClear = true } label: {
                                Label("Clear alerts", systemImage: "xmark.circle")
                            }
                            .font(.subheadline.weight(.medium))
                            .confirmationDialog("Clear alerts?", isPresented: $confirmClear, titleVisibility: .visible) {
                                Button("Clear alerts") { run { try await APIClient.shared.clearHMS(printerId) } }
                            } message: {
                                Text("Clears the error list on the printer. Problems that still exist will come back.")
                            }
                        }
                    }
                }
            }
            .confirmationDialog(pending.map { HMSActionLabel.label($0.action) } ?? "", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ), titleVisibility: .visible, presenting: pending) { item in
                Button(HMSActionLabel.label(item.action), role: HMSActionLabel.isStop(item.action) ? .destructive : nil) {
                    send(item)
                }
            } message: { item in
                Text(HMSActionLabel.isStop(item.action)
                    ? "This will stop the print on the printer."
                    : "This sends the choice to the printer, which can restart or resume the print.")
            }
        }
    }

    private func alertRow(_ p: HMSError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.description ?? "Printer alert").font(.subheadline)
                    if let code = p.fullCode ?? p.code { Text(code).font(.caption2.monospaced()).foregroundStyle(Color.textMuted) }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(p.severity == 1 ? Color.statusError : Color.statusWarning)
            }
            if canControl, let fullCode = p.fullCode, !fullCode.isEmpty, let actions = p.actions, !actions.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(actions, id: \.self) { action in
                        Button { pending = Pending(error: p, action: action) } label: {
                            Text(HMSActionLabel.label(action)).font(.footnote.weight(.medium)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(HMSActionLabel.isStop(action) ? .statusError : .accentTeal)
                    }
                }
            }
        }
    }

    private func send(_ item: Pending) {
        guard let code = item.error.fullCode else { return }
        run { try await APIClient.shared.executeHMSAction(printerId, printError: code, action: item.action, jobId: item.error.jobId) }
    }
}
