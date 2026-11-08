import SwiftUI

/// Where filament is bought from, with how many spools, how much is left and what was spent per
/// supplier. Reading needs inventory:read; add, change and delete need inventory:update.
/// No navigation stack of its own.
struct SuppliersView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var suppliers: [Supplier] = []
    @State private var stats: [Int: SupplierStat] = [:]
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Editing?
    @State private var deleting: Supplier?

    private struct Editing: Identifiable { let supplier: Supplier?; var id: Int { supplier?.id ?? -1 } }

    private var canWrite: Bool { farm.can("inventory:update") }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(suppliers) { supplier in
                Button { if canWrite { editing = Editing(supplier: supplier) } } label: { row(supplier) }
                    .swipeActions {
                        if canWrite { Button(role: .destructive) { deleting = supplier } label: { Label("Delete", systemImage: "trash") } }
                    }
                    .listRowBackground(Color.bgCard)
            }
            if loaded, suppliers.isEmpty, error == nil {
                ContentUnavailableView("No suppliers", systemImage: "shippingbox",
                                       description: Text(canWrite ? "Tap + to add where you buy filament." : ""))
                    .listRowBackground(Color.clear)
            }
            if !canWrite, loaded {
                Label("Read-only: your account can't change suppliers.", systemImage: "lock").font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .farmBackground()
        .navigationTitle("Suppliers")
        .toolbar {
            if canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Editing(supplier: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Add supplier")
                }
            }
        }
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in SupplierEditSheet(supplier: edit.supplier) { await load() } }
        .confirmationDialog("Delete this supplier?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { supplier in
            Button("Delete \(supplier.name)", role: .destructive) { delete(supplier) }
        } message: { supplier in
            Text((supplier.spoolCount ?? 0) > 0 ? "\(supplier.name) has spools assigned, so Bambuddy will refuse." : "This can't be undone.")
        }
    }

    private func row(_ supplier: Supplier) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(supplier.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                if let n = supplier.spoolCount { Text("\(n) spool\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(Color.textMuted) }
            }
            if let site = supplier.website, !site.isEmpty { Text(site).font(.caption).foregroundStyle(Color.accentTeal).lineLimit(1) }
            if let number = supplier.customerNumber, !number.isEmpty { Text("Customer no. \(number)").font(.caption).foregroundStyle(Color.textSecondary) }
            if let note = supplier.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(Color.textMuted).lineLimit(2) }
            if let stat = stats[supplier.id], stat.spoolCount > 0 || stat.consumedG > 0 {
                HStack(spacing: 12) {
                    Label(formatGrams(stat.remainingG) + " left", systemImage: "cylinder.split.1x2")
                    Label(formatGrams(stat.consumedG) + " used", systemImage: "flame")
                    if stat.cost > 0 { Label(stat.cost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")), systemImage: "creditcard") }
                }
                .font(.caption2).foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            suppliers = try await APIClient.shared.suppliers()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        if let list = try? await APIClient.shared.supplierStats() { stats = Dictionary(uniqueKeysWithValues: list.map { ($0.supplierId, $0) }) }
        loaded = true
    }

    private func delete(_ supplier: Supplier) {
        Task {
            do {
                try await APIClient.shared.deleteSupplier(supplier.id)
                suppliers.removeAll { $0.id == supplier.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

struct SupplierEditSheet: View {
    let supplier: Supplier?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SupplierDraft
    @State private var saving = false
    @State private var error: String?

    init(supplier: Supplier?, onSaved: @escaping () async -> Void) {
        self.supplier = supplier
        self.onSaved = onSaved
        _draft = State(initialValue: supplier.map(SupplierDraft.init) ?? SupplierDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supplier") {
                    TextField("Name", text: $draft.name)
                    TextField("Website (optional)", text: $draft.website)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Your customer number (optional)", text: $draft.customerNumber).autocorrectionDisabled()
                    TextField("Note (optional)", text: $draft.note, axis: .vertical)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle(supplier == nil ? "Add supplier" : "Edit supplier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        if let problem = draft.problem { error = problem; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if let supplier {
                    let patch = draft.patch(from: supplier)
                    if !patch.isEmpty { _ = try await APIClient.shared.updateSupplier(supplier.id, patch) }
                } else {
                    _ = try await APIClient.shared.createSupplier(draft)
                }
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
