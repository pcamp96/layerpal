import SwiftUI

/// Pressure-advance (K) profiles stored on one printer, per nozzle diameter. Reading needs
/// `kprofiles:read`. Edit, add and delete are MQTT commands: they need `kprofiles:update` /
/// `kprofiles:delete`, a printer that accepts control (not cloud-only), and Bambuddy refuses
/// those for API keys, so they run through the admin sign-in.
struct KProfilesView: View {
    let printerId: Int
    let printerName: String
    let model: String

    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var admin = AdminSession.shared
    @AppStorage("kprofiles.nozzleDiameter") private var nozzle = "0.4"
    @State private var profiles: [KProfile] = []
    @State private var builtin: [String: String] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var search = ""
    @State private var editing: KProfile?
    @State private var creating = false
    @State private var deleting: KProfile?
    @State private var busy = false

    static let nozzles = ["0.2", "0.4", "0.6", "0.8"]

    private var canWrite: Bool { farm.canControl(printerId) && farm.can("kprofiles:update") }
    private var canDelete: Bool { farm.canControl(printerId) && farm.can("kprofiles:delete") }
    private var dualNozzle: Bool { Self.isDualNozzle(model) || profiles.contains { $0.extruderId == 1 } }

    static func isDualNozzle(_ model: String) -> Bool {
        ["H2D", "H2D Pro", "H2C", "X2D"].contains(model)
    }

