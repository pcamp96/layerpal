import SwiftUI

/// Spoolman connection (Bambuddy: Settings > Spoolman). Status needs `filaments:read`; the URL, enable switch,
/// connect and disconnect need `settings:update`; syncing AMS data needs `filaments:update`.
struct SpoolmanSetupView: View {
    var body: some View {
        SessionGate(title: "Spoolman", permission: "filaments:read") { SpoolmanContent() }
    }
}

private struct SpoolmanContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var status: SetupSpoolmanStatus?
    @State private var printers: [Printer] = []
    @State private var url = ""
    @State private var enabled = false
    @State private var syncMode = "auto"
    @State private var savedSyncMode = "auto"
    @State private var settingsLoaded = false
    @State private var busy: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var result: (title: String, body: String)?
    @State private var showResult = false
    @State private var confirmDisconnect = false

    private var canEdit: Bool { session.can("settings:update") }
    private var canSync: Bool { session.can("filaments:update") }
    private var urlChanged: Bool { url.trimmingCharacters(in: .whitespaces) != (status?.url ?? "") }

    var body: some View {
        Form {
            if let error { Section { InlineError(message: error) } }
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(Color.textSecondary) } }
            Section {
                HStack {
                    Label("Spoolman", systemImage: "cylinder.split.1x2.fill")
                    Spacer()
                    if let status {
                        Pill(text: status.connected ? "Connected" : (status.enabled ? "Not reachable" : "Off"),
                             tint: status.connected ? .accentTeal : (status.enabled ? .statusError : .textMuted))
                    } else if error == nil { ProgressView() }
                }
                if let status, status.connected, status.nativeTags == true {
                    Text("This Spoolman links RFID tags natively.").font(.footnote).foregroundStyle(Color.textMuted)
                }
            } header: { Text("Status") }
            if canEdit {
                Section {
                    Toggle("Use Spoolman", isOn: $enabled).onChange(of: enabled) { _, new in
                        if settingsLoaded, new != (status?.enabled ?? false) { Task { await save(["spoolman_enabled": .bool(new)]) } }
                    }
                    TextField("http://192.168.1.20:7912", text: $url).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if urlChanged {
                        Button("Save address") { Task { await save(["spoolman_url": .string(url.trimmingCharacters(in: .whitespaces))]) } }
                            .disabled(busy != nil)
                    }
                    Picker("Sync", selection: $syncMode) {
                        Text("Automatic").tag("auto")
                        Text("Manual").tag("manual")
                    }
                    .onChange(of: syncMode) { _, new in
                        if settingsLoaded, new != savedSyncMode { Task { await save(["spoolman_sync_mode": .string(new)]) } }
                    }
                } header: { Text("Settings") } footer: {
                    Text("Automatic sync pushes AMS changes to Spoolman as they happen. Manual waits for you to sync below.")
                }
                Section {
                    Button { Task { await connect() } } label: {
                        HStack { Text(status?.connected == true ? "Reconnect" : "Connect"); if busy == "connect" { Spacer(); ProgressView() } }
                    }
                    .disabled(busy != nil || status?.enabled != true || (status?.url ?? "").isEmpty)
                    if status?.connected == true {
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }.disabled(busy != nil)
                    }
                } footer: { Text("Connect checks the saved address and registers the extra fields Bambuddy stores in Spoolman.") }
            }
            if canSync, status?.connected == true {
                Section {
                    Button { Task { await syncAll() } } label: {
                        HStack { Text("Sync all printers"); if busy == "all" { Spacer(); ProgressView() } }
                    }
                    .disabled(busy != nil)
                    ForEach(printers) { printer in
                        Button { Task { await sync(printer) } } label: {
                            HStack { Text(printer.name); Spacer(); if busy == "p\(printer.id)" { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.textMuted) } }
                        }
                        .foregroundStyle(.primary)
                        .disabled(busy != nil)
                    }
                } header: { Text("Sync AMS to Spoolman") }
            }
        }
        .farmBackground()
        .task { await load() }
        .refreshable { await load() }
        .alert(result?.title ?? "", isPresented: $showResult) { Button("OK", role: .cancel) {} } message: { Text(result?.body ?? "") }
        .confirmationDialog("Disconnect from Spoolman?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
        } message: { Text("Bambuddy stops talking to Spoolman until you connect again. Your spools stay in Spoolman.") }
    }

    private func load() async {
        do {
            status = try await session.perform { try await APIClient.shared.spoolmanStatus(bearer: $0) }
            error = nil
            url = status?.url ?? ""
            enabled = status?.enabled ?? false
        } catch {
            self.error = AdminError.friendly(error)
        }
        if let settings = try? await session.perform({ try await APIClient.shared.adminSettings(bearer: $0) }) {
            savedSyncMode = settings["spoolman_sync_mode"]?.string ?? "auto"
            syncMode = savedSyncMode
        }
        printers = (try? await APIClient.shared.printers()) ?? printers
        settingsLoaded = true
    }

    private func save(_ patch: [String: AdminJSON]) async {
        busy = "save"
        defer { busy = nil }
        do {
            _ = try await session.perform { try await APIClient.shared.patchSettings(patch, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            notice = nil
            await load()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await load()
        }
    }

    private func connect() async {
        busy = "connect"
        defer { busy = nil }
        do {
            try await session.perform { try await APIClient.shared.spoolmanConnect(bearer: $0) }
            notice = "Connected to Spoolman."
            error = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func disconnect() async {
        busy = "disconnect"
        defer { busy = nil }
        do {
            try await session.perform { try await APIClient.shared.spoolmanDisconnect(bearer: $0) }
            notice = "Disconnected from Spoolman."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await load()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func sync(_ printer: Printer) async {
        busy = "p\(printer.id)"
        defer { busy = nil }
        await run(title: printer.name) { try await APIClient.shared.spoolmanSync(printerId: printer.id, bearer: $0) }
    }

    private func syncAll() async {
        busy = "all"
        defer { busy = nil }
        await run(title: "All printers") { try await APIClient.shared.spoolmanSyncAll(bearer: $0) }
    }

    private func run(title: String, _ call: (String?) async throws -> SetupSyncResult) async {
        do {
            let r = try await session.perform(call)
            var lines = ["\(r.syncedCount) spool\(r.syncedCount == 1 ? "" : "s") synced"]
            if let skipped = r.skippedCount, skipped > 0 { lines.append("\(skipped) skipped (no RFID tag or slot assignment)") }
            for e in (r.errors ?? []).prefix(4) { lines.append(e) }
            result = (r.success ? "\(title): done" : "\(title): problems", lines.joined(separator: "\n"))
            showResult = true
            UINotificationFeedbackGenerator().notificationOccurred(r.success ? .success : .warning)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
