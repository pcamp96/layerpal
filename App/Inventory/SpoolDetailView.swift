import SwiftUI

/// One spool: remaining filament, where it is loaded, its details, and the actions
/// (edit, set remaining grams, assign to a printer slot, archive, delete).
struct SpoolDetailView: View {
    let spoolId: Int
    @ObservedObject var store: InventoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing = false
    @State private var showLabel = false
    @State private var assigning = false
    @State private var settingRemaining = false
    @State private var remainingText = ""
    @State private var confirmFull = false
    @State private var confirmArchive = false
    @State private var confirmDelete = false
    @State private var unassignTarget: SlotAssignment?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var notice: String?

    private var spool: Spool? { store.spool(spoolId) }
    private var slots: [SlotAssignment] { store.slots(for: spoolId) }

    var body: some View {
        Group {
            if let spool {
                content(spool)
            } else {
                ContentUnavailableView("Spool not found", systemImage: "cylinder.split.1x2",
                                       description: Text("It may have been deleted or archived."))
            }
        }
        .background(Color.bgPrimary)
        .navigationTitle(spool?.displayName ?? "Spool")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if spool != nil, store.canRead {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLabel = true } label: { Image(systemName: "printer") }.accessibilityLabel("Print label")
                }
            }
            if let spool, store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Button { remainingText = SpoolDraft.text(spool.remainingGrams.rounded()); settingRemaining = true } label: {
                            Label("Set remaining grams", systemImage: "scalemass")
                        }
                        Button { confirmArchive = true } label: {
                            Label(spool.isArchived ? "Restore" : "Archive", systemImage: spool.isArchived ? "tray.and.arrow.up" : "archivebox")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Spool actions")
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let spool { SpoolFormView(store: store, editing: spool) { _ in } }
        }
        .sheet(isPresented: $showLabel) { LabelPrintSheet(spoolIds: [spoolId], spoolman: store.spoolman) }
        .sheet(isPresented: $assigning) {
            if let spool { AssignToSlotSheet(spool: spool, store: store) { notice = $0 } }
        }
        .alert("Set remaining grams", isPresented: $settingRemaining) {
            TextField("Grams", text: $remainingText).keyboardType(.decimalPad)
            Button("Set") { applyRemaining() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Weigh the filament (without the spool) and enter what is left.")
        }
        .confirmationDialog("Mark as a full spool?", isPresented: $confirmFull, titleVisibility: .visible) {
            Button("Reset used weight to 0") { setUsed(0) }
        } message: {
            Text("Bambuddy will treat this spool as unused.")
        }
        .confirmationDialog(spool?.isArchived == true ? "Restore this spool?" : "Archive this spool?", isPresented: $confirmArchive, titleVisibility: .visible) {
            if let spool {
                Button(spool.isArchived ? "Restore" : "Archive") { toggleArchive(spool) }
            }
        } message: {
            Text(spool?.isArchived == true ? "It goes back into active inventory." : "It leaves active inventory and is taken out of any printer slot.")
        }
        .confirmationDialog("Delete this spool?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete spool", role: .destructive) { delete() }
        } message: {
            Text("This can't be undone. Its printer slots are freed. Archive it instead to keep the history.")
        }
        .confirmationDialog("Unassign from \(unassignTarget?.fullName ?? "slot")?", isPresented: Binding(get: { unassignTarget != nil }, set: { if !$0 { unassignTarget = nil } }),
                            titleVisibility: .visible, presenting: unassignTarget) { target in
            Button("Unassign", role: .destructive) { unassign(target) }
        } message: { _ in
            Text("The printer keeps whatever filament settings it has.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
        .alert("Assigned", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { _ in
            Button("OK") { notice = nil }
        } message: { Text($0) }
        .onChange(of: store.spools.contains { $0.id == spoolId }) { _, exists in
            if !exists, store.loaded { dismiss() }
        }
        .disabled(busy)
    }

    // MARK: Content

    private func content(_ spool: Spool) -> some View {
        let low = spool.isLow(globalThreshold: store.lowStockThreshold)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(spool, low: low)
                remainingCard(spool, low: low)
                loadedCard(spool)
                detailsCard(spool)
                SpoolUsageSection(spoolId: spoolId, spoolman: store.spoolman, canClear: store.canWrite)
                if let note = spool.note, !note.isEmpty {
                    Card { VStack(alignment: .leading, spacing: 4) {
                        Text("Note").font(.caption).foregroundStyle(Color.textMuted)
                        Text(note).font(.subheadline)
                    } }
                }
                if store.spoolman, store.canWrite {
                    InfoRow(symbol: "link", text: "This spool lives in Spoolman. Category and low-stock alert aren't stored there.")
                }
                if !store.canWrite {
                    InfoRow(symbol: "lock", text: "Read-only: your account or this app's key can't change inventory.")
                }
            }
            .padding()
        }
    }

    private func header(_ spool: Spool, low: Bool) -> some View {
        HStack(spacing: 14) {
            SpoolSwatch(colors: spool.swatchColors, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(spool.displayName).font(.title3.weight(.semibold))
                if let name = spool.colorName, !name.isEmpty { Text(name).font(.subheadline).foregroundStyle(Color.textSecondary) }
                HStack(spacing: 6) {
                    if spool.isArchived { Pill(text: "Archived", systemImage: "archivebox") }
                    if low { Pill(text: "Running low", tint: .statusWarning, systemImage: "exclamationmark.triangle") }
                    if let effect = spool.effectType, !effect.isEmpty { Pill(text: effect.capitalized) }
                    if let category = spool.category, !category.isEmpty { Pill(text: category) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func remainingCard(_ spool: Spool, low: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatGrams(spool.remainingGrams)).font(.title2.weight(.semibold).monospacedDigit())
                    Text("of \(formatGrams(spool.labelGrams))").font(.subheadline).foregroundStyle(Color.textMuted)
                    Spacer()
                    Text("\(Int(spool.remainingPercent.rounded()))%").font(.subheadline.monospacedDigit()).foregroundStyle(Color.textSecondary)
                }
                FarmProgressBar(value: spool.remainingPercent,
                                tint: spool.remainingGrams <= 0 ? .statusError : (low ? .statusWarning : .accentTeal), height: 8)
                Text("Alert below \(Int(spool.lowStockThresholdPct ?? store.lowStockThreshold))%" + (spool.lowStockThresholdPct == nil ? " (global)" : ""))
                    .font(.caption).foregroundStyle(Color.textMuted)
                if store.canWrite {
                    HStack {
                        Button { remainingText = SpoolDraft.text(spool.remainingGrams.rounded()); settingRemaining = true } label: {
                            Label("Set remaining", systemImage: "scalemass")
                        }
                        .buttonStyle(.bordered).tint(.accentTeal)
                        if (spool.weightUsed ?? 0) > 0 {
                            Button { confirmFull = true } label: { Label("Full spool", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(.bordered).tint(.textSecondary)
                        }
                    }
                    .controlSize(.small)
                    if !store.spoolman, spool.weightLocked == true {
                        Text("Weight is locked, so AMS syncing won't overwrite it.").font(.caption).foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
    }

    private func loadedCard(_ spool: Spool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Loaded in").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
                if !store.canViewAssignments {
                    Text("Your account can't view slot assignments.").font(.subheadline).foregroundStyle(Color.textMuted)
                } else if slots.isEmpty {
                    Text(spool.isArchived ? "Archived spools can't be loaded." : "Not in a printer slot.").font(.subheadline).foregroundStyle(Color.textMuted)
                }
                ForEach(slots) { slot in
                    HStack {
                        Label(slot.fullName, systemImage: "printer.fill").font(.subheadline)
                        Spacer()
                        if store.canWrite {
                            Button("Unassign") { unassignTarget = slot }
                                .font(.caption.weight(.medium)).buttonStyle(.bordered).tint(.statusWarning).controlSize(.small)
                        }
                    }
                }
                if store.canWrite, !spool.isArchived {
                    Button { assigning = true } label: {
                        Label("Assign to printer slot", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.bordered).tint(.accentTeal).controlSize(.small)
                }
            }
        }
    }

    private func detailsCard(_ spool: Spool) -> some View {
        let rows: [(String, String)] = [
            ("Material", [spool.material, spool.subtype].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")),
            ("Brand", spool.brand ?? ""),
            ("Spool weight", spool.labelWeight.map { formatGrams($0) } ?? ""),
            ("Empty spool", spool.coreWeight.map { formatGrams($0) } ?? ""),
            ("Used", spool.weightUsed.map { formatGrams($0) } ?? ""),
            ("Nozzle", nozzleRange(spool)),
            ("Cost", spool.costPerKg.map { String(format: "%.2f per kg", $0) } ?? ""),
            ("Storage", spool.storageLocation ?? ""),
            ("Material no.", spool.materialNumber ?? ""),
            ("Last used", spool.lastUsed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""),
        ].filter { !$0.1.isEmpty }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).font(.subheadline).foregroundStyle(Color.textMuted)
                        Spacer(minLength: 12)
                        Text(row.1).font(.subheadline).multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func nozzleRange(_ s: Spool) -> String {
        switch (s.nozzleTempMin, s.nozzleTempMax) {
        case let (lo?, hi?): "\(lo)–\(hi)°C"
        case let (lo?, nil): "\(lo)°C"
        case let (nil, hi?): "\(hi)°C"
        default: ""
        }
    }

    // MARK: Actions

    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                InventoryHaptics.success()
            } catch {
                InventoryHaptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyRemaining() {
        guard let spool, let grams = Double(remainingText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), grams >= 0 else {
            errorMessage = "Enter the remaining weight in grams."
            InventoryHaptics.error()
            return
        }
        setUsed(max(0, spool.labelGrams - min(grams, spool.labelGrams)))
    }

    private func setUsed(_ used: Double) {
        var patch = InventoryPatch()
        patch["weight_used"] = .double((used * 10).rounded() / 10)
        perform { _ = try await store.update(spoolId, patch) }
    }

    private func toggleArchive(_ spool: Spool) {
        let archive = !spool.isArchived
        perform { _ = try await store.setArchived(spoolId, archive) }
    }

    private func delete() {
        perform {
            try await store.delete(spoolId)
            dismiss()
        }
    }

    private func unassign(_ slot: SlotAssignment) {
        perform { try await store.unassign(slot) }
    }
}
