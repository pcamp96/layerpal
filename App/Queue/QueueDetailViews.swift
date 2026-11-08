import SwiftUI

/// Tap a queue row: everything about the job, plus start / edit / cancel / stop / delete.
struct QueueItemDetailView: View {
    @State var item: QueueItem
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var userId: Int?
    @State private var error: String?
    @State private var notice: String?
    @State private var editing = false
    @State private var mappingEdit = false
    @State private var pending: PendingAction?
    @State private var busy = false

    private var access: QueueAccess { QueueAccess(farm: farm, userId: userId) }
    private var isPending: Bool { item.status == "pending" }
    /// Only a pending job on a specific printer has a mapping to choose; "any printer" jobs are mapped by the scheduler.
    private var canEditMapping: Bool {
        isPending && item.printerId != nil && (item.archiveId != nil || item.libraryFileId != nil) && item.archiveDeleted != true && access.canUpdate(item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(path: item.thumbnailPath, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        QueueStatusPill(item: item)
                        Pill(text: item.target, tint: .textSecondary, systemImage: "printer")
                        if item.archiveDeleted == true { Pill(text: "Source deleted", tint: .statusWarning) }
                    }
                    if isPending, let reason = item.waitingReason, !reason.isEmpty {
                        Label(reason, systemImage: "hourglass").font(.footnote).foregroundStyle(Color.statusWarning)
                    }
                    if isPending, item.filamentShort == true {
                        Label("Not enough filament is loaded for this job.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(Color.statusWarning)
                    }
                    if let message = item.errorMessage, !message.isEmpty {
                        Label(message, systemImage: "exclamationmark.octagon.fill").font(.footnote).foregroundStyle(Color.statusError)
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if let notice { Text(notice).font(.footnote).foregroundStyle(Color.accentTeal) }
                actions
                SectionHeader(title: "Job")
                Card {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        fact("Source", item.archiveId != nil ? "Past print" : (item.libraryFileId != nil ? "Library file" : nil))
                        fact("Target", item.target)
                        fact("Plate", item.plateId.map { "Plate \($0)" })
                        fact("Print time", item.printTimeSeconds.flatMap { $0 > 0 ? formatMinutes($0 / 60) : nil })
                        fact("Filament", filamentText)
                        fact("Layer height", item.layerHeight.map { String(format: "%.2f mm", $0) })
                        fact("Nozzle", item.nozzleDiameter.map { String(format: "%.1f mm", $0) })
                        fact("Bed", item.bedType)
                        fact("Sliced for", item.slicedForModel.map { Printer.modelNames[$0] ?? $0 })
                    }
                }
                SectionHeader(title: "Timing")
                Card {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        fact("Added", item.createdAt?.formatted(date: .abbreviated, time: .shortened))
                        fact("Starts", isPending ? (item.scheduledTime?.formatted(date: .abbreviated, time: .shortened) ?? "As soon as possible") : nil)
                        fact("Started", item.startedAt?.formatted(date: .abbreviated, time: .shortened))
                        fact("Finished", item.completedAt?.formatted(date: .abbreviated, time: .shortened))
                        fact("Added by", item.createdByUsername)
                        fact("Batch", item.batchName)
                        fact("Manual start", item.manualStart == true ? "Yes" : nil)
                        fact("Needs previous print OK", item.requirePreviousSuccess == true ? "Yes" : nil)
                    }
                }
                SectionHeader(title: "Print options")
                Card {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        fact("Bed levelling", item.bedLevelling?.capitalized)
                        fact("Flow calibration", item.flowCali?.capitalized)
                        fact("Vibration calibration", item.vibrationCali.map { $0 ? "On" : "Off" })
                        fact("Layer inspection", item.layerInspect.map { $0 ? "On" : "Off" })
                        fact("Timelapse", item.timelapse.map { $0 ? "On" : "Off" })
                        fact("Use AMS", item.useAms.map { $0 ? "Yes" : "No" })
                    }
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("Queue job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPending, access.canUpdate(item) {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .task {
            userId = await IdentityCache.shared.userId()
            await refresh()
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await refresh() } }) { QueueItemEditSheet(item: item) }
        .sheet(isPresented: $mappingEdit, onDismiss: { Task { await refresh() } }) { QueueItemMappingSheet(item: item) }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button(p.button, role: p.destructive ? .destructive : nil) { perform(p) }
        } message: { p in Text(p.message) }
    }

    private var filamentText: String? {
        var parts: [String] = []
        if let g = item.filamentUsedGrams, g > 0 { parts.append(formatGrams(g)) }
        if let type = item.filamentType, !type.isEmpty { parts.append(type) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            if isPending, access.canUpdate(item), item.manualStart == true || item.filamentShort == true {
                Button { start() } label: { Label("Start now", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
            }
            if canEditMapping {
                Button { mappingEdit = true } label: { Label("Filament mapping", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityHint("Choose which loaded spool feeds each filament slot")
            }
            HStack(spacing: 10) {
                if isPending, access.canReorder {
                    Button { moveToTop() } label: { Label("Move to top", systemImage: "arrow.up.to.line").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                if isPending, access.canUpdate(item) {
                    Button(role: .destructive) { confirmCancel() } label: { Label("Cancel job", systemImage: "xmark").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
            if item.status == "printing", access.canUpdate(item) {
                Button(role: .destructive) { confirmStop() } label: { Label("Stop print", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            if !["pending", "printing"].contains(item.status), access.canDelete(item) {
                Button(role: .destructive) { confirmDelete() } label: { Label("Remove from history", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .disabled(busy)
    }

    @ViewBuilder private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(Color.textMuted).textCase(.uppercase)
                Text(value).font(.subheadline.weight(.medium))
            }
        }
    }

    // MARK: Actions

    private func start() {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await APIClient.shared.startQueueItem(item.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Started. The scheduler will send it to the printer."
                error = nil
                await refresh()
            } catch {
                if let warning = FriendlyError.filamentWarning(error) {
                    pending = PendingAction(title: "Start anyway?", message: warning, button: "Print anyway") {
                        try await APIClient.shared.startQueueItem(item.id, skipFilamentCheck: true)
                        return "Started without the filament check."
                    }
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.error = FriendlyError.message(error)
                }
            }
        }
    }

    private func moveToTop() {
        Task {
            busy = true
            defer { busy = false }
            do {
                let pendingIds = try await APIClient.shared.activeQueue()
                    .filter { $0.status == "pending" }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map(\.id)
                try await APIClient.shared.reorderQueue([item.id] + pendingIds.filter { $0 != item.id })
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Moved to the top."
                error = nil
                await refresh()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func confirmCancel() {
        pending = PendingAction(title: "Cancel this job?", message: "It leaves the queue and moves to history.", button: "Cancel job") {
            try await APIClient.shared.queueAction(item.id, "cancel")
            return "Cancelled."
        }
    }

    private func confirmStop() {
        pending = PendingAction(title: "Stop this print?", message: "This stops the print on \(item.printerName ?? "the printer").", button: "Stop print") {
            try await APIClient.shared.queueAction(item.id, "stop")
            return "Stop sent."
        }
    }

    private func confirmDelete() {
        pending = PendingAction(title: "Remove from history?", message: "\(item.name) is removed from the queue history.", button: "Remove") {
            try await APIClient.shared.removeQueueItem(item.id)
            dismiss()
            return nil
        }
    }

    private func perform(_ action: PendingAction) {
        Task {
            busy = true
            defer { busy = false }
            do {
                notice = try await action.run()
                error = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                notice = nil
                self.error = FriendlyError.message(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await refresh()
        }
    }

    private func refresh() async {
        if let fresh = try? await APIClient.shared.queueItem(item.id) { item = fresh }
    }
}

/// PATCH /queue/{id}: printer or model, start time, manual start, previous-success gate, plate, print options.
struct QueueItemEditSheet: View {
    let item: QueueItem
    @Environment(\.dismiss) private var dismiss
    @State private var target: QueueTarget
    @State private var scheduled: Date?
    @State private var manualStart: Bool
    @State private var requirePrevious: Bool
    @State private var plateId: Int?
    @State private var options: PrintOptions
    @State private var error: String?
    @State private var saving = false

    init(item: QueueItem) {
        self.item = item
        _target = State(initialValue: QueueTarget(printerId: item.printerId, targetModel: item.printerId == nil ? item.targetModel : nil))
        _scheduled = State(initialValue: item.scheduledTime)
        _manualStart = State(initialValue: item.manualStart ?? false)
        _requirePrevious = State(initialValue: item.requirePreviousSuccess ?? false)
        _plateId = State(initialValue: item.plateId)
        _options = State(initialValue: PrintOptions(item: item))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(item.name).font(.headline) }
                TargetChoiceSection(target: $target, model: item.targetModel ?? item.slicedForModel, allowUnassigned: true)
                if let archiveId = item.archiveId { PlatePickerSection(archiveId: archiveId, plateId: $plateId) }
                Section("Schedule") {
                    ScheduleField(date: $scheduled)
                    Toggle("Wait for me to start it", isOn: $manualStart)
                    Toggle("Only if the previous print succeeded", isOn: $requirePrevious)
                }
                Section("Print options") { PrintOptionsForm(options: $options) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Edit job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving) }
            }
        }
    }

    private func save() async {
        var patch = SparsePatch()
        // The server refuses a printer and a model together, so the one we leave must be nulled explicitly.
        if target.printerId != item.printerId || (target.printerId == nil && target.targetModel != item.targetModel) {
            if let printerId = target.printerId {
                patch["printer_id"] = .int(printerId)
                patch["target_model"] = .null
                patch["target_location"] = .null
            } else if let model = target.targetModel {
                patch["printer_id"] = .null
                patch["target_model"] = .string(model)
            } else {
                patch["printer_id"] = .null
                patch["target_model"] = .null
                patch["target_location"] = .null
            }
        }
        if Int(scheduled?.timeIntervalSince1970 ?? -1) != Int(item.scheduledTime?.timeIntervalSince1970 ?? -1) {
            patch["scheduled_time"] = .date(scheduled)
        }
        if manualStart != (item.manualStart ?? false) { patch["manual_start"] = .bool(manualStart) }
        if requirePrevious != (item.requirePreviousSuccess ?? false) { patch["require_previous_success"] = .bool(requirePrevious) }
        if let plateId, plateId != item.plateId { patch["plate_id"] = .int(plateId) }
        patch.set(options: options, from: PrintOptions(item: item))
        guard !patch.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            _ = try await APIClient.shared.updateQueueItem(item.id, patch)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }
}

/// PATCH /queue/bulk: printer, start time and manual start for several pending jobs at once.
struct BulkEditSheet: View {
    let ids: [Int]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var farm: FarmStore

    enum ScheduleChoice: String, CaseIterable, Identifiable {
        case keep = "Leave as is", asap = "As soon as possible", at = "At a set time"
        var id: String { rawValue }
    }

    enum ManualChoice: String, CaseIterable, Identifiable {
        case keep = "Leave as is", on = "Wait for me", off = "Start automatically"
        var id: String { rawValue }
    }

    @State private var target = QueueTarget()
    @State private var changePrinter = false
    @State private var schedule = ScheduleChoice.keep
    @State private var when: Date? = Date().addingTimeInterval(3600)
    @State private var manual = ManualChoice.keep
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { Text("\(ids.count) job\(ids.count == 1 ? "" : "s")").font(.headline) }
                Section("Printer") {
                    Toggle("Move to a specific printer", isOn: $changePrinter)
                    if changePrinter {
                        ForEach(farm.activePrinters) { p in
                            Button {
                                target = QueueTarget(printerId: p.id, targetModel: nil)
                            } label: {
                                HStack {
                                    Text(p.name)
                                    Spacer()
                                    if target.printerId == p.id { Image(systemName: "checkmark").foregroundStyle(Color.accentTeal) }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section("Start time") {
                    Picker("Start time", selection: $schedule) { ForEach(ScheduleChoice.allCases) { Text($0.rawValue).tag($0) } }
                    if schedule == .at { ScheduleField(date: $when) }
                }
                Section("Manual start") {
                    Picker("Manual start", selection: $manual) { ForEach(ManualChoice.allCases) { Text($0.rawValue).tag($0) } }
                }
                Text("Only pending jobs you're allowed to edit are changed; the rest are skipped.").font(.footnote).foregroundStyle(Color.textMuted)
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Edit \(ids.count) jobs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { Task { await save() } }.disabled(saving || !hasChanges) }
            }
        }
    }

    private var hasChanges: Bool {
        (changePrinter && target.printerId != nil) || schedule != .keep || manual != .keep
    }

    private func save() async {
        var patch = SparsePatch()
        if changePrinter, let printerId = target.printerId { patch["printer_id"] = .int(printerId) }
        switch schedule {
        case .keep: break
        case .asap: patch["scheduled_time"] = .null
        case .at: patch["scheduled_time"] = .date(when)
        }
        switch manual {
        case .keep: break
        case .on: patch["manual_start"] = .bool(true)
        case .off: patch["manual_start"] = .bool(false)
        }
        saving = true
        defer { saving = false }
        do {
            let result = try await APIClient.shared.bulkUpdateQueue(ids: ids, patch: patch)
            UINotificationFeedbackGenerator().notificationOccurred(result.updatedCount > 0 ? .success : .warning)
            if result.skippedCount > 0, result.updatedCount == 0 {
                error = "Nothing changed: \(result.skippedCount) job(s) were skipped (not pending or not yours)."
                return
            }
            onDone()
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }
}
