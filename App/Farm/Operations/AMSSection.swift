import SwiftUI

/// Tray id encoding used by the load/unload/tray_now fields:
/// 0-15 = unit * 4 + slot, AMS-HT = its unit id (128-135), rack AMS = 28+slot (AMS-3H) / 37+slot (AMS-B),
/// external = 254/255 (247-255 per nozzle on the H3C).
extension AMSUnit {
    var isHT: Bool { isAmsHt == true || id >= 128 }
    var rack: Bool { isRack == true || amsType == 6 || amsType == 7 }
    func globalTrayId(_ tray: AMSTray) -> Int {
        if rack { return (amsType == 7 ? 37 : 28) + tray.id }
        return isHT ? id : id * 4 + tray.id
    }
    var displayName: String {
        if rack { return amsTypeName?.isEmpty == false ? amsTypeName! : (amsType == 7 ? "AMS-B" : "AMS-3H") }
        return SlotNaming.unit(id)
    }
    var isDrying: Bool { (dryTime ?? 0) > 0 }
}

/// AMS and external-spool cards. Tap a tray for load / unload / RFID re-read;
/// drying controls sit in each unit's header.
struct AMSSection: View {
    let printerId: Int
    let status: PrinterStatus
    let controllable: Bool
    let canRFID: Bool
    let run: OpsRun

    private struct TrayChoice: Identifiable {
        let title: String
        let trayId: Int
        let amsId: Int
        let slotId: Int
        let isExternal: Bool
        var isRack = false
        var canLoad = true
        var canUnload = true
        /// Tray index for spool assignment: slot in the unit, or 0/1 for the external holders (254/255).
        var assignTray: Int { isExternal ? max(0, trayId - 254) : slotId }
        var id: Int { trayId }
    }

    private enum Dialog: Identifiable {
        case tray(TrayChoice)
        case feed(TrayChoice)
        var id: String {
            switch self {
            case let .tray(c): "tray\(c.trayId)"
            case let .feed(c): "feed\(c.trayId)"
            }
        }
    }

    @EnvironmentObject private var farm: FarmStore
    @StateObject private var inventory = InventoryStore()
    @State private var dialog: Dialog?
    @State private var dryingUnit: AMSUnit?
    @State private var scheduleUnit: AMSUnit?
    @State private var scheduleRefresh = 0
    @State private var notice: String?
    @State private var assignTarget: TrayChoice?
    @State private var assignNotice: String?
    @State private var unassignTarget: SlotAssignment?
    @State private var configureTarget: TrayChoice?
    @State private var resetTarget: TrayChoice?
    @State private var configureNotice: String?

    private var printing: Bool { (status.state ?? "").uppercased() == "RUNNING" }
    private var canTapTrays: Bool { controllable && !printing }
    /// Spool assignment is an inventory write (inventory:update), not printer control.
    private var canAssign: Bool { farm.can("inventory:update") }

    private func assignment(amsId: Int, trayId: Int) -> SlotAssignment? {
        inventory.assignment(printerId: printerId, amsId: amsId, trayId: trayId)
    }

    /// Short name of the spool assigned to a slot, when known.
    private func assignedName(amsId: Int, trayId: Int) -> String? {
        guard let a = assignment(amsId: amsId, trayId: trayId) else { return nil }
        guard let spool = inventory.spool(for: a) else { return "Spool #\(a.spoolId)" }
        if let color = spool.colorName, !color.isEmpty { return color }
        return spool.displayName
    }

