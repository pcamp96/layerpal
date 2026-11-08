import SwiftUI

/// Profiles hub: K-profiles per printer, local presets, slicer presets and Bambuddy's built-in
/// filament table. No NavigationStack inside; push it from More. Everything here is read-only
/// except deleting a local preset (settings:update, which needs the admin sign-in).
struct ProfilesView: View {
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        List {
            if farm.can("kprofiles:read") {
                Section {
                    ForEach(farm.activePrinters) { printer in
                        NavigationLink {
                            KProfilesView(printerId: printer.id, printerName: printer.name, model: printer.displayModel)
                        } label: {
                            HStack {
                                Label(printer.name, systemImage: "waveform.path")
                                Spacer()
                                if farm.state(printer.id) == .offline {
                                    Text("Offline").font(.caption).foregroundStyle(Color.textMuted)
                                }
                            }
                        }
                    }
                } header: {
                    Text("K-profiles (pressure advance)")
                } footer: {
                    Text("Stored on each printer and read over MQTT, so the printer has to be online.")
                }
            }
            Section("Presets") {
                if farm.can("settings:read") {
                    NavigationLink { LocalPresetsView() } label: { IconLabel(title: "Local presets", symbol: "slider.horizontal.3") }
                }
                NavigationLink { SlicerPresetsView() } label: { IconLabel(title: "Slicer presets", symbol: "square.stack.3d.up", tint: .statusFinished) }
                if farm.can("filaments:read") {
                    NavigationLink { BuiltinFilamentsView() } label: { IconLabel(title: "Built-in filaments", symbol: "circle.hexagongrid", tint: .statusWarning) }
                }
            }
        }
        .farmBackground()
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Local presets

/// GET /local-presets/ grouped by type, with the preset's full settings on tap.
struct LocalPresetsView: View {
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var admin = AdminSession.shared
    @State private var presets = LocalPresetsResponse.empty
    @State private var type = "filament"
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var deleting: LocalPreset?

    private var current: [LocalPreset] {
        let list = type == "filament" ? presets.filament : (type == "printer" ? presets.printer : presets.process)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $type) {
                    Text("Filament (\(presets.filament.count))").tag("filament")
                    Text("Printer (\(presets.printer.count))").tag("printer")
                    Text("Process (\(presets.process.count))").tag("process")
                }
                .pickerStyle(.segmented)
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            Section {
                ForEach(current) { preset in
                    NavigationLink { LocalPresetDetailView(preset: preset) } label: { row(preset) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if farm.can("settings:update") {
                                Button(role: .destructive) { deleting = preset } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Search presets")
        .navigationTitle("Local presets")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading, current.isEmpty { ProgressView() }
            else if !loading, current.isEmpty, error == nil {
                ContentUnavailableView("No \(type) presets", systemImage: "slider.horizontal.3",
                                       description: Text("Import presets in Bambuddy on the web."))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $admin.showSignIn) { AdminSignInSheet() }
        .confirmationDialog("Delete this preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { preset in
            Button("Delete \(preset.name)", role: .destructive) { delete(preset) }
        } message: { _ in Text("It is removed from Bambuddy's local preset library. This can't be undone.") }
    }

    private func row(_ preset: LocalPreset) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let color = Color(hexRGBA: preset.defaultFilamentColour?.replacingOccurrences(of: "#", with: "")) {
                    Circle().fill(color).frame(width: 14, height: 14).overlay(Circle().stroke(Color.hairline, lineWidth: 0.5))
                        .accessibilityHidden(true)
                }
                Text(preset.name).font(.subheadline).lineLimit(2)
            }
            HStack(spacing: 8) {
                if !preset.subtitle.isEmpty { Text(preset.subtitle) }
                if let lo = preset.nozzleTempMin, let hi = preset.nozzleTempMax { Text("\(lo)-\(hi)°C") }
                if let pa = preset.pressureAdvance, !pa.isEmpty { Text("PA \(pa)") }
            }
            .font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
        }
    }

