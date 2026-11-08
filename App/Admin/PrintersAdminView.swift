import SwiftUI

/// Printer management (Bambuddy: Printers page add/edit modal). Needs an admin session.
struct PrintersAdminView: View {
    var body: some View {
        AdminGate(title: "Printers", permission: "printers:read") { PrintersAdminList() }
    }
}

private struct PrintersAdminList: View {
    @ObservedObject private var session = AdminSession.shared
    @EnvironmentObject private var farm: FarmStore
    @State private var printers: [AdminPrinter] = []
    @State private var connected: [Int: Bool] = [:]
    @State private var devWarnings: [Int: String] = [:]
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false
    @State private var busyId: Int?
    @State private var toast: String?

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let toast { Text(toast).font(.footnote).foregroundStyle(Color.textSecondary) }
            if !devWarnings.isEmpty {
                Section {
                    Label {
                        Text("Developer LAN mode is off on \(devWarnings.values.sorted().joined(separator: ", ")). Some controls won't work on these printers until you turn it on.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                } footer: {
                    Text("Turn on LAN Only and Developer Mode in the printer's network settings.")
                }
            }
            ForEach(printers) { printer in
                NavigationLink {
                    PrinterFormView(mode: .edit(printer)) { await load() }
                } label: { row(printer) }
                    .contextMenu { actions(printer) }
                    .swipeActions(edge: .trailing) {
                        if session.can("printers:control") {
                            if isConnected(printer) {
                                Button { run(printer, "Disconnected") { _ = try await APIClient.shared.disconnectPrinter(printer.id, bearer: $0); connected[printer.id] = false } }
                                    label: { Label("Disconnect", systemImage: "bolt.slash.fill") }.tint(.statusWarning)
                            } else {
                                Button { connect(printer) } label: { Label("Connect", systemImage: "bolt.fill") }.tint(.accentTeal)
                            }
                        }
                    }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, printers.isEmpty, error == nil {
                ContentUnavailableView("No printers", systemImage: "printer.fill", description: Text("Add your first printer with the + button."))
            } else if !loaded, error == nil {
                ProgressView()
            }
        }
        .toolbar {
            if session.can("printers:create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add printer")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { PrinterFormView(mode: .add) { await load() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func isConnected(_ p: AdminPrinter) -> Bool { connected[p.id] ?? (farm.statuses[p.id]?.connected ?? false) }

    private func row(_ p: AdminPrinter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(p.name).font(.subheadline.weight(.semibold))
                Spacer()
                if busyId == p.id { ProgressView() }
                if devWarnings[p.id] != nil { Pill(text: "Dev mode off", tint: .statusWarning, systemImage: "exclamationmark.triangle.fill") }
                if p.isActive == false {
                    Pill(text: "Inactive", tint: .textMuted)
                } else if isConnected(p) {
                    Pill(text: "Connected", tint: .accentTeal, systemImage: "bolt.fill")
                } else {
                    Pill(text: "Offline", tint: .statusWarning)
                }
            }
            Text([p.model.map { Printer.modelNames[$0] ?? $0 }, p.ipAddress, p.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Color.textMuted)
            if let serial = p.serialNumber { Text(serial).font(.caption2.monospaced()).foregroundStyle(Color.textMuted) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func actions(_ p: AdminPrinter) -> some View {
        if session.can("printers:control") {
            if isConnected(p) {
                Button { run(p, "Disconnected") { _ = try await APIClient.shared.disconnectPrinter(p.id, bearer: $0); connected[p.id] = false } }
                    label: { Label("Disconnect", systemImage: "bolt.slash") }
            } else {
                Button { connect(p) } label: { Label("Connect", systemImage: "bolt") }
            }
        }
        if session.can("printers:read") {
            Button { run(p, "Status refresh requested") { try await APIClient.shared.refreshPrinterStatus(p.id, bearer: $0) } }
                label: { Label("Refresh status", systemImage: "arrow.clockwise") }
        }
    }

    private func connect(_ p: AdminPrinter) {
        run(p, nil) { bearer in
            let ok = try await APIClient.shared.connectPrinter(p.id, bearer: bearer)
            connected[p.id] = ok
            toast = ok ? "\(p.name) connected." : "\(p.name) didn't connect. Check its IP address and access code."
        }
    }

    private func run(_ p: AdminPrinter, _ done: String?, _ op: @escaping (String?) async throws -> Void) {
        Task {
            busyId = p.id
            defer { busyId = nil }
            do {
                try await session.perform(op)
                if let done { toast = "\(p.name): \(done.lowercased())." }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                await load()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func load() async {
        do {
            printers = try await session.perform { try await APIClient.shared.adminPrinters(bearer: $0) }
            // Best effort: the warning list needs a connected printer, and its absence is not an error.
            devWarnings = (try? await session.perform { try await APIClient.shared.developerModeWarnings(bearer: $0) }) ?? [:]
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}

// MARK: - Add / edit

struct PrinterFormView: View {
    enum Mode { case add, edit(AdminPrinter) }

    let mode: Mode
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serial = ""
    @State private var ip = ""
    @State private var accessCode = ""
    @State private var model = ""
    @State private var location = ""
    @State private var autoArchive = true
    @State private var isActive = true
    @State private var wearCost = ""
    @State private var cameraEnabled = false
    @State private var cameraType = "mjpeg"
    @State private var cameraURL = ""
    @State private var snapshotURL = ""
    @State private var rotation = 0
    @State private var lightAuto = false
    @State private var plateDetection = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var loadedOnce = false
    @State private var discovering = false
    @State private var prefilled = false

    private var editing: AdminPrinter? { if case let .edit(p) = mode { p } else { nil } }

    private var canSave: Bool {
        let base = !name.trimmingCharacters(in: .whitespaces).isEmpty && !ip.trimmingCharacters(in: .whitespaces).isEmpty
        if editing == nil { return base && !serial.trimmingCharacters(in: .whitespaces).isEmpty && !accessCode.isEmpty }
        return base
    }

    var body: some View {
        Form {
            if editing == nil, session.can("discovery:scan") {
                Section {
                    Button { discovering = true } label: { Label("Find printers on the network", systemImage: "dot.radiowaves.left.and.right") }
                    if prefilled {
                        Label("Filled in from a discovered printer. Enter its access code.", systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(Color.accentTeal)
                    }
                } footer: {
                    Text("Searches the network Bambuddy is on and fills in the name, serial, address and model for you.")
                }
            }
            Section("Printer") {
                TextField("Name", text: $name)
                if editing == nil {
                    TextField("Serial number", text: $serial)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } else {
                    LabeledContent("Serial number", value: serial)
                }
                TextField("IP address or hostname", text: $ip)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(editing == nil ? "Access code" : "Access code (blank keeps current)", text: $accessCode)
                    .textContentType(.password).autocorrectionDisabled()
                Picker("Model", selection: $model) {
                    Text("Not set").tag("")
                    ForEach(AdminPrinterModels.all, id: \.self) { Text($0).tag($0) }
                }
                TextField("Location", text: $location)
            }
            Section {
                Toggle("Auto-archive prints", isOn: $autoArchive)
                if editing != nil {
                    Toggle("Active", isOn: $isActive)
                    HStack {
                        Text("Wear cost per hour")
                        Spacer()
                        TextField("0", text: $wearCost).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                    }
                    Toggle("Plate detection", isOn: $plateDetection)
                    if let p = editing, session.can("printers:update") {
                        NavigationLink { PlateROIEditorView(printerId: p.id, printerName: p.name) } label: {
                            Label("Detection area and test", systemImage: "viewfinder")
                        }
                    }
                }
            } footer: {
                if editing != nil { Text("An inactive printer is disconnected and hidden from the farm.") }
            }
            Section("Camera") {
                if let p = editing, session.can("camera:view") {
                    NavigationLink { CameraDiagnosticsView(printer: p) } label: {
                        Label("Test and diagnose camera", systemImage: "stethoscope")
                    }
                }
                Picker("Rotation", selection: $rotation) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                Toggle("Light on automatically", isOn: $lightAuto)
                Toggle("Use external camera", isOn: $cameraEnabled)
                if cameraEnabled {
                    Picker("Type", selection: $cameraType) {
                        ForEach(AdminPrinterModels.cameraTypes, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    TextField("Stream URL", text: $cameraURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Snapshot URL (optional)", text: $snapshotURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if editing != nil, session.can("printers:delete") {
                Section {
                    Button("Delete printer", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes the printer from Bambuddy, along with its maintenance schedule and queue entries.")
                }
            }
        }
        .farmBackground()
        .navigationTitle(editing == nil ? "Add printer" : "Edit printer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button(editing == nil ? "Add" : "Save") { Task { await save() } }.disabled(!canSave) }
            }
        }
        .confirmationDialog("Delete \(editing?.name ?? "printer")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete printer, keep archives", role: .destructive) { Task { await delete(archives: false) } }
            Button("Delete printer and its archives", role: .destructive) { Task { await delete(archives: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Deleting its archives also removes its print history and photos.")
        }
        .onAppear(perform: populate)
        .sheet(isPresented: $discovering) {
            DiscoverySheet { found in
                if !found.name.isEmpty { name = found.name }
                serial = found.realSerial
                ip = found.ipAddress
                if !found.pickerModel.isEmpty { model = found.pickerModel }
                prefilled = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func populate() {
        guard !loadedOnce, let p = editing else { return }
        loadedOnce = true
        name = p.name
        serial = p.serialNumber ?? ""
        ip = p.ipAddress ?? ""
        model = p.model ?? ""
        location = p.location ?? ""
        autoArchive = p.autoArchive ?? true
        isActive = p.isActive ?? true
        wearCost = p.wearCostPerHour.map { $0 > 0 ? String($0) : "" } ?? ""
        cameraEnabled = p.externalCameraEnabled ?? false
        cameraType = p.externalCameraType ?? "mjpeg"
        cameraURL = p.externalCameraUrl ?? ""
        snapshotURL = p.externalCameraSnapshotUrl ?? ""
        rotation = p.cameraRotation ?? 0
        lightAuto = p.cameraLightAuto ?? false
        plateDetection = p.plateDetectionEnabled ?? false
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let p = editing {
                let patch = diff(from: p)
                guard !patch.isEmpty else { dismiss(); return }
                try await session.perform { try await APIClient.shared.updatePrinter(p.id, patch: .object(patch), bearer: $0) }
            } else {
                var body: [String: AdminJSON] = [
                    "name": .string(name.trimmingCharacters(in: .whitespaces)),
                    "serial_number": .string(serial.trimmingCharacters(in: .whitespaces)),
                    "ip_address": .string(ip.trimmingCharacters(in: .whitespaces)),
                    "access_code": .string(accessCode),
                    "auto_archive": .bool(autoArchive),
                    "camera_rotation": .int(rotation),
                    "camera_light_auto": .bool(lightAuto),
                    "external_camera_enabled": .bool(cameraEnabled),
                ]
                if !model.isEmpty { body["model"] = .string(model) }
                if !location.trimmingCharacters(in: .whitespaces).isEmpty { body["location"] = .string(location) }
                if cameraEnabled {
                    body["external_camera_type"] = .string(cameraType)
                    if !cameraURL.isEmpty { body["external_camera_url"] = .string(cameraURL) }
                    if !snapshotURL.isEmpty { body["external_camera_snapshot_url"] = .string(snapshotURL) }
                }
                try await session.perform { try await APIClient.shared.createPrinter(.object(body), bearer: $0) }
            }
            accessCode = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func diff(from p: AdminPrinter) -> [String: AdminJSON] {
        var patch: [String: AdminJSON] = [:]
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        if trimmed(name) != p.name { patch["name"] = .string(trimmed(name)) }
        if trimmed(ip) != (p.ipAddress ?? "") { patch["ip_address"] = .string(trimmed(ip)) }
        if !accessCode.isEmpty { patch["access_code"] = .string(accessCode) }
        if !model.isEmpty, model != (p.model ?? "") { patch["model"] = .string(model) }
        if trimmed(location) != (p.location ?? "") { patch["location"] = .string(trimmed(location)) }
        if autoArchive != (p.autoArchive ?? true) { patch["auto_archive"] = .bool(autoArchive) }
        if isActive != (p.isActive ?? true) { patch["is_active"] = .bool(isActive) }
        let cost = Double(wearCost.replacingOccurrences(of: ",", with: "."))
        if (cost ?? 0) != (p.wearCostPerHour ?? 0) { patch["wear_cost_per_hour"] = cost.map { .double($0) } ?? .null }
        if cameraEnabled != (p.externalCameraEnabled ?? false) { patch["external_camera_enabled"] = .bool(cameraEnabled) }
        if cameraType != (p.externalCameraType ?? "mjpeg") { patch["external_camera_type"] = .string(cameraType) }
        if cameraURL != (p.externalCameraUrl ?? "") { patch["external_camera_url"] = .string(cameraURL) }
        if snapshotURL != (p.externalCameraSnapshotUrl ?? "") { patch["external_camera_snapshot_url"] = .string(snapshotURL) }
        if rotation != (p.cameraRotation ?? 0) { patch["camera_rotation"] = .int(rotation) }
        if lightAuto != (p.cameraLightAuto ?? false) { patch["camera_light_auto"] = .bool(lightAuto) }
        if plateDetection != (p.plateDetectionEnabled ?? false) { patch["plate_detection_enabled"] = .bool(plateDetection) }
        return patch
    }

    private func delete(archives: Bool) async {
        guard let p = editing else { return }
        saving = true
        defer { saving = false }
        do {
            try await session.perform { try await APIClient.shared.deletePrinter(p.id, deleteArchives: archives, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}
