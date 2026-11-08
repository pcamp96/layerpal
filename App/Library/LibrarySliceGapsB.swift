import SwiftUI

/// Slice a library STL or 3MF on the server (Bambuddy's Slice dialog): printer, process and filament presets from
/// GET /slicer/presets, one filament per project slot, plate, bed type, auto-orient, auto-arrange and "slice as
/// designed" for 3MF. The job runs in the background on the server (202 + job id) and LayerPal polls
/// GET /slice-jobs/{id}. Needs library:upload. Not offered here (the web dialog has them): per-setting process
/// overrides and carrying the designer's individual setting tweaks; slicing STEP files is refused by the slicers.
struct LibrarySliceSheet: View {
    let fileId: Int
    let filename: String
    let isThreeMF: Bool
    let plates: [LibPlate]
    let initialPlate: Int?
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var presets: SlicerPresetsResponse?
    @State private var slots: [FilamentNeed] = []
    @State private var printerKey = ""
    @State private var processKey = ""
    @State private var filamentKeys: [String] = []
    @State private var plate: Int?
    @State private var bedType = ""
    @State private var autoOrient = false
    @State private var autoArrange = false
    @State private var embedded = false
    @State private var loading = true
    @State private var error: String?
    @State private var phase: Phase = .form
    @State private var visible = true

    private enum Phase: Equatable {
        case form
        case running(String)
        case finished(String)
    }

    private static let bedTypes = ["Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate", "Supertack Plate", "Textured Cool Plate"]

    private struct Choice: Identifiable, Hashable {
        let key: String
        let preset: SlicerPresetsResponse.Preset
        let tier: String
        var id: String { key }
        var label: String { "\(preset.name) · \(tier)" }
    }

    private func choices(_ pick: (SlicerPresetsResponse.Slots) -> [SlicerPresetsResponse.Preset]) -> [Choice] {
        guard let presets else { return [] }
        let tiers: [(String, SlicerPresetsResponse.Slots)] = [("My presets", presets.local), ("Standard", presets.standard),
                                                              ("Orca Cloud", presets.orcaCloud), ("Bambu Cloud", presets.cloud)]
        return tiers.flatMap { tier, slots in pick(slots).map { Choice(key: "\($0.source)|\($0.id)", preset: $0, tier: tier) } }
    }

    private var printerChoices: [Choice] { choices(\.printer) }
    private var selectedPrinter: Choice? { printerChoices.first { $0.key == printerKey } }

    /// Presets that list compatible printers are narrowed to the chosen one; if that empties the list, show everything.
    private func compatible(_ all: [Choice]) -> [Choice] {
        guard let name = selectedPrinter?.preset.name else { return all }
        let narrowed = all.filter { c in
            let list = c.preset.compatiblePrinters ?? []
            return list.isEmpty || list.contains(name)
        }
        return narrowed.isEmpty ? all : narrowed
    }

