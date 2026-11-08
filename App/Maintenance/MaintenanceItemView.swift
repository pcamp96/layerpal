import SwiftUI

/// One maintenance item: status, history, Mark done, interval and enabled edits, remove.
struct MaintenanceItemView: View {
    @State var item: MaintStatus
    var onChange: () -> Void = {}

    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var history: [MaintHistoryEntry] = []
    @State private var types: [MaintType] = []
    @State private var historyLoaded = false
    @State private var error: String?
    @State private var markingDone = false
    @State private var editing = false
    @State private var confirmRemove = false

    private var access: MaintAccess { MaintAccess(farm: farm) }
    private var type: MaintType? { types.first { $0.id == item.maintenanceTypeId } }
    /// Only custom types can be unassigned from a printer (the server answers 400 for system types).
    private var canRemove: Bool { access.canDelete && type?.isSystem == false }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: item.symbol).font(.title2).foregroundStyle(item.tint).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.maintenanceTypeName).font(.headline)
                        Text(item.printerName).font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Status") { Text(item.dueText).foregroundStyle(item.isDue || item.isWarning ? item.tint : Color.primary) }
                LabeledContent("Interval", value: item.intervalText)
                if let since = item.inDays ? item.daysSinceMaintenance : item.hoursSinceMaintenance {
                    LabeledContent("Since last", value: String(format: "%.1f %@", since, item.inDays ? "days" : "print hours"))
                }
                LabeledContent("Last done", value: item.lastPerformedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                if let d = type?.description, !d.isEmpty { Text(d).font(.footnote).foregroundStyle(Color.textSecondary) }
                if let wiki = item.maintenanceTypeWikiUrl ?? type?.wikiUrl, let url = URL(string: wiki) {
                    Link(destination: url) { Label("How to", systemImage: "book") }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if access.canUpdate {
                Section {
                    Button { markingDone = true } label: {
                        Label("Mark done", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
                    .disabled(!item.enabled)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            Section("History") {
                if history.isEmpty {
                    Text(historyLoaded ? "Never performed" : "Loading").font(.footnote).foregroundStyle(Color.textMuted)
                }
                ForEach(history) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.performedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                        if let h = entry.hoursAtMaintenance { Text(String(format: "At %.0f print hours", h)).font(.caption).foregroundStyle(Color.textMuted) }
                        if let n = entry.notes, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(Color.textSecondary) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if canRemove {
                Section {
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from this printer", systemImage: "trash") }
                }
            }
        }
        .farmBackground()
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if access.canUpdate {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $markingDone) {
            MarkDoneSheet(item: item) {
                await refreshItem()
                await load()
                onChange()
            }
        }
        .sheet(isPresented: $editing) {
            MaintItemEditSheet(item: item, defaultType: type) {
                await refreshItem()
                onChange()
            }
        }
        .confirmationDialog("Remove \(item.maintenanceTypeName) from \(item.printerName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove() }
        } message: { Text("Its history is deleted with it. You can assign the type again later.") }
    }

    private func load() async {
        do {
            history = try await APIClient.shared.maintHistory(item.id)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        historyLoaded = true
        types = (try? await APIClient.shared.maintTypes()) ?? types
    }

    /// The item screen has no single-item route, so re-read the printer and pick the item out.
    private func refreshItem() async {
        if let overview = try? await APIClient.shared.maintPrinter(item.printerId),
           let fresh = overview.maintenanceItems.first(where: { $0.id == item.id }) {
            item = fresh
        }
    }

    private func remove() {
        Task {
            do {
                try await APIClient.shared.maintRemoveItem(item.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onChange()
                dismiss()
            } catch { self.error = FriendlyError.message(error) }
        }
    }
}

/// Edit the interval (or fall back to the type's default) and enable or disable the item.
/// PATCH /maintenance/items/{id} {custom_interval_hours, custom_interval_type, enabled}.
struct MaintItemEditSheet: View {
    let item: MaintStatus
    let defaultType: MaintType?
    var onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var intervalText: String
    @State private var inDays: Bool
    @State private var error: String?
    @State private var busy = false

    init(item: MaintStatus, defaultType: MaintType?, onSaved: @escaping () async -> Void) {
        self.item = item
        self.defaultType = defaultType
        self.onSaved = onSaved
        _enabled = State(initialValue: item.enabled)
        _intervalText = State(initialValue: item.intervalHours.rounded() == item.intervalHours ? String(Int(item.intervalHours)) : String(item.intervalHours))
        _inDays = State(initialValue: item.inDays)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Track this item", isOn: $enabled)
                }
                Section {
                    Picker("Count in", selection: $inDays) {
                        Text("Print hours").tag(false)
                        Text("Days").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Every")
                        TextField("Interval", text: $intervalText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text(inDays ? "days" : "hours").foregroundStyle(Color.textMuted)
                    }
                } header: { Text("Interval") } footer: {
                    if let defaultType { Text("The type's default is \(defaultType.intervalText.lowercased()). Setting that value goes back to the default.") }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle(item.maintenanceTypeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy) }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let value = Double(intervalText.replacingOccurrences(of: ",", with: ".")), value >= 1 else {
            error = "The interval must be a number of at least 1."
            return
        }
        var patch = LibPatch()
        patch["enabled"] = .bool(enabled)
        // The server treats a null custom interval as "use the type's default", so a value equal to the default goes as null.
        let sameInterval = defaultType.map { abs($0.defaultIntervalHours - value) < 0.01 } ?? false
        let sameType = defaultType.map { $0.inDays == inDays } ?? false
        patch["custom_interval_hours"] = sameInterval ? .null : .double(value)
        patch["custom_interval_type"] = sameType ? .null : .string(inDays ? "days" : "hours")
        busy = true
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.maintUpdateItem(item.id, patch)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onSaved()
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
