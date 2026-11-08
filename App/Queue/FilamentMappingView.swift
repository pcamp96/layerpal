import SwiftUI

/// "Filament" section of the add-to-queue sheet: what the plate needs and, for a specific
/// printer, which loaded tray feeds each slot (auto-matched, see FilamentMappingModel).
struct FilamentMappingSection: View {
    @ObservedObject var model: FilamentMappingModel
    let target: QueueTarget

    private var mapsToPrinter: Bool { target.printerId != nil }

    var body: some View {
        if model.loadingNeeds, model.needs.isEmpty {
            Section("Filament") {
                HStack(spacing: 8) { ProgressView(); Text("Reading filament needs…").foregroundStyle(Color.textMuted) }
            }
        } else if let error = model.needsError {
            Section("Filament") { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
        } else if !model.needs.isEmpty {
            Section {
                if mapsToPrinter {
                    ForEach(model.comparison) { row in mappingRow(row) }
                } else {
                    ForEach(model.needs) { need in needRow(need) }
                }
            } header: {
                Text("Filament")
            } footer: {
                footer
            }
        }
    }

    // MARK: Rows

    private func swatch(_ hex: String?, size: CGFloat = 22) -> some View {
        Circle()
            .fill(Color(hexRGBA: MappingColor.normalize(hex)) ?? Color.bgRaised)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.hairline, lineWidth: 0.75))
            .accessibilityHidden(true)
    }

    private func needTitle(_ need: FilamentNeed) -> String {
        var text = need.materialName
        if let g = need.usedGrams, g > 0 { text += " · \(formatGrams(g))" }
        return text
    }

    private func needRow(_ need: FilamentNeed) -> some View {
        HStack(spacing: 10) {
            swatch(need.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(needTitle(need)).font(.subheadline)
                Text("Slot \(need.slotId)").font(.caption).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func mappingRow(_ row: SlotComparison) -> some View {
        HStack(alignment: .center, spacing: 10) {
            swatch(row.need.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(needTitle(row.need)).font(.subheadline)
                HStack(spacing: 8) {
                    Text("Slot \(row.need.slotId)").font(.caption).foregroundStyle(Color.textMuted)
                    rackPicker(row.need)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button { model.manual[row.need.slotId] = nil } label: {
                    Label("Automatic", systemImage: !row.manual ? "checkmark" : "wand.and.stars")
                }
                ForEach(model.trays) { tray in
                    Button { model.manual[row.need.slotId] = tray.globalId } label: {
                        let picked = row.manual && row.tray?.globalId == tray.globalId
                        Label("\(tray.label): \(tray.displayName)", systemImage: picked ? "checkmark" : "circle")
                    }
                }
                Button { model.manual[row.need.slotId] = -1 } label: {
                    Label("Don't map this slot", systemImage: row.match == .unassigned ? "checkmark" : "nosign")
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.tray?.label ?? (row.match == .unassigned ? "Not mapped" : "Nothing loaded"))
                            .font(.caption.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.trailing)
                        statusText(row)
                    }
                    if let tray = row.tray { swatch(tray.color, size: 18) }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Color.textMuted)
                }
            }
            .disabled(model.trays.isEmpty && !model.loadingPrinter)
            .accessibilityLabel("Tray for slot \(row.need.slotId), \(row.need.materialName)")
            .accessibilityValue(accessibilityStatus(row))
        }
    }

    /// H2C: which of the six rack positions this slot's filament group prints from. Positions that are empty or
    /// hold the wrong nozzle are greyed out. Groups on the fixed carriage have no choice to make.
    @ViewBuilder private func rackPicker(_ need: FilamentNeed) -> some View {
        if model.hasRack, let groupId = need.groupId, let group = need.group {
            if group.onRack {
                let chosen = model.effectiveRackChoice[groupId]
                Menu {
                    ForEach(NozzleRack.options(model.rackSlots, for: group)) { option in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            model.pickRack(group: groupId, position: option.position)
                        } label: {
                            Label(option.eligible ? option.title : "\(option.title) (\(option.reason ?? "unavailable"))",
                                  systemImage: chosen == option.position ? "checkmark" : "circle")
                        }
                        .disabled(!option.eligible)
                    }
                    if !model.rackChoice.isEmpty {
                        Divider()
                        Button { model.resetRack() } label: { Label("Let the printer assign", systemImage: "wand.and.stars") }
                    }
                } label: {
                    Label(chosen.map { "R\($0)" } ?? "Rack", systemImage: "square.grid.3x2")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.bgRaised, in: Capsule())
                        .foregroundStyle(chosen == nil ? Color.statusWarning : Color.primary)
                }
                .accessibilityLabel("Nozzle rack position for slot \(need.slotId)")
                .accessibilityValue(chosen.map { "Position \($0)" } ?? "Not set")
            } else {
                Text("Fixed nozzle").font(.caption2).foregroundStyle(Color.textMuted)
            }
        }
    }

    @ViewBuilder private func statusText(_ row: SlotComparison) -> some View {
        switch row.match {
        case .match:
            Label(row.manual ? "Chosen" : "Matches", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal)
        case .colorDiffers:
            Label("Colour differs", systemImage: "exclamationmark.circle.fill").foregroundStyle(Color.statusWarning)
        case .mismatch:
            Label(row.tray == nil ? "No \(row.need.materialName) loaded" : "Different material", systemImage: "xmark.octagon.fill")
                .foregroundStyle(Color.statusError)
        case .unassigned:
            Label("Skipped", systemImage: "minus.circle.fill").foregroundStyle(Color.statusWarning)
        }
    }

    private func accessibilityStatus(_ row: SlotComparison) -> String {
        let tray = row.tray?.label ?? "none"
        switch row.match {
        case .match: return "\(tray), matches"
        case .colorDiffers: return "\(tray), colour differs"
        case .mismatch: return row.tray == nil ? "no matching material loaded" : "\(tray), different material"
        case .unassigned: return "not mapped"
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !mapsToPrinter {
                Text(target.targetModel != nil
                    ? "For \"any printer\" jobs the scheduler picks a printer and maps these filaments itself when it starts the print."
                    : "Pick a printer to map these filaments to its AMS.")
            } else if model.loadingPrinter {
                Text("Reading the printer's loaded filament…")
            } else if model.trays.isEmpty, model.printerNote == nil {
                Text("No filament is loaded on this printer (or it is offline). The scheduler will map trays when the job starts.")
            }
            if mapsToPrinter, let note = model.printerNote { Text(note) }
            if mapsToPrinter, model.substitutesMaterial {
                Text("A slot is mapped to a different material. It will print that way, so the filament check is skipped.")
                    .foregroundStyle(Color.statusWarning)
            }
            if mapsToPrinter, model.preferLowest, !model.trays.isEmpty {
                Text("Automatic picks use the spool with the least filament left when several match (a Bambuddy setting).")
            }
            if mapsToPrinter, model.hasRack {
                Text("Rack positions that are empty or hold another nozzle size can't be chosen. Bambuddy re-checks the rack when the print starts.")
            }
            if mapsToPrinter, !model.deficits.isEmpty {
                ForEach(model.deficits) { deficit in
                    Label(deficit.text, systemImage: "scalemass.fill").foregroundStyle(Color.statusWarning)
                }
                Text("These spools may run out before the job finishes.").foregroundStyle(Color.statusWarning)
            }
        }
    }
}
