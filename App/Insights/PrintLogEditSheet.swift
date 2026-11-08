import SwiftUI

/// Edit one print-log row: outcome, failure reason and note go to PATCH /print-log/{id}; the quality verdict
/// is not editable there, so it goes to PATCH /archives/{archive_id} with `run_id` (the run is this log row).
/// Both need `archives:update_all`, or `archives:update_own` for the user's own runs. The failure-reason
/// vocabulary is the server's own; unknown values are refused with a 400.
struct PrintLogEditSheet: View {
    let entry: InsPrintLogEntry
    let archiveDeleted: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: String
    @State private var reason: String
    @State private var verdict: String
    @State private var notes: String
    @State private var error: String?
    @State private var saving = false

    static let failureReasons = [
        "adhesionFailure", "spaghettiDetached", "layerShift", "cloggedNozzle", "filamentRunout", "warping", "stringing",
        "underExtrusion", "powerFailure", "userCancelled", "noStatusUpdate", "killSwitch", "other",
    ]

    init(entry: InsPrintLogEntry, archiveDeleted: Bool, onSaved: @escaping () -> Void) {
        self.entry = entry
        self.archiveDeleted = archiveDeleted
        self.onSaved = onSaved
        _status = State(initialValue: entry.status)
        _reason = State(initialValue: entry.failureReason ?? "")
        _verdict = State(initialValue: entry.userVerdict ?? "")
        _notes = State(initialValue: entry.notes ?? "")
    }

    /// A verdict belongs to a run of an archive, so it needs a live archive.
    private var canSetVerdict: Bool { entry.archiveId != nil && !archiveDeleted }

    /// The server only accepts the five finished outcomes; a row already marked something else (an older
    /// "aborted") keeps its value in the list so it can stay as it is.
    private var statuses: [String] { InsStatus.all.contains(entry.status) ? InsStatus.all : [entry.status] + InsStatus.all }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(entry.title).font(.headline) }
                Section {
                    Picker("Outcome", selection: $status) {
                        ForEach(statuses, id: \.self) { Text(InsStatus.label($0)).tag($0) }
                    }
                    Picker("Failure reason", selection: $reason) {
                        Text("Not set").tag("")
                        if !reason.isEmpty, !Self.failureReasons.contains(reason) { Text(insFailureReasonLabel(reason)).tag(reason) }
                        ForEach(Self.failureReasons, id: \.self) { Text(insFailureReasonLabel($0)).tag($0) }
                    }
                } footer: {
                    Text("Failure reasons feed the failure breakdown on the Stats screen.")
                }
                if canSetVerdict {
                    Section {
                        Picker("Quality verdict", selection: $verdict) {
                            Text("Not set").tag("")
                            Text("Good print").tag("good")
                            Text("Rejected").tag("reject")
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Quality")
                    } footer: {
                        Text("Rejected prints are left out of project totals.")
                    }
                }
                Section("Note") {
                    TextField("Note about this print", text: $notes, axis: .vertical).lineLimit(3 ... 8)
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            }
            .farmBackground()
            .navigationTitle("Edit print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving) }
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        var patch = SparsePatch()
        if reason != (entry.failureReason ?? "") { patch["failure_reason"] = reason.isEmpty ? .null : .string(reason) }
        if status != entry.status { patch["status"] = .string(status) }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (entry.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { patch["notes"] = .string(trimmed) }
        let verdictChanged = canSetVerdict && verdict != (entry.userVerdict ?? "")
        guard !patch.isEmpty || verdictChanged else { dismiss(); return }
        saving = true
        error = nil
        defer { saving = false }
        var logSaved = false
        do {
            if !patch.isEmpty {
                try await APIClient.shared.updatePrintLogEntry(entry.id, patch)
                logSaved = true
            }
            if verdictChanged, let archiveId = entry.archiveId {
                try await APIClient.shared.setRunVerdict(archiveId: archiveId, runId: entry.id, verdict: verdict.isEmpty ? nil : verdict)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let message = insMessage(error)
            self.error = logSaved ? "The outcome, reason and note were saved, but the verdict wasn't: \(message)" : message
        }
    }
}
