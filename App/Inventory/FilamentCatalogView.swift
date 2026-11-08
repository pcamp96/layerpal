import SwiftUI

/// The filament catalog (/filament-catalog): reference filaments with cost, spool weight and temperatures.
/// Reading needs filaments:read; add, change and delete need filaments:create, :update and :delete.
/// No navigation stack of its own.
struct FilamentCatalogView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var items: [CatalogFilament] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Editing?
    @State private var deleting: CatalogFilament?
    @State private var confirmSeed = false

    private struct Editing: Identifiable { let item: CatalogFilament?; var id: Int { item?.id ?? -1 } }

    @ObservedObject private var admin = AdminSession.shared

    /// Catalog writes are admin-only on the server (no API-key scope), so they need the admin sign-in.
    private func allowed(_ permission: String) -> Bool { farm.can(permission) && (!admin.isSignedIn || admin.can(permission)) }
    private var canCreate: Bool { allowed("filaments:create") }
    private var canUpdate: Bool { allowed("filaments:update") }
    private var canDelete: Bool { allowed("filaments:delete") }

    private var visible: [CatalogFilament] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { [$0.name, $0.type, $0.brand, $0.color].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(q) }
    }

    private var grouped: [(String, [CatalogFilament])] {
        Dictionary(grouping: visible, by: \.type).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(grouped, id: \.0) { type, list in
                Section(type) {
                    ForEach(list) { item in
                        Button { if canUpdate { editing = Editing(item: item) } } label: { row(item) }
                            .swipeActions {
                                if canDelete { Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") } }
                            }
                            .listRowBackground(Color.bgCard)
                    }
                }
            }
            if loaded, items.isEmpty, error == nil {
                ContentUnavailableView("The catalog is empty", systemImage: "swatchpalette",
                                       description: Text(canCreate ? "Add a filament, or load Bambuddy's default list from the menu." : ""))
                    .listRowBackground(Color.clear)
            } else if loaded, visible.isEmpty, !items.isEmpty {
                ContentUnavailableView.search(text: search).listRowBackground(Color.clear)
            }
            if !canUpdate, !canCreate, loaded {
                Label("Read-only: your account can't change the catalog.", systemImage: "lock").font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .farmBackground()
        .navigationTitle("Filament catalog")
        .searchable(text: $search, prompt: "Name, material, brand")
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = Editing(item: nil) } label: { Label("Add filament", systemImage: "plus") }
                        Button { confirmSeed = true } label: { Label("Load default filaments", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add to catalog")
                }
            }
        }
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in CatalogFilamentEditSheet(item: edit.item, canSave: edit.item == nil ? canCreate : canUpdate) { await load() } }
        .sheet(isPresented: Binding(get: { admin.showSignIn && editing == nil }, set: { admin.showSignIn = $0 })) { AdminSignInSheet() }
        .confirmationDialog("Delete this filament?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete \(item.name)", role: .destructive) { delete(item) }
        } message: { _ in Text("Spools you already added aren't affected.") }
        .confirmationDialog("Load default filaments?", isPresented: $confirmSeed, titleVisibility: .visible) {
            Button("Load defaults") { seed() }
        } message: { Text("Bambuddy adds its starter list of filaments to the catalog.") }
    }

    private func row(_ item: CatalogFilament) -> some View {
        HStack(spacing: 12) {
            SpoolSwatch(colors: [item.swatch], size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if let brand = item.brand, !brand.isEmpty { Text(brand) }
                    Text("\(item.costPerKg.formatted(.currency(code: item.currency ?? "USD"))) per kg")
                    Text(formatGrams(item.spoolWeightG))
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
                if let lo = item.printTempMin, let hi = item.printTempMax {
                    Text("Nozzle \(lo)–\(hi)°C" + (item.bedTempMax.map { ", bed up to \($0)°C" } ?? ""))
                        .font(.caption2).foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            items = try await APIClient.shared.filamentCatalog()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func delete(_ item: CatalogFilament) {
        Task {
            do {
                try await AdminSession.shared.perform { try await APIClient.shared.deleteCatalogFilament(item.id, bearer: $0) }
                items.removeAll { $0.id == item.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func seed() {
        Task {
            do {
                try await AdminSession.shared.perform { try await APIClient.shared.seedCatalogDefaults(bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

struct CatalogFilamentEditSheet: View {
    let item: CatalogFilament?
    let canSave: Bool
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CatalogFilamentDraft
    @State private var color = Color.gray
    @State private var hasColor: Bool
    @ObservedObject private var admin = AdminSession.shared
    @State private var saving = false
    @State private var error: String?

    init(item: CatalogFilament?, canSave: Bool, onSaved: @escaping () async -> Void) {
        self.item = item
        self.canSave = canSave
        self.onSaved = onSaved
        let d = item.map(CatalogFilamentDraft.init) ?? CatalogFilamentDraft()
        _draft = State(initialValue: d)
        _hasColor = State(initialValue: !d.colorHex.isEmpty)
        _color = State(initialValue: Color(hexRGBA: d.colorHex.replacingOccurrences(of: "#", with: "")) ?? .gray)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament") {
                    TextField("Name", text: $draft.name)
                    TextField("Material, such as PLA", text: $draft.type).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Brand (optional)", text: $draft.brand)
                    TextField("Color name (optional)", text: $draft.color)
                    Toggle("Has a color swatch", isOn: $hasColor)
                    if hasColor { ColorPicker("Swatch", selection: $color, supportsOpacity: false) }
                }
                Section("Cost and weight") {
                    TextField("Cost per kg", text: $draft.costPerKg).keyboardType(.decimalPad)
                    TextField("Currency", text: $draft.currency).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Spool weight (g)", text: $draft.spoolWeight).keyboardType(.decimalPad)
                    TextField("Density (optional)", text: $draft.density).keyboardType(.decimalPad)
                }
                Section("Temperatures (°C, optional)") {
                    TextField("Nozzle minimum", text: $draft.printMin).keyboardType(.numberPad)
                    TextField("Nozzle maximum", text: $draft.printMax).keyboardType(.numberPad)
                    TextField("Bed minimum", text: $draft.bedMin).keyboardType(.numberPad)
                    TextField("Bed maximum", text: $draft.bedMax).keyboardType(.numberPad)
                }
                if !canSave { Label("Your account can't change the catalog.", systemImage: "lock").font(.footnote).foregroundStyle(Color.textSecondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .disabled(!canSave)
            .sheet(isPresented: $admin.showSignIn) { AdminSignInSheet() }
            .navigationTitle(item == nil ? "Add filament" : "Edit filament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if canSave { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving) } }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        var d = draft
        d.colorHex = hasColor ? "#" + (ColorHex.rgb(color) ?? "808080") : ""
        if let problem = d.problem { error = problem; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if let item {
                    let patch = d.patch(from: item)
                    if !patch.isEmpty { _ = try await AdminSession.shared.perform { try await APIClient.shared.updateCatalogFilament(item.id, patch, bearer: $0) } }
                } else {
                    _ = try await AdminSession.shared.perform { try await APIClient.shared.createCatalogFilament(d, bearer: $0) }
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
