import SwiftUI

/// Home Assistant sensors (Bambuddy: Settings > Network > Home Assistant, and the printer / storage-location
/// sensor dialogs). Binds HA entities (door contacts, temperature, humidity...) to printers or storage
/// locations, with live readings. The HA address and token are edited under "Connection" (settings:update). Reads need
/// `smart_plugs:read`; add and remove need `smart_plugs:create` / `smart_plugs:delete`.
struct HomeAssistantSensorsView: View {
    var body: some View {
        SessionGate(title: "Home Assistant", permission: "smart_plugs:read") { SensorsContent() }
    }
}

private enum SensorScope: String, CaseIterable, Identifiable {
    case printer = "Printers", location = "Storage"
    var id: String { rawValue }
}

private struct SensorRow: Identifiable {
    let id: Int
    let name: String
    let entityId: String
    let kind: String
    let alertText: String?
    let notifies: Bool
    let blocksPrint: Bool
    let reading: SetupHAReading?
}

private struct SensorGroup: Identifiable {
    let id: Int
    let title: String
    let rows: [SensorRow]
}

private struct SensorsContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var scope = SensorScope.printer
    @State private var printers: [Printer] = []
    @State private var locations: [SetupStorageLocation] = []
    @State private var printerSensors: [SetupHASensor] = []
    @State private var locationSensors: [SetupHALocSensor] = []
    @State private var readings: [String: SetupHAReading] = [:] // "p<id>" / "l<id>" -> reading
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false
    @State private var pendingDelete: (scope: SensorScope, id: Int, name: String)?

    private var groups: [SensorGroup] {
        switch scope {
        case .printer:
            printers.compactMap { printer in
                let rows = printerSensors.filter { $0.printerId == printer.id }.map { s in
                    SensorRow(id: s.id, name: s.name, entityId: s.entityId, kind: s.kind, alertText: alertText(s.alertState, s.alertAbove, s.alertBelow),
                              notifies: s.notifyOnAlert == true, blocksPrint: s.blockPrint == true, reading: readings["p\(s.id)"])
                }
                return rows.isEmpty ? nil : SensorGroup(id: printer.id, title: printer.name, rows: rows)
            }
        case .location:
            locations.compactMap { location in
                let rows = locationSensors.filter { $0.locationId == location.id }.map { s in
                    SensorRow(id: s.id, name: s.name, entityId: s.entityId, kind: s.kind, alertText: alertText(s.alertState, s.alertAbove, s.alertBelow),
                              notifies: s.notifyOnAlert == true, blocksPrint: false, reading: readings["l\(s.id)"])
                }
                return rows.isEmpty ? nil : SensorGroup(id: location.id, title: location.name, rows: rows)
            }
        }
    }

    var body: some View {
        List {
            if session.can("settings:read") {
                Section {
                    NavigationLink { HAConnectionView() } label: {
                        IconLabel(title: "Home Assistant connection", symbol: "link", tint: .cyan)
                    }
                } footer: { Text("The address and long-lived access token Bambuddy uses to reach Home Assistant.") }
            }
            Section {
                Picker("Bound to", selection: $scope) { ForEach(SensorScope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
            }
            if let error { Section { InlineError(message: error) } }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        sensorRow(row)
                            .swipeActions(edge: .trailing) {
                                if session.can("smart_plugs:delete") {
                                    Button(role: .destructive) { pendingDelete = (scope, row.id, row.name) } label: { Label("Remove", systemImage: "trash") }
                                }
                            }
                    }
                }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, groups.isEmpty, error == nil {
                ContentUnavailableView("No sensors", systemImage: "sensor",
                                       description: Text(scope == .printer ? "Bind a Home Assistant entity to a printer with +." : "Bind a Home Assistant entity to a storage location with +."))
                .padding(.top, 80)
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            if session.can("smart_plugs:create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add sensor")
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddSensorSheet(scope: scope, printers: printers, locations: locations) { await load() }
        }
        .confirmationDialog("Remove \(pendingDelete?.name ?? "sensor")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Remove sensor", role: .destructive) { if let p = pendingDelete { delete(p.scope, p.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This only removes the binding in Bambuddy. The entity stays in Home Assistant.") }
        .task { await load() }
        .refreshable { await load() }
    }

    private func sensorRow(_ row: SensorRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let reading = row.reading {
                    Text(reading.display).font(.subheadline.monospacedDigit())
                        .foregroundStyle(reading.alerting == true ? Color.statusError : (reading.reachable == false ? Color.textMuted : Color.primary))
                }
            }
            Text(row.entityId).font(.caption.monospaced()).foregroundStyle(Color.textMuted).lineLimit(1)
            HStack(spacing: 6) {
                if let alert = row.alertText { Pill(text: alert, tint: .statusWarning, systemImage: "bell.badge") }
                if row.notifies { Pill(text: "Notifies", tint: .statusFinished) }
                if row.blocksPrint { Pill(text: "Blocks prints", tint: .statusError) }
                if row.reading?.alerting == true { Pill(text: "Alerting now", tint: .statusError) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func alertText(_ state: String?, _ above: Double?, _ below: Double?) -> String? {
        if let state { return "Alert when \(state)" }
        switch (above, below) {
        case let (a?, b?): return "Alert above \(a.formatted()) or below \(b.formatted())"
        case let (a?, nil): return "Alert above \(a.formatted())"
        case let (nil, b?): return "Alert below \(b.formatted())"
        default: return nil
        }
    }

    private func load() async {
        do {
            printers = (try? await APIClient.shared.printers()) ?? printers
            locations = (try? await session.perform { try await APIClient.shared.setupStorageLocations(bearer: $0) }) ?? locations
            printerSensors = try await session.perform { try await APIClient.shared.haSensors(printerId: nil, bearer: $0) }
            locationSensors = (try? await session.perform { try await APIClient.shared.haLocSensors(bearer: $0) }) ?? []
            var fresh: [String: SetupHAReading] = [:]
            for pid in Set(printerSensors.map(\.printerId)) {
                let list = (try? await session.perform { try await APIClient.shared.haReadings(printerId: pid, bearer: $0) }) ?? []
                for r in list { fresh["p\(r.id)"] = r }
            }
            for lid in Set(locationSensors.map(\.locationId)) {
                let list = (try? await session.perform { try await APIClient.shared.haLocReadings(locationId: lid, bearer: $0) }) ?? []
                for r in list { fresh["l\(r.id)"] = r }
            }
            readings = fresh
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func delete(_ scope: SensorScope, _ id: Int) {
        Task {
            do {
                try await session.perform {
                    if scope == .printer { try await APIClient.shared.haDelete(id, bearer: $0) }
                    else { try await APIClient.shared.haLocDelete(id, bearer: $0) }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
            pendingDelete = nil
        }
    }
}

// MARK: - Add sensor

private struct AddSensorSheet: View {
    let scope: SensorScope
    let printers: [Printer]
    let locations: [SetupStorageLocation]
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var targetId: Int?
    @State private var entity: SetupHAEntity?
    @State private var name = ""
    @State private var alertState = "" // "", "on", "off"
    @State private var above = ""
    @State private var below = ""
    @State private var block = false
    @State private var notify = false
    @State private var showOnCard = true
    @State private var busy = false
    @State private var error: String?

    private var aboveValue: Double? { Double(above.replacingOccurrences(of: ",", with: ".")) }
    private var belowValue: Double? { Double(below.replacingOccurrences(of: ",", with: ".")) }

    private var hasAlert: Bool {
        guard let entity else { return false }
        return entity.kind == "binary" ? !alertState.isEmpty : (aboveValue != nil || belowValue != nil)
    }

    private var problem: String? {
        guard let entity else { return nil }
        if entity.kind == "numeric", !above.isEmpty, aboveValue == nil { return "Alert above must be a number." }
        if entity.kind == "numeric", !below.isEmpty, belowValue == nil { return "Alert below must be a number." }
        if let a = aboveValue, let b = belowValue, b >= a { return "Alert below must be lower than alert above." }
        if (block || notify), !hasAlert { return "Blocking prints and notifications need an alert condition." }
        return nil
    }

    private var canSave: Bool {
        targetId != nil && entity != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(scope == .printer ? "Printer" : "Storage location") {
                    if scope == .printer {
                        Picker("Printer", selection: $targetId) {
                            Text("Choose").tag(Int?.none)
                            ForEach(printers) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                    } else {
                        Picker("Location", selection: $targetId) {
                            Text("Choose").tag(Int?.none)
                            ForEach(locations) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        EntityPicker(scope: scope) { picked in
                            entity = picked
                            if name.isEmpty { name = picked.friendlyName }
                            alertState = ""; above = ""; below = ""
                            block = false; notify = false
                        }
                    } label: {
                        if let entity {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.friendlyName)
                                Text(entity.entityId).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                            }
                        } else {
                            Text("Choose a Home Assistant entity")
                        }
                    }
                } header: { Text("Entity") } footer: {
                    Text("Binary sensors (door, window, leak) and numeric sensors (temperature, humidity, battery) are supported.")
                }
                if let entity {
                    Section("Label") { TextField("Name", text: $name) }
                    Section {
                        if entity.kind == "binary" {
                            Picker("Alert when", selection: $alertState) {
                                Text("Never").tag("")
                                Text("On").tag("on")
                                Text("Off").tag("off")
                            }
                        } else {
                            TextField("Alert above", text: $above).keyboardType(.numbersAndPunctuation)
                            TextField("Alert below", text: $below).keyboardType(.numbersAndPunctuation)
                        }
                        Toggle("Send a notification on alert", isOn: $notify)
                        if scope == .printer { Toggle("Block prints while alerting", isOn: $block) }
                        Toggle(scope == .printer ? "Show on printer card" : "Show on location card", isOn: $showOnCard)
                    } header: { Text("Alert") } footer: {
                        Text(problem ?? "Optional. Without an alert condition the sensor is display-only.")
                            .foregroundStyle(problem == nil ? Color.textMuted : Color.statusError)
                    }
                }
                if let error { Section { InlineError(message: error) } }
            }
            .farmBackground()
            .navigationTitle("Add sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Add") { Task { await save() } }.disabled(!canSave) }
                }
            }
        }
    }

    private func save() async {
        guard let entity, let targetId else { return }
        busy = true
        error = nil
        defer { busy = false }
        var body: [String: AdminJSON] = [
            scope == .printer ? "printer_id" : "location_id": .int(targetId),
            "name": .string(String(name.trimmingCharacters(in: .whitespaces).prefix(100))),
            "entity_id": .string(entity.entityId),
            "kind": .string(entity.kind),
            "notify_on_alert": .bool(notify),
            scope == .printer ? "show_on_printer_card" : "show_on_card": .bool(showOnCard),
        ]
        if scope == .printer { body["block_print"] = .bool(block) }
        if let dc = entity.deviceClass { body["device_class"] = .string(String(dc.prefix(32))) }
        if let unit = entity.unitOfMeasurement { body["unit"] = .string(String(unit.prefix(16))) }
        if entity.kind == "binary", !alertState.isEmpty { body["alert_state"] = .string(alertState) }
        if entity.kind == "numeric" {
            if let a = aboveValue { body["alert_above"] = .double(a) }
            if let b = belowValue { body["alert_below"] = .double(b) }
        }
        let payload = AdminJSON.object(body)
        do {
            try await session.perform {
                if scope == .printer { try await APIClient.shared.haCreate(payload, bearer: $0) }
                else { try await APIClient.shared.haLocCreate(payload, bearer: $0) }
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

private struct EntityPicker: View {
    let scope: SensorScope
    var picked: (SetupHAEntity) -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var entities: [SetupHAEntity] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List(entities) { entity in
            Button {
                picked(entity)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entity.friendlyName).font(.subheadline)
                        Spacer()
                        if let state = entity.state {
                            Text(entity.unitOfMeasurement.map { "\(state) \($0)" } ?? state).font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                    Text(entity.entityId).font(.caption.monospaced()).foregroundStyle(Color.textMuted)
                }
            }
            .foregroundStyle(.primary)
        }
        .farmBackground()
        .navigationTitle("Entities")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search entities")
        .onSubmit(of: .search) { Task { await load() } }
        .overlay {
            if let error {
                ContentUnavailableView("Couldn't load entities", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !loaded { ProgressView() }
            else if entities.isEmpty { ContentUnavailableView.search }
        }
        .task { await load() }
    }

    private func load() async {
        loaded = false
        do {
            let term = search
            let isPrinter = scope == .printer
            entities = try await session.perform { bearer -> [SetupHAEntity] in
                if isPrinter { return try await APIClient.shared.haEntities(search: term, bearer: bearer) }
                return try await APIClient.shared.haLocEntities(search: term, bearer: bearer)
            }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}
