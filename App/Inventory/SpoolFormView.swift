import SwiftUI

/// Create (editing == nil) or edit a spool. In Spoolman mode only the fields Spoolman's
/// inventory routes accept are shown.
struct SpoolFormView: View {
    @ObservedObject var store: InventoryStore
    let editing: Spool?
    let onSaved: (Spool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SpoolDraft
    @State private var hexText = ""
    @State private var showCatalog = false
    @State private var saving = false
    @State private var errorMessage: String?

    init(store: InventoryStore, editing: Spool?, onSaved: @escaping (Spool) -> Void) {
        self.store = store
        self.editing = editing
        self.onSaved = onSaved
        _draft = State(initialValue: editing.map(SpoolDraft.init) ?? SpoolDraft())
    }

    private static let commonMaterials = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA", "PET", "HIPS", "PLA-CF", "PETG-CF", "PA-CF", "PAHT-CF"]

    private var materialChoices: [String] {
        Array(Set(Self.commonMaterials + store.spools.compactMap(\.material))).filter { !$0.isEmpty }.sorted()
    }

    private var categoryChoices: [String] {
        Array(Set(store.spools.compactMap(\.category).filter { !$0.isEmpty })).sorted()
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hexRGBA: draft.rgba) ?? .gray },
            set: { new in
                guard let rgb = ColorHex.rgb(new) else { return }
                draft.rgba = rgb + String(draft.rgba.suffix(2))
                draft.hasColor = true
                draft.extraColors = "" // a hand-picked color replaces the catalog's multi-color stops
                hexText = rgb
            }
        )
    }

    private var problem: String? { draft.problem(spoolman: store.spoolman) }
    private var patch: InventoryPatch? { editing.map { draft.patch(from: $0, spoolman: store.spoolman) } }
    private var canSave: Bool { problem == nil && !saving && (editing == nil || patch?.isEmpty == false) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament") {
                    HStack {
                        TextField("Material (PLA, PETG…)", text: $draft.material).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Menu {
                            ForEach(materialChoices, id: \.self) { m in Button(m) { draft.material = m } }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                            .accessibilityLabel("Choose material")
                    }
                    TextField("Subtype (Basic, Matte, Silk…)", text: $draft.subtype)
                    TextField("Brand", text: $draft.brand)
                }
                Section {
                    TextField("Color name", text: $draft.colorName)
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    HStack {
                        Text("Hex").foregroundStyle(Color.textSecondary)
                        TextField("RRGGBB", text: $hexText)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .onChange(of: hexText) { _, text in
                                if let rgba = ColorHex.normalized(text) {
                                    draft.rgba = rgba
                                    draft.hasColor = true
                                }
                            }
                    }
                    if !draft.extraColors.isEmpty {
                        HStack {
                            SpoolSwatch(colors: previewColors, size: 24)
                            Text("Multi-color\(draft.effectType.isEmpty ? "" : " · \(draft.effectType)")").font(.footnote).foregroundStyle(Color.textSecondary)
                            Spacer()
                            Button("Clear") { draft.extraColors = ""; draft.effectType = "" }.font(.footnote)
                        }
                    }
                    Button { showCatalog = true } label: { Label("Pick from color catalog", systemImage: "swatchpalette") }
                } header: {
                    Text("Color")
                } footer: {
                    Text("Saved as RRGGBBAA. The catalog is Bambuddy's color list; it fills the name and color together.")
                }
                Section("Weight") {
                    numberField("Spool weight (g)", $draft.labelWeight)
                    numberField("Empty spool (g)", $draft.coreWeight)
                    numberField("Used (g)", $draft.weightUsed)
                }
                if !store.spoolman {
                    Section("Printing") {
                        numberField("Nozzle min (°C)", $draft.nozzleMin, decimal: false)
                        numberField("Nozzle max (°C)", $draft.nozzleMax, decimal: false)
                        numberField("Low-stock alert (%)", $draft.lowStockPct, decimal: false, prompt: "Global \(Int(store.lowStockThreshold))")
                    }
                }
                Section("Inventory") {
                    numberField("Cost per kg", $draft.costPerKg)
                    if !store.spoolman {
                        HStack {
                            TextField("Category", text: $draft.category)
                            if !categoryChoices.isEmpty {
                                Menu {
                                    ForEach(categoryChoices, id: \.self) { c in Button(c) { draft.category = c } }
                                } label: { Image(systemName: "chevron.up.chevron.down") }
                                    .accessibilityLabel("Choose category")
                            }
                        }
                    }
                    TextField("Storage location", text: $draft.storageLocation)
                    TextField("Note", text: $draft.note, axis: .vertical).lineLimit(1 ... 4)
                }
                if let problem, !isPristine {
                    Section { Text(problem).font(.footnote).foregroundStyle(Color.statusError) }
                }
                if store.spoolman {
                    Section {
                        Text("Spoolman keeps category, nozzle temperatures and the low-stock alert out of this form. Emptying subtype, brand or cost can't be done from here.")
                            .font(.footnote).foregroundStyle(Color.textMuted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgPrimary)
            .navigationTitle(editing == nil ? "New spool" : "Edit spool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { save() }.disabled(!canSave) }
                }
            }
            .sheet(isPresented: $showCatalog) {
                ColorCatalogSheet(brand: draft.brand, material: draft.material) { entry in apply(entry) }
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }), presenting: errorMessage) { _ in
                Button("OK") { errorMessage = nil }
            } message: { Text($0) }
            .onAppear {
                if draft.hasColor { hexText = String(draft.rgba.prefix(6)) }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    /// Don't nag about a blank new form before the user has typed anything.
    private var isPristine: Bool { editing == nil && draft.material.isEmpty }

    private var previewColors: [Color] {
        ([draft.rgba] + draft.extraColors.split(separator: ",").map(String.init)).compactMap { Color(hexRGBA: $0) }
    }

    private func numberField(_ title: String, _ text: Binding<String>, decimal: Bool = true, prompt: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(prompt ?? "", text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
        }
    }

    private func apply(_ entry: ColorEntry) {
        draft.colorName = entry.colorName
        draft.rgba = entry.rgba
        draft.hasColor = true
        draft.extraColors = entry.extraColors ?? ""
        draft.effectType = entry.effectType ?? ""
        hexText = String(entry.rgba.prefix(6))
        if draft.brand.isEmpty { draft.brand = entry.manufacturer }
        if draft.material.isEmpty, let m = entry.material { draft.material = m }
    }

    private func save() {
        if let problem {
            errorMessage = problem
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved: Spool
                if let editing {
                    guard let patch, !patch.isEmpty else { dismiss(); return }
                    saved = try await store.update(editing.id, patch)
                } else {
                    saved = try await store.create(draft)
                }
                InventoryHaptics.success()
                onSaved(saved)
                dismiss()
            } catch {
                InventoryHaptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Bambuddy's color catalog (GET /inventory/colors/search, inventory:read). Filters on brand and
/// material run on the server (at most 100 rows); the name box filters what came back.
struct ColorCatalogSheet: View {
    @State var brand: String
    @State var material: String
    let onPick: (ColorEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ColorEntry] = []
    @State private var query = ""
    @State private var loading = false
    @State private var failure: String?

    init(brand: String, material: String, onPick: @escaping (ColorEntry) -> Void) {
        _brand = State(initialValue: brand)
        _material = State(initialValue: material)
        self.onPick = onPick
    }

    private var shown: [ColorEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? entries : entries.filter { $0.colorName.lowercased().contains(q) || $0.hexColor.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Brand", text: $brand)
                    TextField("Material", text: $material)
                } footer: {
                    Text("Leave a box empty to search every brand or material.")
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(Color.statusError) }
                Section(entries.count >= 100 ? "First 100 matches" : "Matches") {
                    ForEach(shown) { entry in
                        Button {
                            onPick(entry)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                SpoolSwatch(colors: ([entry.rgba] + (entry.extraColors ?? "").split(separator: ",").map(String.init)).compactMap { Color(hexRGBA: $0) }, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.colorName).foregroundStyle(.primary)
                                    Text([entry.manufacturer, entry.material].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Color.textMuted)
                                }
                                Spacer()
                                Text("#" + entry.rgba.prefix(6)).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                            }
                        }
                        .accessibilityLabel("\(entry.colorName), \(entry.manufacturer)")
                    }
                }
            }
            .farmBackground()
            .navigationTitle("Color catalog")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Color name or hex")
            .overlay {
                if loading, entries.isEmpty { ProgressView() }
                else if !loading, shown.isEmpty, failure == nil { ContentUnavailableView.search }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: brand + "|" + material) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                await load()
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await APIClient.shared.colorCatalog(manufacturer: brand.trimmingCharacters(in: .whitespaces),
                                                              material: material.trimmingCharacters(in: .whitespaces))
            failure = nil
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
