import SwiftUI

/// "Filament mapping" for a queued job: the same tray-per-slot picker as the add-to-queue sheet, run against the
/// job's own printer and plate and started from the mapping the job already stores. Saves with
/// PATCH /queue/{id} (`ams_mapping`, plus `skip_filament_check` and `nozzle_rack_choice` when they apply;
/// queue:update_own | update_all). Pending jobs on a specific printer only.
struct QueueItemMappingSheet: View {
    let item: QueueItem
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FilamentMappingModel()
    @State private var error: String?
    @State private var saving = false

    private var target: QueueTarget { QueueTarget(printerId: item.printerId, targetModel: nil) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.name).font(.headline)
                    LabeledContent("Printer", value: item.target)
                    if let plate = item.plateId { LabeledContent("Plate", value: "Plate \(plate)") }
                }
                FilamentMappingSection(model: model, target: target)
                if model.needs.isEmpty, !model.loadingNeeds, model.needsError == nil {
                    Section { Text("This job doesn't list any filament slots to map.").foregroundStyle(Color.textMuted) }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            }
            .farmBackground()
            .navigationTitle("Filament mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || model.mapping == nil)
                }
            }
            .task {
                model.printerModel = farm.printers.first { $0.id == item.printerId }?.model
                model.seed(mapping: item.amsMapping, rack: item.nozzleRackChoice)
                await model.loadNeeds(archiveId: item.archiveId, libraryFileId: item.libraryFileId, plateId: item.plateId)
                await model.loadPrinter(item.printerId)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let mapping = model.mapping else { return }
        var patch = SparsePatch()
        if mapping != item.amsMapping { patch["ams_mapping"] = .intList(mapping) }
        // Only ever set here, never cleared: an earlier "Print anyway" stays acknowledged across an edit.
        if model.substitutesMaterial { patch["skip_filament_check"] = .bool(true) }
        if model.hasRack {
            let rack = model.rackChoiceForRequest
            if rack != item.nozzleRackChoice, !(rack == nil && (item.nozzleRackChoice ?? [:]).isEmpty) {
                // null, not omitted: clearing the picks means "assign these again", and an omitted key keeps the old ones.
                patch["nozzle_rack_choice"] = rack.map(JSONScalar.intMap) ?? .null
            }
        }
        guard !patch.isEmpty else { dismiss(); return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            _ = try await APIClient.shared.updateQueueItem(item.id, patch)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }
}
