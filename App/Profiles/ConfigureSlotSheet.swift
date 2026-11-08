import SwiftUI

/// "Configure slot…": tell the printer what filament sits in an AMS slot (type, name, colour,
/// temperature range) and which K-profile to use. Sends POST /printers/{id}/slots/{ams}/{tray}/configure
/// (printers:control; an API key may use it). Presets come from Bambuddy's built-in filament table and
/// its local presets, plus the signed-in user's Bambu Cloud and Orca Cloud presets (admin session + a linked account).
struct ConfigureSlotSheet: View {
    let printerId: Int
    /// 0-3 for a classic AMS, 128-135 for AMS-HT, 255 for the external spool.
    let amsId: Int
    /// Slot within the unit; 0 or 1 for the external holders.
    let trayId: Int
    let title: String
    let current: AMSTray?
    let onDone: (String) -> Void

    struct Choice: Equatable {
        /// `cloud` = Bambu Cloud, `orca` = Orca Cloud (both need the signed-in Bambuddy session and a linked account).
        enum Source { case builtin, local, cloud, orca }
        let source: Source
        let name: String
        let builtinId: String?
        let local: LocalPreset?
        /// Bambu Cloud setting id, or Orca Cloud profile id.
        var remoteId: String?
        /// The cloud list's own filament id for the preset, when it gave one.
        var remoteFilamentId: String?
        static func == (a: Choice, b: Choice) -> Bool {
            a.source == b.source && a.name == b.name && a.builtinId == b.builtinId && a.local?.id == b.local?.id && a.remoteId == b.remoteId
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice?
    @State private var color: Color
    @State private var tempMin = 190
    @State private var tempMax = 230
    @State private var nozzle = "0.4"
    @State private var kProfiles: [KProfile] = []
    @State private var kProblem: String?
    @State private var kLoading = false
    @State private var selectedK: KProfile?
    @State private var slotExtruder: Int?
    @State private var dualNozzle = false
    @State private var picking = false
    @State private var error: String?
    @State private var saving = false
    @ObservedObject private var session = AdminSession.shared
    @EnvironmentObject private var farm: FarmStore
    /// Remember the chosen preset for this slot (PUT /slot-presets, printers:update, so it needs the admin session).
    @State private var remember = true
    @State private var recalledName: String?
    @State private var signingIn = false
    /// What the printer reports for this slot now (AMSTray doesn't carry tray_info_idx), to spot a slot re-configured elsewhere.
    @State private var slotInfoIdx: String?

    init(printerId: Int, amsId: Int, trayId: Int, title: String, current: AMSTray?, onDone: @escaping (String) -> Void) {
        self.printerId = printerId
        self.amsId = amsId
        self.trayId = trayId
        self.title = title
        self.current = current
        self.onDone = onDone
        _color = State(initialValue: Color(hexRGBA: current?.trayColor) ?? .white)
    }

    private var material: String {
        guard let choice else { return "PLA" }
        let parsed = PresetNaming.material(of: choice.name)
        if choice.source == .local {
            return PresetNaming.materials.contains(parsed.uppercased()) ? parsed.uppercased() : (choice.local?.filamentType ?? parsed)
        }
        return parsed
    }

    /// K-profiles that fit this slot: its nozzle on a dual-nozzle printer, the selected filament first.
    private var visibleProfiles: [KProfile] {
        let list = kProfiles.filter { !dualNozzle || slotExtruder == nil || $0.extruderId == slotExtruder }
        let filamentId = choice?.builtinId
        return list.sorted { a, b in
            let am = filamentId != nil && a.filamentId == filamentId, bm = filamentId != nil && b.filamentId == filamentId
            if am != bm { return am }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Slot", value: title)
                    if let current, !current.isEmpty { LabeledContent("Now", value: current.label) }
                }
                Section {
                    Button { picking = true } label: {
                        HStack {
                            Text(choice?.name ?? "Choose a filament preset")
                                .foregroundStyle(choice == nil ? Color.accentTeal : .primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                    ColorPicker("Colour", selection: $color, supportsOpacity: false)
                    Stepper("Min nozzle: \(tempMin)°C", value: $tempMin, in: 150 ... 350, step: 5)
                    Stepper("Max nozzle: \(tempMax)°C", value: $tempMax, in: 150 ... 350, step: 5)
                } header: {
                    Text("Filament")
                } footer: {
                    if let recalledName { Text("Preselected: \(recalledName) is what was last chosen for this slot.") }
                }
                rememberSection
                Section {
                    Picker("Nozzle", selection: $nozzle) {
                        ForEach(KProfilesView.nozzles, id: \.self) { Text("\($0) mm").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if kLoading {
                        HStack(spacing: 8) { ProgressView(); Text("Asking the printer…").foregroundStyle(Color.textMuted) }
                    } else if let kProblem {
                        Text(kProblem).font(.footnote).foregroundStyle(Color.textMuted)
                    }
                    Picker("K-profile", selection: $selectedK) {
                        Text("Default (0.020)").tag(KProfile?.none)
                        ForEach(visibleProfiles) { p in
                            Text("\(p.name) · \(KProfilesView.formatK(p.kValue))").tag(Optional(p))
                        }
                    }
                } header: {
                    Text("Pressure advance")
                } footer: {
                    Text("Profiles stored on the printer for this nozzle size. Pick one that matches the filament, or leave the default.")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgPrimary)
            .navigationTitle("Configure slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(choice == nil || saving || tempMin > tempMax)
                }
            }
            .task {
                await loadStatus()
                await recallPreset()
            }
            .task(id: nozzle) { await loadProfiles() }
            .onChange(of: choice) { _, new in
                applyDefaults(from: new)
                if new?.name != recalledName { recalledName = nil }
            }
            .sheet(isPresented: $picking) { SlotPresetPicker(selection: $choice) }
            .sheet(isPresented: $signingIn) { AdminSignInSheet() }
        }
        .presentationDetents([.large])
    }

    // MARK: Slot preset memory

    private var canRemember: Bool { session.isReady && session.can("printers:update") }

    @ViewBuilder private var rememberSection: some View {
        if canRemember {
            Section {
                Toggle("Remember for this slot", isOn: $remember)
            } footer: {
                Text("Bambuddy keeps the preset name for the slot and preselects it next time. Needs your admin sign-in.")
            }
        } else if !session.isReady {
            Section {
                Button { signingIn = true } label: { Label("Sign in to remember presets", systemImage: "person.badge.key") }
            } footer: {
                Text("Remembering a preset per slot is an admin action in Bambuddy; it isn't available to this app's API key.")
            }
        }
    }

    /// Preselects what was last chosen for this slot, unless the slot was configured from elsewhere since
    /// (the saved filament id no longer matches what the printer reports), as Bambuddy's own slot card does.
    private func recallPreset() async {
        guard choice == nil,
              let saved = try? await APIClient.shared.savedSlotPreset(printerId: printerId, amsId: amsId, trayId: trayId) else { return }
        if let now = slotInfoIdx, !now.isEmpty, let then = saved.trayInfoIdx, !then.isEmpty, now != then { return }
        let id = saved.presetId
        var resolved: Choice?
        if id.hasPrefix("builtin_") {
            resolved = Choice(source: .builtin, name: saved.presetName, builtinId: String(id.dropFirst("builtin_".count)), local: nil)
        } else if id.hasPrefix("local_") {
            guard farm.can("settings:read"), let number = Int(id.dropFirst("local_".count)),
                  let preset = try? await APIClient.shared.localPresets().filament.first(where: { $0.id == number }) else { return }
            resolved = Choice(source: .local, name: preset.name, builtinId: nil, local: preset)
        } else if id.hasPrefix("orca_") {
            resolved = Choice(source: .orca, name: saved.presetName, builtinId: nil, local: nil, remoteId: String(id.dropFirst("orca_".count)))
        } else if !id.isEmpty {
            resolved = Choice(source: .cloud, name: saved.presetName, builtinId: nil, local: nil, remoteId: id)
        }
        guard choice == nil, let resolved else { return }
        choice = resolved
        recalledName = resolved.name
    }

    // MARK: Loading

    private func loadStatus() async {
        guard let status = try? await APIClient.shared.mappingStatus(printerId: printerId) else { return }
        let tray = amsId == 255 ? status.vtTray?.first { $0.id == 254 + trayId } : status.ams?.first { $0.id == amsId }?.tray?.first { $0.id == trayId }
        slotInfoIdx = tray?.trayInfoIdx
        if let diameter = status.nozzles?.first?.nozzleDiameter, KProfilesView.nozzles.contains(diameter) { nozzle = diameter }
        let map = status.amsExtruderMap ?? [:]
        dualNozzle = (status.nozzles ?? []).dropFirst().first.map { ($0.nozzleDiameter ?? "").isEmpty == false } == true || !map.isEmpty
        slotExtruder = amsId == 255 ? (trayId == 0 || trayId == 1 ? 1 - trayId : nil) : map[String(amsId)]
    }

    private func loadProfiles() async {
        kLoading = true
        defer { kLoading = false }
        selectedK = nil
        do {
            kProfiles = try await APIClient.shared.kProfiles(printerId: printerId, nozzleDiameter: nozzle)
            kProblem = kProfiles.isEmpty ? "No K-profiles are stored for a \(nozzle) mm nozzle." : nil
        } catch {
            kProfiles = []
            kProblem = KProfilesView.readMessage(error) + " The default K value will be used."
        }
    }

    private func applyDefaults(from new: Choice?) {
        guard let new else { return }
        if new.source == .local, let local = new.local {
            if let hex = local.defaultFilamentColour, let c = Color(hexRGBA: hex.replacingOccurrences(of: "#", with: "")) { color = c }
            if let lo = local.nozzleTempMin, let hi = local.nozzleTempMax { tempMin = lo; tempMax = hi; return }
        }
        let range = PresetNaming.nozzleRange(material)
        tempMin = range.min
        tempMax = range.max
    }

    // MARK: Apply

    private func apply() {
        guard let choice else { return }
        saving = true
        error = nil
        let mat = material
        let name = PresetNaming.cleanName(choice.name)
        Task {
            defer { saving = false }
            do {
                var trayInfoIdx = choice.source == .builtin ? (choice.builtinId ?? "") : PresetNaming.genericId(for: mat)
                var settingId = ""
                var orcaId = ""
                switch choice.source {
                case .builtin, .local:
                    break
                case .orca:
                    // The backend looks up the profile's own filament id from orca_profile_id (following parents);
                    // sending none is how it knows to. The profile id is a UUID, foreign to the printer.
                    trayInfoIdx = ""
                    orcaId = choice.remoteId ?? ""
                case .cloud:
                    let id = choice.remoteId ?? ""
                    settingId = id
                    trayInfoIdx = await cloudFilamentId(for: choice)
                }
                var config = SlotConfiguration(trayInfoIdx: trayInfoIdx, trayType: mat, traySubBrands: name,
                                               trayColor: color.hexRGB + "FF", nozzleTempMin: tempMin, nozzleTempMax: tempMax)
                config.nozzleDiameter = nozzle
                config.settingId = settingId
                config.orcaProfileId = orcaId
                if let k = selectedK {
                    config.caliIdx = k.slotId
                    config.kprofileFilamentId = k.filamentId
                    config.kprofileSettingId = k.settingId ?? ""
                    config.kValue = k.kNumber ?? 0
                }
                let result = try await APIClient.shared.configureSlot(printerId: printerId, amsId: amsId, trayId: trayId, config)
                var message = "\(title) is set to \(config.traySubBrands)."
                var warn = result.kValueUnsent == true
                if result.kValueUnsent == true { message += " The printer didn't accept the K value, so it kept its own." }
                if choice.source == .orca, let reason = result.orcaFallbackReason, !reason.isEmpty {
                    message += " Orca Cloud had no filament id for that profile, so a generic \(mat) id was used."
                    warn = true
                }
                if remember, canRemember {
                    let saved = await rememberPreset(choice, name: name, trayInfoIdx: result.trayInfoIdx ?? trayInfoIdx)
                    if !saved { message += " The preset wasn't remembered for this slot."; warn = true }
                }
                UINotificationFeedbackGenerator().notificationOccurred(warn ? .warning : .success)
                onDone(message)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    /// The filament id a Bambu Cloud preset puts in the slot. A user's own preset (setting id not
    /// starting with "GFS") asks the server for the preset's detail when the admin session is ready.
    private func cloudFilamentId(for choice: Choice) async -> String {
        let settingId = choice.remoteId ?? ""
        return await CloudPresetIds.filamentId(listId: choice.remoteFilamentId, settingId: settingId, sessionReady: session.isReady) {
            let answer = try? await session.perform { await APIClient.shared.cloudPresetFilamentId(settingId, bearer: $0) }
            return answer ?? nil
        }
    }

    /// PUT /printers/{id}/slot-presets/{ams}/{tray}. Never fails the configure that already succeeded.
    private func rememberPreset(_ choice: Choice, name: String, trayInfoIdx: String) async -> Bool {
        let presetId: String
        let source: String
        switch choice.source {
        case .builtin: presetId = "builtin_\(choice.builtinId ?? "")"; source = "builtin"
        case .local: presetId = "local_\(choice.local?.id ?? 0)"; source = "local"
        case .cloud: presetId = choice.remoteId ?? ""; source = "cloud"
        case .orca: presetId = "orca_\(choice.remoteId ?? "")"; source = "orca_cloud"
        }
        guard !presetId.isEmpty else { return false }
        do {
            try await session.perform {
                try await APIClient.shared.saveSlotPreset(printerId: printerId, amsId: amsId, trayId: trayId, presetId: presetId,
                                                          presetName: name, source: source, trayInfoIdx: trayInfoIdx, bearer: $0)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Bambu Cloud preset ids. A preset is listed by setting id (for example "GFSA00_02"); the slot needs
/// the filament id ("GFA00").
enum CloudPresetIds {
    /// User-preset id prefixes. The printer can't do anything useful with them, so they aren't sent.
    private static let userPrefixes = ["PFUS", "PFSP", "PFCN"]

    static func filamentId(fromSetting id: String) -> String {
        let base = id.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let digits = { (s: Substring) in !s.isEmpty && s.allSatisfy(\.isNumber) }
        if base.hasPrefix("GFSNLS"), digits(base.dropFirst(6)) { return "GFSNL" + base.dropFirst(6) }
        if base.hasPrefix("GFSNL"), digits(base.dropFirst(5)) { return base }
        if base.hasPrefix("GFS"), let next = base.dropFirst(3).first {
            if next.isLetter { return "GF" + base.dropFirst(3) }
            return base
        }
        return base
    }

    /// The id to store for a Bambu Cloud preset: the list's own filament id, else one derived from the
    /// setting id. For a user's own preset, the server's detail lookup wins when it answers.
    static func filamentId(listId: String?, settingId: String, sessionReady: Bool,
                           detail: () async -> String?) async -> String {
        var result = (listId ?? "").isEmpty ? filamentId(fromSetting: settingId) : listId!
        if !settingId.hasPrefix("GFS"), sessionReady, let answer = await detail() { result = answer }
        if userPrefixes.contains(where: { result.hasPrefix($0) }) { return "" }
        return result
    }
}

/// Built-in, local, Bambu Cloud and Orca Cloud filament presets, searchable, for the slot sheet.
/// The two cloud tiers are the signed-in Bambuddy user's own accounts: they need the admin session
/// (cloud:auth / orca_cloud:auth are refused for API keys) and a linked cloud account.
private struct SlotPresetPicker: View {
    @Binding var selection: ConfigureSlotSheet.Choice?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var session = AdminSession.shared
    @State private var source = ConfigureSlotSheet.Choice.Source.builtin
    @State private var builtin: [BuiltinFilament] = []
    @State private var local: [LocalPreset] = []
    @State private var bambu: [CloudPreset] = []
    @State private var orca: [CloudPreset] = []
    @State private var bambuNote: String?
    @State private var orcaNote: String?
    @State private var cloudLoading = false
    @State private var bambuLoaded = false
    @State private var orcaLoaded = false
    @State private var search = ""
    @State private var loading = true
    @State private var notes: [String] = []
    @State private var signingIn = false

    private var canLocal: Bool { farm.can("settings:read") }
    private var isCloudTier: Bool { source == .cloud || source == .orca }

    private struct CloudKey: Hashable {
        let source: ConfigureSlotSheet.Choice.Source
        let ready: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Source", selection: $source) {
                    Text("Built-in").tag(ConfigureSlotSheet.Choice.Source.builtin)
                    if canLocal { Text("Local").tag(ConfigureSlotSheet.Choice.Source.local) }
                    Text("Cloud").tag(ConfigureSlotSheet.Choice.Source.cloud)
                    Text("Orca").tag(ConfigureSlotSheet.Choice.Source.orca)
                }
                .pickerStyle(.segmented)
                ForEach(notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(Color.textMuted) }
                switch source {
                case .builtin: builtinRows
                case .local: localRows
                case .cloud: cloudRows(bambu, note: bambuNote, name: "Bambu Cloud", loaded: bambuLoaded)
                case .orca: cloudRows(orca, note: orcaNote, name: "Orca Cloud", loaded: orcaLoaded)
                }
            }
            .farmBackground()
            .searchable(text: $search, prompt: "Search filaments")
            .overlay { if loading || (isCloudTier && cloudLoading) { ProgressView() } }
            .navigationTitle("Filament preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
            .task(id: CloudKey(source: source, ready: session.isReady)) { await loadCloud() }
            .sheet(isPresented: $signingIn) { AdminSignInSheet() }
        }
    }

    // MARK: Rows

    @ViewBuilder private var builtinRows: some View {
        ForEach(filteredBuiltin) { item in
            Button { pick(.init(source: .builtin, name: item.name, builtinId: item.filamentId, local: nil)) } label: {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.filamentId).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder private var localRows: some View {
        ForEach(filteredLocal) { preset in
            Button { pick(.init(source: .local, name: preset.name, builtinId: nil, local: preset)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                    if !preset.subtitle.isEmpty { Text(preset.subtitle).font(.caption).foregroundStyle(Color.textMuted) }
                }
            }
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder private func cloudRows(_ presets: [CloudPreset], note: String?, name: String, loaded: Bool) -> some View {
        if !session.isReady {
            Section {
                Button { signingIn = true } label: { Label("Sign in", systemImage: "person.badge.key") }
            } footer: {
                Text("\(name) presets belong to your own Bambuddy account. Bambuddy doesn't let this app's API key read them, so sign in to see them.")
            }
        } else if let note {
            Text(note).font(.footnote).foregroundStyle(Color.textMuted)
        } else if loaded {
            let rows = filtered(presets)
            if rows.isEmpty {
                Text(presets.isEmpty ? "No custom filament presets in this \(name) account." : "No presets match.")
                    .font(.footnote).foregroundStyle(Color.textMuted)
            }
            ForEach(rows) { preset in
                Button {
                    pick(.init(source: source, name: preset.name, builtinId: nil, local: nil,
                               remoteId: preset.settingId, remoteFilamentId: preset.filamentId))
                } label: {
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Image(systemName: source == .orca ? "cloud.fill" : "icloud.fill").font(.caption).foregroundStyle(Color.textMuted)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: Filtering

    private var filteredBuiltin: [BuiltinFilament] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = builtin.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return q.isEmpty ? sorted : sorted.filter { $0.name.lowercased().contains(q) || $0.filamentId.lowercased().contains(q) }
    }

    private var filteredLocal: [LocalPreset] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? local : local.filter { $0.name.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    private func filtered(_ list: [CloudPreset]) -> [CloudPreset] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return q.isEmpty ? sorted : sorted.filter { $0.name.lowercased().contains(q) }
    }

    private func pick(_ choice: ConfigureSlotSheet.Choice) {
        UISelectionFeedbackGenerator().selectionChanged()
        selection = choice
        dismiss()
    }

    // MARK: Loading

    private func load() async {
        do { builtin = try await APIClient.shared.builtinFilaments() } catch { notes.append("Built-in list unavailable: \(FriendlyError.message(error))") }
        if canLocal {
            do { local = try await APIClient.shared.localPresets().filament } catch { notes.append("Local presets unavailable: \(FriendlyError.message(error))") }
        }
        loading = false
    }

    /// Fetches the chosen cloud tier once the admin session exists. Not-linked and expired links are explained
    /// rather than treated as errors, and a cloud 401 must not look like an expired Bambuddy session, so the
    /// preset list itself is read with the bearer directly instead of through `perform`.
    private func loadCloud() async {
        guard isCloudTier, session.isReady else { return }
        let tier = source
        if tier == .cloud ? bambuLoaded : orcaLoaded { return }
        cloudLoading = true
        defer { cloudLoading = false }
        let api = APIClient.shared
        do {
            if tier == .cloud {
                let status = try await session.perform { try await api.cloudStatus(bearer: $0) }
                guard status.isAuthenticated else {
                    bambuNote = status.signInExpired == true
                        ? "Your Bambu Cloud sign-in has expired. Sign in to Bambu Cloud again in Bambuddy's web settings."
                        : "Bambu Cloud isn't linked to your Bambuddy account. Link it in Bambuddy's web settings, then come back."
                    bambuLoaded = true
                    return
                }
                bambu = try await api.cloudFilamentPresets(bearer: session.bearer).filter { $0.isCustom == true }
                bambuNote = nil
                bambuLoaded = true
            } else {
                let status = try await session.perform { try await api.orcaCloudStatus(bearer: $0) }
                guard status.connected else {
                    orcaNote = "Orca Cloud isn't connected to your Bambuddy account. Connect it in Bambuddy's web settings, then come back."
                    orcaLoaded = true
                    return
                }
                orca = try await api.orcaCloudFilamentPresets(bearer: session.bearer)
                orcaNote = nil
                orcaLoaded = true
            }
        } catch AdminError.signInRequired {
            // `perform` already asked for a sign-in; the rows show the Sign in button again.
        } catch {
            let message = AdminError.friendly(error)
            if tier == .cloud { bambuNote = message; bambuLoaded = true } else { orcaNote = message; orcaLoaded = true }
        }
    }
}