    private var processChoices: [Choice] { compatible(choices(\.process)) }
    private var filamentChoices: [Choice] { compatible(choices(\.filament)) }
    private var slotCount: Int { max(1, slots.count) }
    private var canStart: Bool {
        selectedPrinter != nil && processChoices.contains { $0.key == processKey } && filamentKeys.count == slotCount
            && filamentKeys.allSatisfy { k in filamentChoices.contains { $0.key == k } }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form: form
                case let .running(text): progress(text)
                case let .finished(text): finished(text)
                }
            }
            .farmBackground()
            .navigationTitle("Slice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .form ? "Cancel" : "Close") { dismiss() }
                }
                if phase == .form {
                    ToolbarItem(placement: .confirmationAction) { Button("Slice") { Task { await start() } }.disabled(!canStart) }
                }
            }
        }
        .presentationDetents([.large])
        .task { await load() }
        .onDisappear { visible = false }
        .onChange(of: plate) { _, _ in if isThreeMF, !loading { Task { await reloadSlots() } } }
    }

    // MARK: Phases

    private var form: some View {
        Form {
            if loading {
                Section { HStack { Text("Loading presets"); Spacer(); ProgressView() } }
            } else if let presets, presets.local.isEmpty, presets.standard.isEmpty, presets.orcaCloud.isEmpty, presets.cloud.isEmpty {
                Section { Text("Bambuddy has no slicer presets. Import presets in Bambuddy's Profiles page first.").font(.footnote) }
            } else if presets != nil {
                Section {
                    picker("Printer", selection: $printerKey, options: printerChoices)
                    picker("Process", selection: $processKey, options: processChoices)
                    ForEach(0 ..< slotCount, id: \.self) { index in
                        picker(slotTitle(index), selection: Binding(get: { index < filamentKeys.count ? filamentKeys[index] : "" },
                                                                    set: { if index < filamentKeys.count { filamentKeys[index] = $0 } }),
                               options: filamentChoices)
                    }
                } header: { Text("Presets") } footer: {
                    Text(embedded ? "These stay required but are not used while \"Slice as designed\" is on." : "Filament presets follow the project's slot order.")
                }
                Section {
                    if isThreeMF, plates.count > 1 {
                        Picker("Plate", selection: Binding(get: { plate ?? plates.first?.index ?? 1 }, set: { plate = $0 })) {
                            Text("All plates").tag(0)
                            ForEach(plates) { Text($0.title).tag($0.index) }
                        }
                    }
                    Picker("Bed type", selection: $bedType) {
                        Text("From the process preset").tag("")
                        ForEach(Self.bedTypes, id: \.self) { Text($0 == "Textured Cool Plate" ? "\($0) (OrcaSlicer only)" : $0).tag($0) }
                    }
                    Toggle("Auto orient", isOn: $autoOrient)
                    Toggle("Auto arrange", isOn: $autoArrange)
                    if isThreeMF { Toggle("Slice as designed", isOn: $embedded) }
                } header: { Text("Options") } footer: {
                    Text(isThreeMF ? "Auto orient rotates models and auto arrange moves them, so leave both off for a layout you set on purpose. Slice as designed uses the file's own settings and only makes sense when the printer matches the design."
                                   : "Auto orient rotates models and auto arrange repositions them on the plate.")
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            Section { } footer: { Text("The sliced file is saved next to the source as a new library file. Slicing runs on the Bambuddy server.") }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Slicing \(filename)").font(.headline).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
            Text("You can close this. The server keeps slicing and the new file appears in the library when it's done.")
                .font(.footnote).foregroundStyle(Color.textMuted).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func finished(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Color.accentTeal)
            Text("Sliced").font(.headline)
            Text(text).font(.subheadline).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(.accentTeal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func picker(_ title: String, selection: Binding<String>, options: [Choice]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { Text($0.label).tag($0.key) }
        }
    }

    private func slotTitle(_ index: Int) -> String {
        guard index < slots.count else { return "Filament" }
        let slot = slots[index]
        let base = "Filament \(slot.slotId)" + (slot.type.map { $0.isEmpty ? "" : " (\($0))" } ?? "")
        return slot.usedInPlate == false ? base + ", unused" : base
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        plate = isThreeMF && plates.count > 1 ? (initialPlate ?? plates.first?.index) : nil
        do {
            presets = try await APIClient.shared.slicerPresets()
            if isThreeMF { slots = (try? await APIClient.shared.libSliceSlots(fileId, plateId: plate)) ?? [] }
            applyDefaults()
            error = nil
        } catch { self.error = FriendlyError.message(error) }
    }

    private func reloadSlots() async {
        let previous = filamentKeys
        slots = (try? await APIClient.shared.libSliceSlots(fileId, plateId: plate == 0 ? nil : plate)) ?? slots
        applyDefaults()
        if previous.count == filamentKeys.count { filamentKeys = previous.enumerated().map { $0.element.isEmpty ? filamentKeys[$0.offset] : $0.element } }
    }

    /// First usable preset per slot: filament presets of the slot's material win over the first in the list.
    private func applyDefaults() {
        if selectedPrinter == nil { printerKey = printerChoices.first?.key ?? "" }
        if !processChoices.contains(where: { $0.key == processKey }) { processKey = processChoices.first?.key ?? "" }
        let pool = filamentChoices
        filamentKeys = (0 ..< slotCount).map { index in
            let type = index < slots.count ? (slots[index].type ?? "").lowercased() : ""
            let match = type.isEmpty ? nil : pool.first { ($0.preset.filamentType ?? "").lowercased() == type }
            return (match ?? pool.first)?.key ?? ""
        }
    }

    // MARK: Slice

    private func ref(_ key: String) -> SliceOptions.Ref? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? SliceOptions.Ref(source: parts[0], id: parts[1]) : nil
    }

    private func colour(_ raw: String?) -> String {
        var value = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, !value.hasPrefix("#") { value = "#" + value }
        let hex = value.dropFirst()
        return (hex.count == 6 || hex.count == 8) && hex.allSatisfy(\.isHexDigit) ? value : ""
    }

    private func start() async {
        guard let printer = ref(printerKey), let process = ref(processKey) else { return }
        let filaments = filamentKeys.compactMap(ref)
        guard filaments.count == slotCount else { return }
        var options = SliceOptions(printerPreset: printer, processPreset: process, filamentPresets: filaments)
        options.filamentColours = slots.isEmpty ? [] : slots.map { colour($0.color) }
        options.plate = isThreeMF && plates.count > 1 ? plate : nil
        options.bedType = bedType.isEmpty ? nil : bedType
        options.autoOrient = autoOrient
        options.autoArrange = autoArrange
        options.useEmbeddedSettings = isThreeMF && embedded
        error = nil
        phase = .running("Starting")
        do {
            let job = try await APIClient.shared.libStartSlice(fileId, options: options)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await poll(job)
        } catch {
            phase = .form
            self.error = FriendlyError.message(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func poll(_ job: Int) async {
        var failures = 0
        let deadline = Date().addingTimeInterval(20 * 60)
        while visible, Date() < deadline {
            do {
                let state = try await APIClient.shared.sliceJob(job)
                failures = 0
                if state.status == "completed" {
                    phase = .finished(summary(state.result))
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onDone()
                    return
                }
                if state.status == "failed" {
                    phase = .form
                    error = state.errorDetail ?? "The slicer failed."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    return
                }
                phase = .running(state.progressText ?? (state.status == "pending" ? "Waiting for the slicer" : "Slicing"))
            } catch {
                failures += 1
                if failures >= 5 { phase = .form; self.error = FriendlyError.message(error); return }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
        if visible, phase != .form { phase = .form; error = "Slicing is taking longer than expected. Check the library in a few minutes." }
    }

    private func summary(_ result: AdminJSON?) -> String {
        var parts: [String] = []
        if let name = result?["name"]?.string { parts.append(name) }
        if let secs = result?["printTimeSeconds"]?.int, secs > 0 { parts.append(formatMinutes(secs / 60)) }
        if let g = result?["filamentUsedG"], let grams = g.double ?? g.int.map(Double.init), grams > 0 { parts.append(formatGrams(grams)) }
        var text = parts.isEmpty ? "The sliced file is in your library." : parts.joined(separator: " · ")
        if let fallback = result?["externalWriteFallback"]?.string, !fallback.isEmpty {
            text += "\nSaved in managed storage because the source folder couldn't take it (\(fallback))."
        }
        return text
    }
}
