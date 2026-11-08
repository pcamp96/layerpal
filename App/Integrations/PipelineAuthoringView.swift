import SwiftUI
import UIKit

/// Create, edit and delete slicer pipelines (Bambuddy: Settings > Slicer pipelines). Writing pipelines
/// is `pipelines:write`, which Bambuddy keeps admin-only, so this uses the admin session.
struct PipelineManagerView: View {
    var onChanged: () async -> Void
    var body: some View {
        AdminGate(title: "Manage pipelines", permission: "pipelines:write") { PipelineManagerList(onChanged: onChanged) }
    }
}

private struct PipelineManagerList: View {
    var onChanged: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var pipelines: [PipelineConfig] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false
    @State private var pendingDelete: PipelineConfig?
    @StateObject private var printers = PrinterChoices()

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(pipelines) { pipeline in
                NavigationLink {
                    PipelineEditorView(pipeline: pipeline) { await reload() }
                } label: { row(pipeline) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = pipeline } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, pipelines.isEmpty, error == nil {
                ContentUnavailableView("No pipelines", systemImage: "arrow.triangle.branch",
                                       description: Text("A pipeline bundles printer, process and filament profiles so one tap slices and queues a file."))
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New pipeline")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { PipelineEditorView(pipeline: nil) { await reload() } }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "pipeline")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete pipeline", role: .destructive) { if let p = pendingDelete { delete(p) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its past runs stay in the history. This can't be undone.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ p: PipelineConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.name).font(.subheadline.weight(.semibold))
            if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(2) }
            Text(targetText(p)).font(.caption).foregroundStyle(Color.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func targetText(_ p: PipelineConfig) -> String {
        let target = p.targetKind == "specific_printer"
            ? (p.targetPrinterId.map { printers.name($0) } ?? "No printer chosen")
            : (p.targetModelClass.isEmpty ? "No model chosen" : "Any \(Printer.modelNames[p.targetModelClass] ?? p.targetModelClass)")
        return "\(target) · \(p.filaments.count) filament\(p.filaments.count == 1 ? "" : "s")"
    }

    private func load() async {
        do {
            pipelines = try await session.perform { try await APIClient.shared.authoringPipelines(bearer: $0) }
            await printers.load()
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func reload() async {
        await load()
        await onChanged()
    }

    private func delete(_ p: PipelineConfig) {
        pendingDelete = nil
        Task {
            do {
                try await session.perform { try await APIClient.shared.deletePipeline(p.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await reload()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Editor

private struct PipelineEditorView: View {
    let pipeline: PipelineConfig?
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = PipelineConfig()
    @State private var presets: SlicerPresetsResponse?
    @State private var presetsError: String?
    @State private var saving = false
    @State private var error: String?
    @State private var populated = false
    @StateObject private var printers = PrinterChoices()

    private var models: [String] {
        var seen = Set<String>()
        var list = printers.printers.compactMap(\.model).filter { seen.insert($0).inserted }.sorted()
        if !draft.targetModelClass.isEmpty, !list.contains(draft.targetModelClass) { list.insert(draft.targetModelClass, at: 0) }
        return list
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Description (optional)", text: $draft.description, axis: .vertical).lineLimit(1 ... 4)
            }
            profilesSection
            Section {
                Picker("Bed type", selection: $draft.bedType) {
                    Text("Use the file's setting").tag("")
                    ForEach(PipelineConfig.bedTypes, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("Overrides the plate the file was sliced for. Textured Cool Plate is OrcaSlicer only; Bambu Studio slices it as Cool Plate.")
            }
            targetSection
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
        }
        .farmBackground()
        .navigationTitle(pipeline == nil ? "New pipeline" : "Edit pipeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if pipeline == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button(pipeline == nil ? "Create" : "Save") { Task { await save() } }.disabled(!draft.isComplete) }
            }
        }
        .onAppear {
            guard !populated else { return }
            populated = true
            if let pipeline { draft = pipeline }
        }
        .task {
            await printers.load()
            do {
                presets = try await session.perform { try await APIClient.shared.slicerPresets(bearer: $0) }
            } catch {
                presetsError = AdminError.friendly(error)
            }
        }
    }

    // MARK: Profiles

    @ViewBuilder private var profilesSection: some View {
        Section {
            if let presetsError {
                Text("Couldn't load slicer profiles: \(presetsError)").font(.footnote).foregroundStyle(Color.statusError)
            } else if presets == nil {
                HStack { ProgressView(); Text("Loading slicer profiles").font(.footnote).foregroundStyle(Color.textMuted) }
            }
            NavigationLink {
                PresetPickerView(title: "Printer profile", tiers: tiers(\.printer), selected: draft.printer, compatiblePrinter: nil) { draft.printer = $0 }
            } label: { slotRow("Printer", draft.printer, slot: \.printer) }
            NavigationLink {
                PresetPickerView(title: "Process profile", tiers: tiers(\.process), selected: draft.process, compatiblePrinter: printerName) { draft.process = $0 }
            } label: { slotRow("Process", draft.process, slot: \.process) }
            ForEach(Array(draft.filaments.enumerated()), id: \.offset) { index, ref in
                NavigationLink {
                    PresetPickerView(title: "Filament \(index + 1)", tiers: tiers(\.filament), selected: ref, compatiblePrinter: printerName) {
                        if draft.filaments.indices.contains(index) { draft.filaments[index] = $0 }
                    }
                } label: { slotRow("Filament \(index + 1)", ref, slot: \.filament) }
                    .swipeActions { Button(role: .destructive) { draft.filaments.remove(at: index) } label: { Label("Remove", systemImage: "trash") } }
            }
            NavigationLink {
                PresetPickerView(title: "Add filament", tiers: tiers(\.filament), selected: nil, compatiblePrinter: printerName) { draft.filaments.append($0) }
            } label: { Label("Add filament", systemImage: "plus.circle") }
        } header: {
            Text("Slicer profiles")
        } footer: {
            Text("One filament per slot of the file you'll slice, in slot order. Profiles come from your local, Orca Cloud, Bambu Cloud and bundled lists.")
        }
    }

    private var printerName: String? {
        guard let ref = draft.printer, let preset = allPresets(\.printer).first(where: { $0.id == ref.id && $0.source == ref.source }) else { return nil }
        return preset.name
    }

    private func slotRow(_ title: String, _ ref: PipelineConfig.Ref?, slot: KeyPath<SlicerPresetsResponse.Slots, [SlicerPresetsResponse.Preset]>) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let ref {
                Text(allPresets(slot).first { $0.id == ref.id && $0.source == ref.source }?.name ?? ref.id)
                    .foregroundStyle(Color.textSecondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Choose").foregroundStyle(Color.statusWarning)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func slots(_ source: String) -> SlicerPresetsResponse.Slots? {
        switch source {
        case "orca_cloud": presets?.orcaCloud
        case "cloud": presets?.cloud
        case "local": presets?.local
        case "standard": presets?.standard
        default: nil
        }
    }

    private func allPresets(_ slot: KeyPath<SlicerPresetsResponse.Slots, [SlicerPresetsResponse.Preset]>) -> [SlicerPresetsResponse.Preset] {
        ["local", "orca_cloud", "cloud", "standard"].flatMap { slots($0)?[keyPath: slot] ?? [] }
    }

    private func tiers(_ slot: KeyPath<SlicerPresetsResponse.Slots, [SlicerPresetsResponse.Preset]>) -> [PresetTier] {
        [("local", "Local"), ("orca_cloud", "Orca Cloud"), ("cloud", "Bambu Cloud"), ("standard", "Bundled")].compactMap { source, title in
            let list = slots(source)?[keyPath: slot] ?? []
            return list.isEmpty ? nil : PresetTier(source: source, title: title, presets: list)
        }
    }

    // MARK: Target

    @ViewBuilder private var targetSection: some View {
        Section {
            Picker("Print on", selection: $draft.targetKind) {
                Text("Any printer of a model").tag("printer_class")
                Text("One specific printer").tag("specific_printer")
            }
            if draft.targetKind == "specific_printer" {
                Picker("Printer", selection: $draft.targetPrinterId) {
                    Text("Choose").tag(Int?.none)
                    if let id = draft.targetPrinterId, !printers.printers.contains(where: { $0.id == id }) {
                        Text(printers.name(id)).tag(Int?.some(id))
                    }
                    ForEach(printers.printers) { Text($0.name).tag(Int?.some($0.id)) }
                }
            } else {
                Picker("Model", selection: $draft.targetModelClass) {
                    Text("Choose").tag("")
                    ForEach(models, id: \.self) { Text(Printer.modelNames[$0] ?? $0).tag($0) }
                }
                Picker("Spread copies", selection: $draft.fanoutStrategy) {
                    ForEach(PipelineConfig.fanouts, id: \.value) { Text($0.label).tag($0.value) }
                }
            }
        } header: {
            Text("Where it prints")
        } footer: {
            Text(draft.targetKind == "specific_printer"
                ? "Every copy goes to this printer."
                : "Copies are queued on idle printers of this model. Round robin cycles through them; fill one first keeps every copy on a single printer.")
        }
    }

    // MARK: Save

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        var body = draft
        body.name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        body.description = body.description.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let pipeline {
                try await session.perform { try await APIClient.shared.updatePipeline(pipeline.id, body, bearer: $0) }
            } else {
                _ = try await session.perform { try await APIClient.shared.createPipeline(body, bearer: $0) }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Profile picker

private struct PresetTier: Identifiable {
    let source: String
    let title: String
    let presets: [SlicerPresetsResponse.Preset]
    var id: String { source }
}

private struct PresetPickerView: View {
    let title: String
    let tiers: [PresetTier]
    let selected: PipelineConfig.Ref?
    /// Printer profile name: local process/filament profiles that name other printers are hidden.
    let compatiblePrinter: String?
    var onPick: (PipelineConfig.Ref) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var onlyCompatible = true

    private func visible(_ p: SlicerPresetsResponse.Preset) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, !p.name.lowercased().contains(q) { return false }
        if onlyCompatible, let compatiblePrinter, let list = p.compatiblePrinters, !list.isEmpty, !list.contains(compatiblePrinter) { return false }
        return true
    }

    var body: some View {
        List {
            if compatiblePrinter != nil {
                Section { Toggle("Only profiles for this printer", isOn: $onlyCompatible) } footer: {
                    Text("Applies to local profiles, which say which printers they fit.")
                }
            }
            ForEach(tiers) { tier in
                let list = tier.presets.filter(visible)
                if !list.isEmpty {
                    Section(tier.title) {
                        ForEach(list) { preset in
                            Button {
                                onPick(.init(source: tier.source, id: preset.id))
                                UISelectionFeedbackGenerator().selectionChanged()
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        if !preset.subtitle.isEmpty { Text(preset.subtitle).font(.caption).foregroundStyle(Color.textMuted) }
                                    }
                                    Spacer()
                                    if selected?.source == tier.source, selected?.id == preset.id {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentTeal)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selected?.source == tier.source && selected?.id == preset.id ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Search profiles")
        .overlay { if tiers.isEmpty { ContentUnavailableView("No profiles", systemImage: "square.stack.3d.up.slash", description: Text("Bambuddy returned no profiles for this slot. Check the slicer and cloud sign-in in Bambuddy.")) } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension SlicerPresetsResponse.Preset {
    var subtitle: String { [filamentType, inherits].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}
