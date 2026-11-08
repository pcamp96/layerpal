import SwiftUI

/// Nozzle hardware (diameter, material, flow, wear), the active extruder on dual-nozzle
/// printers, and the tool-changer rack on H2C / H3C.
///
/// Read-only except "Select extruder" (`POST /printers/{id}/select-extruder`, printers:control).
/// Bambuddy 1.3.0 has no rack command at all, and the H3C 9-nozzle layout is unverified on
/// hardware, so nothing here ever sends anything to a rack or to an H3C.
struct NozzlesSheet: View {
    let printerId: Int
    let model: String?
    let canSelect: Bool
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    private var status: PrinterStatus? { farm.statuses[printerId] }
    private var isDual: Bool { status?.temperature("nozzle_2") != nil }
    private var slots: [AdvRackSlot] { status?.nozzleRack ?? [] }
    private var isRack: Bool { AdvModels.isRack(model) }
    private var unverified: Bool { AdvModels.isToolChangerUnverified(model) }
    private var rackSlots: [AdvRackSlot] { slots.filter { $0.id >= 2 }.sorted { $0.id < $1.id } }
    /// 0 = right, 1 = left.
    private var activeExtruder: Int { status?.activeExtruder == 1 ? 1 : 0 }
    private var canSwitch: Bool { canSelect && isDual && !unverified && status?.isPrinting != true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isDual { dualBlock } else { singleBlock }
                    if isRack || !rackSlots.isEmpty { rackBlock }
                    if unverified {
                        InfoRow(symbol: "info.circle", text: "H3C tool changer support is read-only: Bambuddy hasn't verified its nozzle layout on hardware, so no nozzle commands are sent.")
                    }
                }
                .padding()
            }
            .background(Color.bgPrimary)
            .navigationTitle("Nozzles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .alert("Couldn't do that", isPresented: .constant(error != nil), presenting: error) { _ in
            Button("OK") { error = nil }
        } message: { Text($0) }
    }

    // MARK: Single nozzle

    @ViewBuilder private var singleBlock: some View {
        let slot = slots.first { $0.id == 0 }
        let info = status?.nozzles?.first
        let type = slot?.nozzleType ?? info?.nozzleType
        let diameter = slot?.nozzleDiameter ?? info?.nozzleDiameter
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Nozzle")
            Card {
                detailRows(diameter: diameter, type: type, wear: slot?.wear, maxTemp: slot?.maxTemp, serial: slot?.serialNumber)
            }
        }
    }

    // MARK: Dual nozzle

    private var dualBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Active nozzle")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ForEach([(1, "Left"), (0, "Right")], id: \.0) { extruder, label in
                                Button { select(extruder) } label: {
                                    HStack(spacing: 6) {
                                        if activeExtruder == extruder { Image(systemName: "checkmark.circle.fill") }
                                        Text(label)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                }
                                .buttonStyle(.bordered)
                                .tint(activeExtruder == extruder ? .accentTeal : .textSecondary)
                                .disabled(!canSwitch || busy || activeExtruder == extruder)
                                .accessibilityLabel("\(label) nozzle\(activeExtruder == extruder ? ", active" : "")")
                            }
                        }
                        if status?.isPrinting == true, canSelect {
                            Text("Nozzle selection is disabled while printing.").font(.caption).foregroundStyle(Color.textMuted)
                        } else if !canSelect {
                            Text("Read-only: you can't control this printer.").font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                }
            }
            hotendCard("Left nozzle", slot: slots.first { $0.id == 1 }, active: activeExtruder == 1)
            hotendCard("Right nozzle", slot: slots.first { $0.id == 0 }, active: activeExtruder == 0)
        }
    }

    private func hotendCard(_ title: String, slot: AdvRackSlot?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, trailing: active ? "Active" : nil)
            Card {
                if let slot {
                    detailRows(diameter: slot.nozzleDiameter, type: slot.nozzleType, wear: slot.wear, maxTemp: slot.maxTemp, serial: slot.serialNumber)
                } else {
                    Text("No details reported.").font(.footnote).foregroundStyle(Color.textMuted)
                }
            }
        }
    }

    // MARK: Rack

    private var rackBlock: some View {
        let positions: [(label: String, slot: AdvRackSlot?)] = isRack
            // H2C rack IDs are fixed 16...21; a nozzle in the hotend is absent from the rack list.
            ? (0 ..< 6).map { i in ("\(i + 1)", rackSlots.first { $0.id == 16 + i }) }
            : rackSlots.map { ("\($0.id)", $0) }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Nozzle rack", trailing: "Read-only")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(positions.enumerated()), id: \.offset) { index, item in
                        rackRow(item.label, item.slot)
                        if index < positions.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
            }
        }
    }

    private func rackRow(_ label: String, _ slot: AdvRackSlot?) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted).frame(width: 18)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(slot.flatMap { $0.isEmpty ? nil : Color(hexRGBA: $0.filamentColor) } ?? Color.bgRaised)
                    .frame(width: 36, height: 28)
                Text(slot.flatMap { $0.isEmpty ? nil : $0.nozzleDiameter } ?? "–")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(slot.flatMap { Color(hexRGBA: $0.filamentColor) } == nil ? Color.textSecondary : Color.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.hairline, lineWidth: 0.75))
            VStack(alignment: .leading, spacing: 2) {
                if let slot, !slot.isEmpty {
                    Text([AdvNozzleText.material(slot.nozzleType), AdvNozzleText.flow(slot.nozzleType)]
                        .compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                    HStack(spacing: 8) {
                        Text(slot.isMounted ? "Mounted" : "Docked")
                        if let wear = slot.wear { Text("Wear \(wear)%") }
                        if let type = slot.filamentType, !type.isEmpty { Text(type) }
                    }
                    .font(.caption).foregroundStyle(Color.textMuted)
                } else {
                    Text("Empty").font(.subheadline).foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rack position \(label)")
    }

    // MARK: Pieces

    private func detailRows(diameter: String?, type: String?, wear: Int?, maxTemp: Int?, serial: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Diameter", (diameter?.isEmpty == false) ? "\(diameter!) mm" : nil)
            row("Type", AdvNozzleText.material(type))
            row("Flow", AdvNozzleText.flow(type))
            row("Wear", wear.map { "\($0)%" })
            row("Max temp", (maxTemp ?? 0) > 0 ? "\(maxTemp!)°C" : nil)
            row("Serial", (serial?.isEmpty == false) ? serial : nil)
            if diameter == nil && type == nil { Text("No details reported.").font(.footnote).foregroundStyle(Color.textMuted) }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(Color.textMuted)
                Spacer()
                Text(value).font(.subheadline.weight(.medium).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func select(_ extruder: Int) {
        guard canSwitch, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.selectExtruder(printerId, extruder: extruder)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
