import SwiftUI

/// One assignable slot, read from a printer's live status.
struct SlotTarget: Identifiable, Hashable {
    let amsId: Int
    let trayId: Int
    let title: String
    let unitTitle: String
    let colorHex: String?
    let filament: String

    var id: String { "\(amsId)-\(trayId)" }

    /// Slots with a verified id mapping: standard AMS units (up to 4 slots), AMS HT, and the
    /// one or two external spool holders (254 -> tray 0, 255 -> tray 1).
    static func targets(for status: PrinterStatus?) -> [SlotTarget] {
        guard let status else { return [] }
        var out: [SlotTarget] = []
        for unit in status.ams ?? [] where unit.hasStandardSlots {
            for tray in unit.tray ?? [] where tray.id >= 0 && tray.id <= (unit.rack ? 8 : 3) {
                out.append(SlotTarget(amsId: unit.id, trayId: tray.id,
                                      title: SlotNaming.name(amsId: unit.id, trayId: tray.id),
                                      unitTitle: unit.displayName,
                                      colorHex: tray.isEmpty ? nil : tray.trayColor,
                                      filament: tray.isEmpty ? "Empty" : tray.label))
            }
        }
        let external = (status.vtTray ?? []).sorted { $0.id < $1.id }
        if external.count <= 2 {
            for tray in external where tray.id == 254 || tray.id == 255 {
                let slot = tray.id - 254
                out.append(SlotTarget(amsId: 255, trayId: slot,
                                      title: external.count == 2 ? (slot == 0 ? "Ext-L" : "Ext-R") : "External spool",
                                      unitTitle: "External",
                                      colorHex: tray.isEmpty ? nil : tray.trayColor,
                                      filament: tray.isEmpty ? "Empty" : tray.label))
            }
        }
        return out
    }
}

private func assignMessage(_ result: AssignResult) -> String {
    if result.pendingConfig == true { return "Saved. The slot looked empty, so the printer is configured when filament is inserted." }
    if result.configured == true { return "The printer's slot was configured with this spool." }
    return "Assigned."
}

/// From a spool: pick a printer, then a slot, using the live AMS state in `FarmStore`.
struct AssignToSlotSheet: View {
    let spool: Spool
    @ObservedObject var store: InventoryStore
    let onDone: (String) -> Void

    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss

    private var printers: [Printer] {
        farm.activePrinters.filter { farm.statuses[$0.id]?.isConnected == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if printers.isEmpty {
                    Text("No connected printers with an AMS.").foregroundStyle(Color.textMuted)
                }
                ForEach(printers) { printer in
                    let targets = SlotTarget.targets(for: farm.statuses[printer.id])
                    if !targets.isEmpty {
                        NavigationLink {
                            SlotPicker(spool: spool, printer: printer, targets: targets, store: store) { message in
                                dismiss()
                                onDone(message)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                StateDot(state: farm.state(printer.id)).frame(width: 14)
                                Text(printer.name).font(.subheadline)
                                Text(printer.displayModel).font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                    }
                }
            }
            .farmBackground()
            .navigationTitle("Choose printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SlotPicker: View {
    let spool: Spool
    let printer: Printer
    let targets: [SlotTarget]
    @ObservedObject var store: InventoryStore
    let finished: (String) -> Void

    @State private var pending: SlotTarget?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(Dictionary(grouping: targets, by: \.unitTitle).keys.sorted(), id: \.self) { unit in
                Section(unit) {
                    ForEach(targets.filter { $0.unitTitle == unit }) { target in
                        let current = store.assignment(printerId: printer.id, amsId: target.amsId, trayId: target.trayId)
                        Button { pending = target } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(hexRGBA: target.colorHex) ?? Color.bgRaised)
                                    .frame(width: 28, height: 28)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.hairline, lineWidth: 0.75))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.title).foregroundStyle(.primary)
                                    Text(slotSubtitle(target, current)).font(.caption).foregroundStyle(Color.textMuted)
                                }
                                Spacer()
                                if current?.spoolId == spool.id { Image(systemName: "checkmark").foregroundStyle(Color.accentTeal) }
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(Color.statusError) }
        }
        .farmBackground()
        .navigationTitle(printer.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Assign \(spool.displayName) to \(pending?.title ?? "slot")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { target in
            Button("Assign") { assign(target) }
        } message: { target in
            Text(confirmText(target))
        }
    }

