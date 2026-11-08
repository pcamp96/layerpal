import SwiftUI

/// Plate choice for a multi-plate archive or library file, with each plate's thumbnail.
struct PlatePickerSection: View {
    var archiveId: Int?
    var libraryFileId: Int?
    /// Preselected plate (a reprint of one plate, or the plate chosen on the file's page).
    var preferredPlate: Int?
    @Binding var plateId: Int?
    @State private var plates: [Row] = []

    private struct Row: Identifiable {
        let index: Int
        let title: String
        let seconds: Int?
        let grams: Double?
        let thumbnailPath: String?
        var id: Int { index }
    }

    init(archiveId: Int? = nil, libraryFileId: Int? = nil, preferredPlate: Int? = nil, plateId: Binding<Int?>) {
        self.archiveId = archiveId
        self.libraryFileId = libraryFileId
        self.preferredPlate = preferredPlate
        _plateId = plateId
    }

    var body: some View {
        Group {
            if plates.count > 1 {
                Section("Plate") {
                    ForEach(plates) { plate in
                        Button { plateId = plate.index } label: {
                            HStack(spacing: 12) {
                                RemoteImage(path: plate.thumbnailPath)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plate.title)
                                    HStack(spacing: 8) {
                                        if let s = plate.seconds, s > 0 { Text(formatMinutes(s / 60)) }
                                        if let g = plate.grams, g > 0 { Text(formatGrams(g)) }
                                    }
                                    .font(.caption).foregroundStyle(Color.textMuted)
                                }
                                Spacer()
                                if plateId == plate.index { Image(systemName: "checkmark").foregroundStyle(Color.accentTeal) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(plateId == plate.index ? .isSelected : [])
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let archiveId {
            let list = (try? await APIClient.shared.archivePlates(archiveId)) ?? []
            plates = list.map {
                Row(index: $0.index, title: $0.title, seconds: $0.printTimeSeconds, grams: $0.filamentUsedGrams, thumbnailPath: $0.thumbnailPath)
            }
        } else if let libraryFileId {
            let list = (try? await APIClient.shared.libPlates(libraryFileId)) ?? []
            plates = list.map {
                Row(index: $0.index, title: $0.title, seconds: $0.printTimeSeconds.map { Int($0) }, grams: $0.filamentUsedGrams,
                    thumbnailPath: $0.hasThumbnail == true ? "library/files/\(libraryFileId)/plate-thumbnail/\($0.index)" : nil)
            }
        }
        if plates.count > 1 {
            if let preferredPlate, plates.contains(where: { $0.index == preferredPlate }) { plateId = preferredPlate }
            else if plateId == nil { plateId = plates.first?.index }
        }
    }
}

/// "Where should this print?", the filament mapping, and the options Bambuddy's dispatch dialog offers.
struct TargetPicker: View {
    let title: String
    let slicedFor: String?
    var archiveId: Int?
    /// Library files get plates and filament mapping too.
    var libraryFileId: Int?
    var initialPlateId: Int?
    let onConfirm: (QueueRequest) async throws -> Void
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mapping = FilamentMappingModel()
    @State private var target = QueueTarget()
    @State private var quantity = 1
    @State private var plateId: Int?
    @State private var scheduled: Date?
    @State private var manualStart = false
    @State private var requirePrevious = false
    @State private var insertAtTop = false
    @State private var options = PrintOptions()
    @State private var error: String?
    @State private var saving = false
    @State private var confirmingShortfall = false

    init(title: String, slicedFor: String?, archiveId: Int?, libraryFileId: Int? = nil, initialPlateId: Int? = nil,
         onConfirm: @escaping (QueueRequest) async throws -> Void) {
        self.title = title
        self.slicedFor = slicedFor
        self.archiveId = archiveId
        self.libraryFileId = libraryFileId
        self.initialPlateId = initialPlateId
        self.onConfirm = onConfirm
        _plateId = State(initialValue: initialPlateId)
    }

    private var hasSource: Bool { archiveId != nil || libraryFileId != nil }

    private var shortfallMessage: String {
        var lines = mapping.shortfalls.map { row -> String in
            if row.match == .unassigned { return "Slot \(row.need.slotId) (\(row.need.materialName)) is not mapped." }
            guard let tray = row.tray else { return "No \(row.need.materialName) is loaded for slot \(row.need.slotId)." }
            return "Slot \(row.need.slotId) needs \(row.need.materialName) but is mapped to \(tray.type)."
        }
        lines += mapping.deficits.map(\.text)
        let tail = mapping.shortfalls.isEmpty
            ? "The spools may run out before the job finishes."
            : "The job may wait or fail until the right filament is loaded."
        return lines.joined(separator: "\n") + "\n" + tail
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(title).font(.headline) }
                TargetChoiceSection(target: $target, model: slicedFor)
                if hasSource {
                    PlatePickerSection(archiveId: archiveId, libraryFileId: libraryFileId, preferredPlate: initialPlateId, plateId: $plateId)
                    FilamentMappingSection(model: mapping, target: target)
                }
                Section {
                    Stepper("Copies: \(quantity)", value: $quantity, in: 1 ... 50)
                }
                Section {
                    DisclosureGroup("Options") {
                        ScheduleField(date: $scheduled)
                        Toggle("Wait for me to start it", isOn: $manualStart)
                        Toggle("Only if the previous print succeeded", isOn: $requirePrevious)
                        Toggle("Put at the front of the queue", isOn: $insertAtTop)
                        PrintOptionsForm(options: $options)
                    }
                }
                if let error { Text(error).foregroundStyle(Color.statusError).font(.footnote) }
            }
            .navigationTitle("Print where?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue") { attempt() }
                        .disabled(saving || (target.printerId == nil && target.targetModel == nil))
                }
            }
            .confirmationDialog("Check the filament", isPresented: $confirmingShortfall, titleVisibility: .visible) {
                Button("Queue anyway") { submit() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(shortfallMessage) }
            .onAppear {
                if target.printerId == nil, target.targetModel == nil {
                    if let slicedFor, !slicedFor.isEmpty {
                        target = QueueTarget(printerId: nil, targetModel: slicedFor)
                    } else if let first = farm.activePrinters.first {
                        target = QueueTarget(printerId: first.id, targetModel: nil)
                    }
                }
            }
            .task(id: plateId) {
                guard hasSource else { return }
                await mapping.loadNeeds(archiveId: archiveId, libraryFileId: libraryFileId, plateId: plateId)
            }
            .task(id: target.printerId) {
                mapping.printerModel = farm.printers.first { $0.id == target.printerId }?.model
                await mapping.loadPrinter(target.printerId)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func attempt() {
        if target.printerId != nil, !mapping.shortfalls.isEmpty || !mapping.deficits.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            confirmingShortfall = true
        } else {
            submit()
        }
    }

    private func submit() {
        saving = true
        Task {
            defer { saving = false }
            do {
                var request = QueueRequest(target: target, quantity: quantity)
                request.options = options
                request.manualStart = manualStart
                request.requirePreviousSuccess = requirePrevious
                request.insertAtTop = insertAtTop
                request.scheduledTime = scheduled
                request.plateId = plateId
                if target.printerId != nil {
                    request.amsMapping = mapping.mapping
                    // "Queue anyway" after the spool-weight warning is remembered so the scheduler
                    // doesn't flag the job again on its first tick.
                    request.skipFilamentCheck = mapping.substitutesMaterial || !mapping.deficits.isEmpty
                    request.nozzleRackChoice = mapping.rackChoiceForRequest
                }
                try await onConfirm(request)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