    private func load() async {
        do {
            presets = try await APIClient.shared.localPresets()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loading = false
    }

    private func delete(_ preset: LocalPreset) {
        Task {
            do {
                try await AdminSession.shared.perform { bearer in try await APIClient.shared.deleteLocalPreset(preset.id, bearer: bearer) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = AdminError.friendly(error)
            }
        }
    }
}

struct LocalPresetDetailView: View {
    let preset: LocalPreset
    @State private var settings: [(key: String, value: String)] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""

    private var shown: [(key: String, value: String)] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? settings : settings.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section("Summary") {
                fact("Type", preset.presetType.capitalized)
                fact("Source", preset.source)
                fact("Vendor", preset.filamentVendor)
                fact("Material", preset.filamentType)
                if let lo = preset.nozzleTempMin, let hi = preset.nozzleTempMax { fact("Nozzle", "\(lo)-\(hi) °C") }
                fact("Pressure advance", preset.pressureAdvance)
                fact("Cost per kg", preset.filamentCost)
                fact("Density", preset.filamentDensity)
                fact("Inherits", preset.inherits)
                fact("Compatible printers", preset.compatiblePrinters)
                fact("Version", preset.version)
                fact("Updated", preset.updatedAt?.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                else if loading { ProgressView() }
                ForEach(shown, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.key).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                        Text(item.value.isEmpty ? "(empty)" : item.value).font(.subheadline).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Settings (\(settings.count))")
            }
        }
        .farmBackground()
        .searchable(text: $filter, prompt: "Filter settings")
        .navigationTitle(preset.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { settings = try await APIClient.shared.localPresetSettings(preset.id) } catch { self.error = FriendlyError.message(error) }
            loading = false
        }
    }

    @ViewBuilder private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(label, value: value) }
    }
}

// MARK: - Slicer presets

/// GET /slicer/presets: the presets the slice dialog offers, by tier.
struct SlicerPresetsView: View {
    private enum Slot: String, CaseIterable, Identifiable {
        case filament = "Filament", process = "Process", printer = "Printer"
        var id: String { rawValue }
    }

    @State private var response: SlicerPresetsResponse?
    @State private var slot = Slot.filament
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?

    private func presets(_ slots: SlicerPresetsResponse.Slots) -> [SlicerPresetsResponse.Preset] {
        let list: [SlicerPresetsResponse.Preset]
        switch slot {
        case .filament: list = slots.filament
        case .process: list = slots.process
        case .printer: list = slots.printer
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
    }

    private var tiers: [(title: String, status: String?, slots: SlicerPresetsResponse.Slots)] {
        guard let response else { return [] }
        return [
            ("Local", nil, response.local),
            ("Bambu Cloud", response.cloudStatus, response.cloud),
            ("OrcaSlicer Cloud", response.orcaCloudStatus, response.orcaCloud),
            ("Standard", nil, response.standard),
        ]
    }

    var body: some View {
        List {
            Section {
                Picker("Slot", selection: $slot) { ForEach(Slot.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            ForEach(tiers, id: \.title) { tier in
                let list = presets(tier.slots)
                if !list.isEmpty || (tier.status != nil && tier.status != "ok") {
                    Section {
                        if let status = tier.status, status != "ok" {
                            Label(Self.statusText(status), systemImage: "cloud.slash").font(.footnote).foregroundStyle(Color.textMuted)
                        }
                        ForEach(list) { preset in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.subheadline)
                                let detail = [preset.filamentType, preset.inherits.map { "from \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
                                if !detail.isEmpty { Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(Color.textMuted) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("\(tier.title) (\(list.count))")
                    }
                }
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Search presets")
        .navigationTitle("Slicer presets")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private static func statusText(_ status: String) -> String {
        switch status {
        case "not_authenticated": "Not signed in to this cloud on Bambuddy."
        case "expired": "This cloud sign-in has expired."
        case "unreachable": "The cloud couldn't be reached."
        default: "Cloud presets unavailable (\(status))."
        }
    }

    private func load() async {
        do {
            response = try await APIClient.shared.slicerPresets()
            error = nil
        } catch {
            if case APIError.http(403, _) = error {
                self.error = "Slicer presets need the library upload permission, which this app's key or account doesn't have."
            } else {
                self.error = FriendlyError.message(error)
            }
        }
        loading = false
    }
}

// MARK: - Built-in filaments

struct BuiltinFilamentsView: View {
    @State private var items: [BuiltinFilament] = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?

    private var shown: [BuiltinFilament] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return q.isEmpty ? sorted : sorted.filter { $0.name.lowercased().contains(q) || $0.filamentId.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(shown) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.filamentId).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Name or id")
        .navigationTitle("Built-in filaments")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .task {
            do { items = try await APIClient.shared.builtinFilaments() } catch { self.error = FriendlyError.message(error) }
            loading = false
        }
    }
}