    private var shown: [KProfile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return profiles
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || filamentName($0).lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Picker("Nozzle", selection: $nozzle) {
                    ForEach(Self.nozzles, id: \.self) { Text("\($0) mm").tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Nozzle diameter")
            } footer: {
                Text("The printer answers over MQTT, so this can take a few seconds.")
            }
            if !canWrite, farm.can("kprofiles:read") {
                Section {
                    Label(readOnlyReason, systemImage: "lock").font(.footnote).foregroundStyle(Color.textMuted)
                }
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(Color.statusError)
                    Button("Try again") { Task { await load() } }
                }
            }
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(Color.accentTeal) } }
            Section {
                ForEach(shown) { profile in
                    Button { if canWrite { editing = profile } } label: { row(profile) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canDelete {
                                Button(role: .destructive) { deleting = profile } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .accessibilityHint(canWrite ? "Opens the editor" : "")
                }
            } header: {
                if !profiles.isEmpty { Text("\(shown.count) profile\(shown.count == 1 ? "" : "s")") }
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Name or filament")
        .navigationTitle("K-profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New K-profile")
                }
            }
        }
        .overlay {
            if loading, profiles.isEmpty { ProgressView("Asking \(printerName)…") }
            else if !loading, profiles.isEmpty, error == nil {
                ContentUnavailableView("No K-profiles", systemImage: "waveform.path",
                                       description: Text("\(printerName) has none stored for a \(nozzle) mm nozzle."))
            }
        }
        .task(id: nozzle) { await load() }
        .refreshable { await load() }
        .disabled(busy)
        .sheet(item: $editing) { profile in
            KProfileEditSheet(printerId: printerId, nozzle: nozzle, dualNozzle: dualNozzle, model: model, existing: profile,
                              builtin: builtin) { message in
                notice = message
                Task { await load() }
            }
        }
        .sheet(isPresented: $creating) {
            KProfileEditSheet(printerId: printerId, nozzle: nozzle, dualNozzle: dualNozzle, model: model, existing: nil,
                              builtin: builtin) { message in
                notice = message
                Task { await load() }
            }
        }
        .sheet(isPresented: $admin.showSignIn) { AdminSignInSheet() }
        .confirmationDialog("Delete this K-profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { profile in
            Button("Delete \(profile.name)", role: .destructive) { delete(profile) }
        } message: { profile in
            Text("It is removed from \(printerName). Slots using it fall back to the default.")
        }
    }

    private var readOnlyReason: String {
        if !farm.canControl { return "Your account can't change printer settings, so K-profiles are read-only." }
        if !farm.canControl(printerId) { return "This printer isn't in local control mode (developer mode), so K-profiles are read-only." }
        return "Your account can't edit K-profiles."
    }

    private func filamentName(_ p: KProfile) -> String { builtin[p.filamentId] ?? p.filamentId }

    private func row(_ p: KProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.name.isEmpty ? filamentName(p) : p.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(Self.formatK(p.kValue)).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Color.accentTeal)
            }
            HStack(spacing: 6) {
                Text(filamentName(p)).lineLimit(1)
                Pill(text: p.isHighFlow ? "High flow" : "Standard")
                if dualNozzle { Pill(text: p.extruderId == 1 ? "Left" : "Right") }
                if let n = Double(p.nCoef), n != 0 { Text("n \(Self.formatK(p.nCoef))") }
            }
            .font(.caption).foregroundStyle(Color.textMuted)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.name), \(filamentName(p)), K \(Self.formatK(p.kValue)), \(p.isHighFlow ? "high flow" : "standard") nozzle")
    }

    static func formatK(_ raw: String) -> String {
        guard let v = Double(raw) else { return raw }
        return String(format: "%.3f", v)
    }

    // MARK: Actions

    private func load() async {
        loading = true
        defer { loading = false }
        if builtin.isEmpty, let list = try? await APIClient.shared.builtinFilaments() {
            builtin = Dictionary(list.map { ($0.filamentId, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        do {
            profiles = try await APIClient.shared.kProfiles(printerId: printerId, nozzleDiameter: nozzle)
            error = nil
        } catch {
            profiles = []
            self.error = Self.readMessage(error)
        }
    }

    static func readMessage(_ error: Error) -> String {
        if case let APIError.http(code, _) = error {
            if code == 400 { return "The printer isn't connected, so it can't be asked for K-profiles." }
            if code == 504 { return "The printer didn't answer the K-profile request. Try again in a moment." }
            if code == 403 { return "Your account or this app's API key can't read K-profiles." }
        }
        return FriendlyError.message(error)
    }

    private func delete(_ profile: KProfile) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await AdminSession.shared.perform { bearer in
                    try await APIClient.shared.deleteKProfile(printerId: printerId, profile, bearer: bearer)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Deleted \(profile.name)."
                error = nil
                await load()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = AdminError.friendly(error)
            }
        }
    }
}

/// Create or edit one K-profile. Edits change the name and K value; the filament, flow and
/// nozzle stay as stored (the printer keys its calibration table by them).
struct KProfileEditSheet: View {
    let printerId: Int
    let nozzle: String
    let dualNozzle: Bool
    let model: String
    let existing: KProfile?
    let builtin: [String: String]
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kText: String
    @State private var filamentId: String
    @State private var highFlow: Bool
    @State private var extruders: Set<Int>
    @State private var picking = false
    @State private var error: String?
    @State private var saving = false

    init(printerId: Int, nozzle: String, dualNozzle: Bool, model: String, existing: KProfile?, builtin: [String: String],
         onSaved: @escaping (String) -> Void) {
        self.printerId = printerId
        self.nozzle = nozzle
        self.dualNozzle = dualNozzle
        self.model = model
        self.existing = existing
        self.builtin = builtin
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _kText = State(initialValue: existing.map { KProfilesView.formatK($0.kValue) } ?? "0.020")
        _filamentId = State(initialValue: existing?.filamentId ?? "")
        _highFlow = State(initialValue: existing?.isHighFlow ?? false)
        _extruders = State(initialValue: existing.map { [$0.extruderId] } ?? (dualNozzle ? [0, 1] : [0]))
    }

    private var supportsFlowChoice: Bool { !(["A1", "A1 Mini", "A2L"].contains(model)) }
    private var kValue: Double? { Double(kText.replacingOccurrences(of: ",", with: ".")) }
    private var valid: Bool {
        guard let k = kValue, k >= 0, k <= 2 else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && !filamentId.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament") {
                    if existing != nil {
                        LabeledContent("Filament", value: builtin[filamentId] ?? filamentId)
                    } else {
                        Button { picking = true } label: {
                            HStack {
                                Text(filamentId.isEmpty ? "Choose a filament" : (builtin[filamentId] ?? filamentId))
                                    .foregroundStyle(filamentId.isEmpty ? Color.accentTeal : .primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                    }
                }
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("K value", text: $kText).keyboardType(.decimalPad)
                    if let existing, let n = Double(existing.nCoef), n != 0 {
                        LabeledContent("N coefficient", value: KProfilesView.formatK(existing.nCoef))
                    }
                }
                Section {
                    LabeledContent("Nozzle", value: "\(existing?.nozzleDiameter.isEmpty == false ? existing!.nozzleDiameter : nozzle) mm")
                    if existing == nil, supportsFlowChoice {
                        Picker("Flow", selection: $highFlow) {
                            Text("Standard").tag(false)
                            Text("High flow").tag(true)
                        }
                    }
                    if existing == nil, dualNozzle {
                        Toggle("Right nozzle", isOn: binding(for: 0))
                        Toggle("Left nozzle", isOn: binding(for: 1))
                    }
                } footer: {
                    if existing != nil { Text("Filament, flow and nozzle can't change after creation. Create a new profile instead.") }
                    else if dualNozzle { Text("Both nozzles are saved in one command.") }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgPrimary)
            .navigationTitle(existing == nil ? "New K-profile" : "Edit K-profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!valid || saving || (existing == nil && extruders.isEmpty))
                }
            }
            .sheet(isPresented: $picking) {
                FilamentIdPicker(builtin: builtin) { id, title in
                    filamentId = id
                    if name.isEmpty { name = "\(highFlow ? "HF" : "S") \(title)" }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(for extruder: Int) -> Binding<Bool> {
        Binding(get: { extruders.contains(extruder) },
                set: { on in if on { extruders.insert(extruder) } else { extruders.remove(extruder) } })
    }

    private func save() {
        guard let k = kValue else { return }
        saving = true
        let kString = String(format: "%.6f", k)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { saving = false }
            do {
                let ack: KProfileAck = try await AdminSession.shared.perform { bearer in
                    if let existing {
                        var body = KProfileBody(slotId: existing.slotId, extruderId: existing.extruderId,
                                                nozzleId: existing.nozzleId.isEmpty ? "HS00-\(existing.nozzleDiameter)" : existing.nozzleId,
                                                nozzleDiameter: existing.nozzleDiameter.isEmpty ? nozzle : existing.nozzleDiameter,
                                                filamentId: existing.filamentId, name: trimmed, kValue: kString)
                        body.nCoef = existing.nCoef
                        body.amsId = existing.amsId
                        body.trayId = existing.trayId
                        body.settingId = existing.settingId
                        return try await APIClient.shared.saveKProfile(printerId: printerId, body, bearer: bearer)
                    }
                    let nozzleId = "\(highFlow ? "HH00" : "HS00")-\(nozzle)"
                    let bodies = extruders.sorted().map {
                        KProfileBody(extruderId: $0, nozzleId: nozzleId, nozzleDiameter: nozzle, filamentId: filamentId, name: trimmed, kValue: kString)
                    }
                    if bodies.count > 1 { return try await APIClient.shared.saveKProfilesBatch(printerId: printerId, bodies, bearer: bearer) }
                    return try await APIClient.shared.saveKProfile(printerId: printerId, bodies[0], bearer: bearer)
                }
                UINotificationFeedbackGenerator().notificationOccurred(ack.confirmed == false ? .warning : .success)
                onSaved(ack.message ?? "Saved.")
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = AdminError.friendly(error)
            }
        }
    }
}

/// Searchable list of Bambuddy's built-in filament ids (GET /cloud/builtin-filaments).
struct FilamentIdPicker: View {
    let builtin: [String: String]
    let onPick: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var items: [(id: String, name: String)] {
        let q = search.lowercased()
        return builtin.map { ($0.key, $0.value) }
            .filter { q.isEmpty || $0.1.lowercased().contains(q) || $0.0.lowercased().contains(q) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(items, id: \.id) { item in
                Button {
                    onPick(item.id, item.name)
                    dismiss()
                } label: {
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(item.id).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                    }
                }
                .foregroundStyle(.primary)
            }
            .farmBackground()
            .searchable(text: $search, prompt: "Filament")
            .overlay { if builtin.isEmpty { ContentUnavailableView("No filaments loaded", systemImage: "questionmark.folder") } }
            .navigationTitle("Filament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
