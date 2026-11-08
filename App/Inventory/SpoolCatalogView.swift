import SwiftUI

/// The spool catalog (Bambuddy: Inventory > Spool catalog): spool types and their empty-spool weight in grams,
/// used when adding spools. Reading needs inventory:read; add, edit, delete and reset need inventory:update
/// (an API key also needs its can_manage_inventory scope). No navigation stack of its own.
struct SpoolCatalogView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var items: [SpoolCatalogEntry] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Editing?
    @State private var deleting: SpoolCatalogEntry?
    @State private var confirmReset = false
    @State private var busy = false

    private struct Editing: Identifiable { let item: SpoolCatalogEntry?; var id: Int { item?.id ?? -1 } }

    private var canWrite: Bool { farm.can("inventory:update") }

    private var visible: [SpoolCatalogEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            Section {
                ForEach(visible) { item in
                    Button { if canWrite { editing = Editing(item: item) } } label: { row(item) }
                        .swipeActions {
                            if canWrite {
                                Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .listRowBackground(Color.bgCard)
                }
            } footer: {
                if !items.isEmpty { Text("\(items.count) spool types. Weights are the empty spool, in grams.") }
            }
            if loaded, items.isEmpty, error == nil {
                ContentUnavailableView("The spool catalog is empty", systemImage: "circle.dashed",
                                       description: Text(canWrite ? "Add a spool type, or reset to Bambuddy's defaults from the menu." : ""))
                    .listRowBackground(Color.clear)
            } else if loaded, visible.isEmpty, !items.isEmpty {
                ContentUnavailableView.search(text: search).listRowBackground(Color.clear)
            }
            if !canWrite, loaded {
                Label("Read-only: your account can't change the catalog.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(Color.textSecondary).listRowBackground(Color.clear)
            }
        }
        .farmBackground()
        .navigationTitle("Spool catalog")
        .searchable(text: $search, prompt: "Search spool types")
        .toolbar {
            if canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = Editing(item: nil) } label: { Label("Add spool type", systemImage: "plus") }
                        Button(role: .destructive) { confirmReset = true } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Spool catalog actions")
                }
            }
        }
        .overlay { if !loaded, error == nil { ProgressView() } }
        .disabled(busy)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in SpoolCatalogEditSheet(item: edit.item) { await load() } }
        .confirmationDialog("Delete this spool type?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete \(item.name)", role: .destructive) { delete(item) }
        } message: { _ in Text("Spools you already added aren't affected.") }
        .confirmationDialog("Reset the spool catalog?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete all and load defaults", role: .destructive) { reset() }
        } message: { Text("Every entry, including ones you added, is deleted and Bambuddy's default list is loaded. This can't be undone.") }
    }

    private func row(_ item: SpoolCatalogEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if item.isDefault { Text("Default").font(.caption2).foregroundStyle(Color.textMuted) }
            }
            Spacer()
            Text("\(item.weight) g").font(.subheadline.monospacedDigit()).foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(canWrite ? "Opens the editor" : "")
    }

    private func load() async {
        do {
            items = try await APIClient.shared.spoolCatalog()
            error = nil
        } catch { self.error = FriendlyError.message(error) }
        loaded = true
    }

    private func delete(_ item: SpoolCatalogEntry) {
        Task {
            do {
                try await APIClient.shared.deleteSpoolCatalogEntry(item.id)
                items.removeAll { $0.id == item.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func reset() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.resetSpoolCatalog()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

private struct SpoolCatalogEditSheet: View {
    let item: SpoolCatalogEntry?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var weight: String
    @State private var saving = false
    @State private var error: String?

    init(item: SpoolCatalogEntry?, onSaved: @escaping () async -> Void) {
        self.item = item
        self.onSaved = onSaved
        _name = State(initialValue: item?.name ?? "")
        _weight = State(initialValue: item.map { String($0.weight) } ?? "")
    }

    private var parsedWeight: Int? { Int(weight.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedWeight != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as Bambu Lab - Refill", text: $name)
                    TextField("Empty spool weight (g)", text: $weight).keyboardType(.numberPad)
                } footer: { Text("The weight of the empty spool, used to work out how much filament is left.") }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            }
            .farmBackground()
            .navigationTitle(item == nil ? "Add spool type" : "Edit spool type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid || saving) }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let grams = parsedWeight else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        saving = true
        Task {
            defer { saving = false }
            do {
                if let item { _ = try await APIClient.shared.updateSpoolCatalogEntry(item.id, name: trimmed, weight: grams) }
                else { _ = try await APIClient.shared.createSpoolCatalogEntry(name: trimmed, weight: grams) }
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