    var body: some View {
        let units = status.ams ?? []
        let external = status.vtTray ?? []
        if !units.isEmpty || !external.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Filament", trailing: printing && controllable ? "Load and unload paused while printing" : nil)
                ForEach(units) { unit in unitCard(unit) }
                if farm.can("printers:read") { ScheduledDryingsSection(printerId: printerId, canCancel: controllable, refresh: scheduleRefresh) }
                if !external.isEmpty {
                    // Per-nozzle inputs (H3C) read in nozzle order; classic Ext-L/Ext-R by id.
                    externalCard(external.sorted { ($0.nozzleAddr ?? $0.id, $0.id) < ($1.nozzleAddr ?? $1.id, $1.id) })
                }
            }
            .confirmationDialog(dialogTitle, isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }),
                                titleVisibility: .visible, presenting: dialog) { item in
                switch item {
                case let .tray(choice):
                    if canTapTrays {
                        if choice.canLoad { Button("Load filament") { startLoad(choice) } }
                        if choice.canUnload {
                            Button("Unload filament") { run { try await APIClient.shared.amsUnload(printerId, trayId: choice.trayId) } }
                        }
                        Button("Configure slot…") { configureTarget = choice }
                        Button("Reset slot", role: .destructive) { resetTarget = choice }
                        if canRFID, !choice.isExternal, !choice.isRack {
                            Button("Re-read RFID tag") {
                                run { try await APIClient.shared.refreshAmsSlot(printerId, amsId: choice.amsId, slotId: choice.slotId) }
                            }
                        }
                    }
                    if canAssign {
                        Button("Assign spool…") { assignTarget = choice }
                        if let current = assignment(amsId: choice.amsId, trayId: choice.assignTray) {
                            Button("Unassign spool", role: .destructive) { unassignTarget = current }
                        }
                    }
                case let .feed(choice):
                    Button("Right nozzle") { run { try await APIClient.shared.amsLoad(printerId, trayId: choice.trayId, extruderId: 0) } }
                    Button("Left nozzle") { run { try await APIClient.shared.amsLoad(printerId, trayId: choice.trayId, extruderId: 1) } }
                }
            } message: { item in
                switch item {
                case let .tray(choice):
                    if let name = assignedName(amsId: choice.amsId, trayId: choice.assignTray) {
                        Text("Assigned spool: \(name). " + (canTapTrays ? "Loading heats the nozzle and moves filament." : ""))
                    } else {
                        Text(canTapTrays ? "The printer heats the nozzle and moves filament." : "Loading is paused while printing.")
                    }
                case .feed: Text("A filament track switch is fitted. Choose which nozzle to feed.")
                }
            }
            .alert("Can't load yet", isPresented: .constant(notice != nil), presenting: notice) { _ in
                Button("OK") { notice = nil }
            } message: { Text($0) }
            .task(id: farm.permissions) {
                if farm.can("inventory:view_assignments") { await inventory.loadAssignments() }
            }
            .sheet(item: $assignTarget) { choice in
                AssignSpoolSheet(printerId: printerId, amsId: choice.amsId, trayId: choice.assignTray, slotTitle: choice.title, store: inventory) { assignNotice = $0 }
            }
            .alert("Spool assigned", isPresented: Binding(get: { assignNotice != nil }, set: { if !$0 { assignNotice = nil } }), presenting: assignNotice) { _ in
                Button("OK") { assignNotice = nil }
            } message: { Text($0) }
            .confirmationDialog("Unassign \(unassignTarget.flatMap { inventory.spool(for: $0)?.displayName } ?? "spool")?",
                                isPresented: Binding(get: { unassignTarget != nil }, set: { if !$0 { unassignTarget = nil } }),
                                titleVisibility: .visible, presenting: unassignTarget) { target in
                Button("Unassign", role: .destructive) { run { try await inventory.unassign(target) } }
            } message: { target in
                Text("It leaves \(target.slotName). The printer keeps its current filament settings.")
            }
            .sheet(item: $configureTarget) { choice in
                ConfigureSlotSheet(printerId: printerId, amsId: choice.amsId, trayId: choice.assignTray, title: choice.title,
                                   current: currentTray(choice)) { configureNotice = $0 }
            }
            .alert("Slot configured", isPresented: Binding(get: { configureNotice != nil }, set: { if !$0 { configureNotice = nil } }), presenting: configureNotice) { _ in
                Button("OK") { configureNotice = nil }
            } message: { Text($0) }
            .confirmationDialog("Reset \(resetTarget?.title ?? "slot")?", isPresented: Binding(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }),
                                titleVisibility: .visible, presenting: resetTarget) { target in
                Button("Reset slot", role: .destructive) {
                    run { try await APIClient.shared.resetSlot(printerId: printerId, amsId: target.amsId, trayId: target.assignTray) }
                }
            } message: { _ in
                Text("The printer forgets this slot's filament type, colour and K-profile. The spool itself stays where it is.")
            }
            .sheet(item: $scheduleUnit) { unit in
                ScheduleDryingSheet(unit: unit, printerId: printerId,
                                    anyLoaded: (unit.tray ?? []).contains { status.trayNow == unit.globalTrayId($0) }) { scheduleRefresh += 1 }
                    .presentationDetents([.large])
            }
            .sheet(item: $dryingUnit) { unit in
                DryingSheet(unit: unit, printerId: printerId, anyLoaded: (unit.tray ?? []).contains { status.trayNow == unit.globalTrayId($0) }, run: run)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func currentTray(_ choice: TrayChoice) -> AMSTray? {
        if choice.isExternal { return (status.vtTray ?? []).first { $0.id == choice.trayId } }
        return status.ams?.first { $0.id == choice.amsId }?.tray?.first { $0.id == choice.slotId }
    }

    private var dialogTitle: String {
        switch dialog {
        case let .tray(c): c.title
        case let .feed(c): "Load \(c.title)"
        case nil: ""
        }
    }

    // MARK: Cards

    private func unitCard(_ unit: AMSUnit) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(unit.displayName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let h = unit.humidity { Label("\(h)%", systemImage: "humidity").font(.caption).foregroundStyle(Color.textMuted) }
                    dryButton(unit)
                    scheduleButton(unit)
                }
                // Wraps instead of stretching: some printers (H3C) report 9-slot units.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], alignment: .leading, spacing: 10) {
                    ForEach(unit.tray ?? []) { tray in
                        let gid = unit.globalTrayId(tray)
                        Button {
                            dialog = .tray(TrayChoice(title: unit.isHT ? unit.displayName : "\(unit.displayName) slot \(tray.id + 1)",
                                                      trayId: gid, amsId: unit.id, slotId: tray.id, isExternal: false,
                                                      isRack: unit.rack,
                                                      canLoad: unit.canAutoFeed ?? (unit.amsType != 7),
                                                      canUnload: unit.canAutoRetract ?? !unit.rack))
                        } label: {
                            VStack(spacing: 2) {
                                TraySwatch(tray: tray, active: status.trayNow == gid)
                                if unit.rack {
                                    Text("Nozzle \((tray.nozzleAddr ?? tray.id) + 1)").font(.caption2).foregroundStyle(Color.textMuted)
                                }
                                assignedCaption(amsId: unit.id, trayId: tray.id)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!(canTapTrays || canAssign))
                        .accessibilityHint(canTapTrays || canAssign ? "Opens slot actions" : "")
                    }
                }
                if unit.isDrying { dryingBanner(unit) }
            }
        }
    }

    @ViewBuilder private func externalCard(_ trays: [AMSTray]) -> some View {
        // Rack printers (H3C) report an input per nozzle even with nothing plugged in.
        if trays.count > 2, trays.allSatisfy({ $0.isEmpty && status.trayNow != $0.id }) {
            Card(padding: 12) {
                HStack {
                    Text("External inputs").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("None loaded").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
        } else {
            externalGrid(trays)
        }
    }

    private func externalGrid(_ trays: [AMSTray]) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(trays.count > 2 ? "External inputs" : "External").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], alignment: .leading, spacing: 10) {
                ForEach(Array(trays.enumerated()), id: \.element.id) { index, tray in
                    let name = trays.count > 2 ? (tray.nozzleAddr.map { "Ext \($0 + 1)" } ?? "\(index + 1)") : (trays.count == 2 ? (tray.id == 254 ? "Ext-L" : "Ext-R") : "External spool")
                    Button {
                        dialog = .tray(TrayChoice(title: name, trayId: tray.id, amsId: 255, slotId: 0, isExternal: true))
                    } label: {
                        VStack(spacing: 2) {
                            TraySwatch(tray: tray, active: status.trayNow == tray.id)
                            if trays.count > 1 { Text(name).font(.caption2).foregroundStyle(Color.textMuted) }
                            assignedCaption(amsId: 255, trayId: max(0, tray.id - 254))
                        }
                    }
                    .buttonStyle(.plain)
                    // Only the classic one/two external spools have a verified tray id mapping.
                    .disabled(!(canTapTrays || canAssign) || trays.count > 2)
                }
                }
            }
        }
    }

    /// Name of the Bambuddy spool assigned to this slot, shown under the swatch.
    @ViewBuilder private func assignedCaption(amsId: Int, trayId: Int) -> some View {
        if let name = assignedName(amsId: amsId, trayId: trayId) {
            Text(name).font(.caption2).foregroundStyle(Color.accentTeal)
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel("Assigned spool \(name)")
        }
    }

    private func unitLetter(_ id: Int) -> String {
        guard id >= 0, id < 26, let scalar = UnicodeScalar(65 + id) else { return "#\(id)" }
        return String(Character(scalar))
    }

    private func startLoad(_ choice: TrayChoice) {
        if status.filaSwitch?.installed == true, !choice.isExternal, !choice.isRack {
            if status.filaSwitch?.ready != true {
                notice = "Assign every AMS to a switch inlet on the printer (Manual AMS Setup), then try again."
                return
            }
            dialog = .feed(choice)
        } else {
            run { try await APIClient.shared.amsLoad(printerId, trayId: choice.trayId) }
        }
    }

    // MARK: Drying

    private static let dryerModules: Set<String> = ["n3f", "n3s"]

    @ViewBuilder private func dryButton(_ unit: AMSUnit) -> some View {
        let dryer = Self.dryerModules.contains(unit.moduleType ?? "")
        let supported = status.supportsDrying == true || status.dryingScreenOnly == true
        if controllable, dryer, supported {
            if status.dryingScreenOnly == true {
                Label("Dry on printer", systemImage: "flame").font(.caption).foregroundStyle(Color.textMuted)
            } else if unit.isDrying {
                Button { run { try await APIClient.shared.stopDrying(printerId, amsId: unit.id) } } label: {
                    Label("Stop drying", systemImage: "stop.circle").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).tint(.statusWarning).controlSize(.small)
            } else if !(unit.drySfReason ?? []).isEmpty {
                Label(Self.blockedMessage(unit.drySfReason ?? []), systemImage: "flame").font(.caption).foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.trailing)
            } else if !printing || status.supportsDryingWhilePrinting == true {
                Button { dryingUnit = unit } label: {
                    Label("Dry", systemImage: "flame").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).tint(.accentTeal).controlSize(.small)
            }
        }
    }

    /// "Schedule drying…": a delayed or timed run the server starts later (POST /scheduled-dryings, printers:control).
    /// Shown only for a drying-capable AMS when the status says drying is supported and the printer isn't screen-only for drying.
    @ViewBuilder private func scheduleButton(_ unit: AMSUnit) -> some View {
        if controllable, Self.dryerModules.contains(unit.moduleType ?? ""), status.supportsDrying == true, status.dryingScreenOnly != true {
            Button { scheduleUnit = unit } label: {
                Image(systemName: "calendar.badge.clock").font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered).tint(.accentTeal).controlSize(.small)
            .accessibilityLabel("Schedule drying")
        }
    }

    private func dryingBanner(_ unit: AMSUnit) -> some View {
        let stalled = unit.dryCountdownStalled == true
        let minutes = unit.dryTime ?? 0
        var parts: [String] = []
        if let f = unit.dryFilament, !f.isEmpty { parts.append(f) }
        if let t = unit.dryTargetTemp { parts.append("\(t)°") }
        parts.append("\(formatMinutes(minutes)) left")
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(stalled ? "Drying not running" : "Drying").font(.caption.weight(.semibold))
                Text(parts.joined(separator: " · ")).font(.caption)
            }
        } icon: {
            Image(systemName: stalled ? "hourglass" : "flame.fill")
        }
        .foregroundStyle(stalled ? Color.textSecondary : Color.statusWarning)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((stalled ? Color.bgRaised : Color.statusWarning.opacity(0.12)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Firmware `dry_sf_reason` codes: 1 and 8 need the AMS power adapter, 3 means filament is still at the outlet,
    /// anything else is a temporary block. The server ranks them the same way for a scheduled drying's waiting reason.
    static func blockedMessage(_ codes: [Int]) -> String {
        if codes.contains(where: { $0 == 1 || $0 == 8 }) { return "Needs external power" }
        if codes.contains(3) { return "Retract filament first" }
        return "Can't dry now"
    }
}

/// Start-drying sheet with per-material drying presets.
struct DryingSheet: View {
    let unit: AMSUnit
    let printerId: Int
    let anyLoaded: Bool
    let run: OpsRun
    @Environment(\.dismiss) private var dismiss

    struct Preset { let n3f: Int; let n3s: Int; let n3fHours: Int; let n3sHours: Int }

    /// Material -> drying preset (AMS 2 Pro `n3f` and AMS HT `n3s` temperature and hours). Numbers match
    /// the AMS drying values in BambuStudio's filament profiles, which the server's auto-drying also uses.
    static let presets: [(String, Preset)] = [
        ("PLA", Preset(n3f: 45, n3s: 45, n3fHours: 12, n3sHours: 12)),
        ("PETG", Preset(n3f: 65, n3s: 65, n3fHours: 12, n3sHours: 12)),
        ("TPU", Preset(n3f: 65, n3s: 75, n3fHours: 12, n3sHours: 18)),
        ("ABS", Preset(n3f: 65, n3s: 80, n3fHours: 12, n3sHours: 8)),
        ("ASA", Preset(n3f: 65, n3s: 80, n3fHours: 12, n3sHours: 8)),
        ("PA", Preset(n3f: 65, n3s: 85, n3fHours: 12, n3sHours: 12)),
        ("PC", Preset(n3f: 65, n3s: 80, n3fHours: 12, n3sHours: 8)),
        ("PVA", Preset(n3f: 65, n3s: 85, n3fHours: 12, n3sHours: 18)),
    ]

    /// Nylon names that dry as PA.
    static let aliases: [String: String] = [
        "NYLON": "PA", "PA6": "PA", "PA11": "PA", "PA12": "PA", "PAHT": "PA", "PPA": "PA",
    ]

    @State private var filament = "PLA"
    @State private var temp = 45
    @State private var hours = 12
    @State private var rotate = false
    @State private var confirm = false

    private var isHT: Bool { unit.moduleType == "n3s" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament") {
                    Picker("Material", selection: $filament) {
                        ForEach(Self.presets, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    .onChange(of: filament) { _, new in apply(new) }
                }
                Section("Settings") {
                    Stepper(value: $temp, in: 45 ... 85, step: 5) {
                        LabeledContent("Temperature", value: "\(temp)°C")
                    }
                    Stepper(value: $hours, in: 1 ... 24) {
                        LabeledContent("Duration", value: "\(hours) h")
                    }
                }
                if !anyLoaded {
                    Section {
                        Toggle("Rotate spool during drying", isOn: $rotate)
                    }
                }
                Section {
                    Button {
                        confirm = true
                    } label: {
                        HStack { Spacer(); Label("Start drying", systemImage: "flame.fill").fontWeight(.semibold); Spacer() }
                    }
                    .confirmationDialog("Start drying \(filament)?", isPresented: $confirm, titleVisibility: .visible) {
                        Button("Start at \(temp)°C for \(hours) h") {
                            let ams = unit.id, t = temp, h = hours, f = filament, r = rotate && !anyLoaded
                            run { try await APIClient.shared.startDrying(printerId, amsId: ams, temp: t, hours: h, filament: f, rotateTray: r) }
                            dismiss()
                        }
                    } message: {
                        Text("The AMS heats its spools until the timer ends.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgPrimary)
            .navigationTitle(unit.isHT ? "Dry AMS HT" : "Dry AMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear(perform: seed)
        }
    }

    private func seed() {
        let first = (unit.tray ?? []).first { !$0.isEmpty }?.trayType ?? ""
        apply(Self.resolve(first))
        filament = Self.resolve(first)
    }

    /// Material on the tray -> preset key. Variants dry as their base ("PETG-CF" -> PETG); anything
    /// unknown gets PLA, the coolest preset, so it is never overheated.
    static func resolve(_ type: String) -> String {
        func lookup(_ key: String) -> String? {
            if presets.contains(where: { $0.0 == key }) { return key }
            return aliases[key]
        }
        let key = type.trimmingCharacters(in: .whitespaces).uppercased()
        if let hit = lookup(key) { return hit }
        if let base = key.split(separator: "-").first.map(String.init), let hit = lookup(base) { return hit }
        return "PLA"
    }

    private func apply(_ key: String) {
        guard let preset = Self.presets.first(where: { $0.0 == key })?.1 else { return }
        temp = isHT ? preset.n3s : preset.n3f
        hours = isHT ? preset.n3sHours : preset.n3fHours
    }
}


extension AMSUnit {
    /// Units with a known slot layout: classic AMS (4 slots), AMS HT (1 slot), and rack AMS (9 slots, Bambuddy 1.3+).
    var hasStandardSlots: Bool { isAmsHt == true || rack || (tray?.count ?? 0) <= 4 }
}