    private func slotSubtitle(_ target: SlotTarget, _ current: SlotAssignment?) -> String {
        if let current, let s = store.spool(for: current) { return "Assigned: \(s.displayName)" }
        if current != nil { return "Assigned: spool #\(current!.spoolId)" }
        return "On printer: \(target.filament)"
    }

    private func confirmText(_ target: SlotTarget) -> String {
        var parts: [String] = []
        if let current = store.assignment(printerId: printer.id, amsId: target.amsId, trayId: target.trayId), current.spoolId != spool.id {
            parts.append("It replaces the spool assigned there now.")
        }
        let elsewhere = store.slots(for: spool.id).filter { !($0.printerId == printer.id && $0.amsId == target.amsId && $0.trayId == target.trayId) }
        if !elsewhere.isEmpty { parts.append("It leaves \(elsewhere.map(\.fullName).joined(separator: ", ")).") }
        parts.append("Bambuddy also sends the spool's filament settings to the printer.")
        return parts.joined(separator: " ")
    }

    private func assign(_ target: SlotTarget) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let result = try await store.assign(spool.id, printerId: printer.id, amsId: target.amsId, trayId: target.trayId)
                InventoryHaptics.success()
                finished(assignMessage(result))
            } catch {
                InventoryHaptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// From a printer slot: pick which spool goes in it.
struct AssignSpoolSheet: View {
    let printerId: Int
    let amsId: Int
    let trayId: Int
    let slotTitle: String
    @ObservedObject var store: InventoryStore
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pending: Spool?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var loading = true

    private var choices: [Spool] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.spools.filter { !$0.isArchived }.filter { s in
            q.isEmpty || [s.brand, s.material, s.subtype, s.colorName].compactMap { $0 }.joined(separator: " ").lowercased().contains(q)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(Color.statusError) }
                ForEach(choices) { spool in
                    let slots = store.slots(for: spool.id)
                    Button { pending = spool } label: {
                        HStack(spacing: 12) {
                            SpoolSwatch(colors: spool.swatchColors, size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(spool.displayName).font(.subheadline).foregroundStyle(.primary)
                                Text([spool.colorName, "\(formatGrams(spool.remainingGrams)) left"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Color.textMuted)
                                if !slots.isEmpty {
                                    Text("In \(slots.map(\.fullName).joined(separator: ", "))").font(.caption).foregroundStyle(Color.statusWarning)
                                }
                            }
                        }
                    }
                    .disabled(busy)
                }
            }
            .farmBackground()
            .navigationTitle(slotTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Material, brand, color")
            .overlay {
                if loading, store.spools.isEmpty { ProgressView() }
                else if !loading, choices.isEmpty { ContentUnavailableView("No spools", systemImage: "cylinder.split.1x2") }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Assign \(pending?.displayName ?? "spool") to \(slotTitle)?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { spool in
                Button("Assign") { assign(spool) }
            } message: { spool in
                let elsewhere = store.slots(for: spool.id).filter { !($0.printerId == printerId && $0.amsId == amsId && $0.trayId == trayId) }
                Text((elsewhere.isEmpty ? "" : "It leaves \(elsewhere.map(\.fullName).joined(separator: ", ")). ") + "Bambuddy also sends the spool's filament settings to the printer.")
            }
            .task {
                if store.spools.isEmpty { await store.load() }
                loading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func assign(_ spool: Spool) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let result = try await store.assign(spool.id, printerId: printerId, amsId: amsId, trayId: trayId)
                InventoryHaptics.success()
                dismiss()
                onDone(assignMessage(result))
            } catch {
                InventoryHaptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}
