import SwiftUI

/// Notification providers (Bambuddy: Settings > Notifications). Needs an admin session.
struct NotificationsAdminView: View {
    var body: some View {
        AdminGate(title: "Notifications", permission: "notifications:read") { ProviderList() }
    }
}

private struct ProviderList: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var providers: [NotificationProviderItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false
    @State private var pendingDelete: NotificationProviderItem?
    @State private var testResult: (title: String, message: String)?
    @State private var showTest = false
    @State private var testingId: Int?

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if session.can("notification_templates:read") {
                NavigationLink { MessageTemplatesView() } label: {
                    IconLabel(title: "Message templates", symbol: "text.bubble.fill", tint: .pink)
                }
            }
            ForEach(providers) { provider in
                NavigationLink {
                    ProviderEditView(provider: provider) { await load() }
                } label: { row(provider) }
                    .swipeActions(edge: .trailing) {
                        if session.can("notifications:delete") {
                            Button(role: .destructive) { pendingDelete = provider } label: { Label("Delete", systemImage: "trash") }
                        }
                        if session.can("notifications:update") {
                            Button { test(provider) } label: { Label("Test", systemImage: "paperplane.fill") }.tint(.statusFinished)
                        }
                    }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, providers.isEmpty, error == nil {
                ContentUnavailableView("No providers", systemImage: "bell.slash", description: Text("Add ntfy, Pushover, Telegram, Discord and more with +."))
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            if session.can("notifications:create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add provider")
                }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { ProviderCreateView { await load() } } }
        .alert(testResult?.title ?? "", isPresented: $showTest) {
            Button("OK", role: .cancel) {}
        } message: { Text(testResult?.message ?? "") }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete provider", role: .destructive) { if let p = pendingDelete { delete(p) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDelete?.isThisApp == true
                ? "This is LayerPal's own provider. Deleting it stops push alerts and Lock Screen progress on this iPhone until you set up notifications again."
                : "This can't be undone.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var deleteTitle: String { "Delete \(pendingDelete?.name ?? "provider")?" }

    private func row(_ p: NotificationProviderItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Pill(text: p.typeLabel, tint: .textSecondary)
                if p.isThisApp { Pill(text: "This app", tint: .accentTeal) }
                Spacer(minLength: 4)
                if testingId == p.id { ProgressView() }
                Toggle("Enabled", isOn: Binding(get: { p.enabled }, set: { setEnabled(p, $0) }))
                    .labelsHidden().disabled(!session.can("notifications:update"))
            }
            if let err = p.lastError, !err.isEmpty {
                Text("Last error: \(err)").font(.caption).foregroundStyle(Color.statusError).lineLimit(2)
            } else if let ok = p.lastSuccess {
                Text("Last sent \(ok.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(Color.textMuted)
            } else {
                Text(p.enabled ? "Nothing sent yet" : "Off").font(.caption).foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func setEnabled(_ p: NotificationProviderItem, _ on: Bool) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.updateNotificationProvider(p.id, patch: .object(["enabled": .bool(on)]), bearer: $0) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }

    private func test(_ p: NotificationProviderItem) {
        Task {
            testingId = p.id
            defer { testingId = nil }
            do {
                let result = try await session.perform { try await APIClient.shared.testNotificationProvider(p.id, bearer: $0) }
                testResult = (result.success ? "Test sent" : "Test failed", result.message)
                showTest = true
                UINotificationFeedbackGenerator().notificationOccurred(result.success ? .success : .error)
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }

    private func delete(_ p: NotificationProviderItem) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.deleteNotificationProvider(p.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
            pendingDelete = nil
        }
    }

    private func load() async {
        do {
            providers = try await session.perform { try await APIClient.shared.notificationProviders(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}

// MARK: - Config field editor

private struct ConfigFieldRow: View {
    let field: ProviderConfigField
    @Binding var value: String

    var body: some View {
        switch field.kind {
        case .secret:
            SecureField(field.label, text: $value).textContentType(.password).autocorrectionDisabled()
        case .number:
            TextField(field.label, text: $value, prompt: Text(field.placeholder.isEmpty ? field.label : field.placeholder)).keyboardType(.numberPad)
        case let .choice(options):
            Picker(field.label, selection: Binding(get: { value.isEmpty ? options[0].0 : value }, set: { value = $0 })) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
        case .multiline:
            VStack(alignment: .leading) {
                Text(field.label).font(.caption).foregroundStyle(Color.textMuted)
                TextEditor(text: $value).font(.callout.monospaced()).frame(minHeight: 70)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .text:
            TextField(field.label, text: $value, prompt: Text(field.placeholder.isEmpty ? field.label : field.placeholder))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

// MARK: - Edit

private struct ProviderEditView: View {
    let provider: NotificationProviderItem
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var enabled = true
    @State private var attachPhoto = true
    @State private var printerId: Int?
    @State private var config: [String: String] = [:]
    @State private var events: [String: Bool] = [:]
    @State private var quietEnabled = false
    @State private var quietStart = ProviderEditView.time("22:00")
    @State private var quietEnd = ProviderEditView.time("07:00")
    @State private var digestEnabled = false
    @State private var digestTime = ProviderEditView.time("08:00")
    @State private var saving = false
    @State private var error: String?
    @State private var testMessage: String?
    @State private var ready = false

    private var fields: [ProviderConfigField] { ProviderConfigField.fields(for: provider.providerType) }
    private var canUpdate: Bool { session.can("notifications:update") }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $enabled)
                Toggle("Attach camera snapshot", isOn: $attachPhoto)
            } footer: {
                if provider.isThisApp { Text("This provider delivers LayerPal's push alerts. Changing its URL or turning it off affects this app.") }
            }
            Section {
                PrinterFilterPicker(printerId: $printerId)
            } footer: {
                Text("Only send events from one printer. A few fleet-wide alerts may still come through, and events that aren't about a printer are skipped.")
            }
            if !fields.isEmpty, !provider.isThisApp {
                Section {
                    ForEach(fields) { ConfigFieldRow(field: $0, value: binding($0.key)) }
                } header: { Text("\(provider.typeLabel) settings") } footer: {
                    Text("Saved secrets show as asterisks. Leave them alone to keep them.")
                }
            }
            ForEach(NotificationEventGroup.all) { group in
                Section(group.title) {
                    ForEach(group.events) { event in
                        Toggle(event.label, isOn: Binding(get: { events[event.key] ?? false }, set: { events[event.key] = $0 }))
                    }
                }
            }
            Section("Quiet hours") {
                Toggle("Hold notifications during quiet hours", isOn: $quietEnabled)
                if quietEnabled {
                    DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $quietEnd, displayedComponents: .hourAndMinute)
                }
            }
            Section("Daily digest") {
                Toggle("Batch into one daily message", isOn: $digestEnabled)
                if digestEnabled { DatePicker("Send at", selection: $digestTime, displayedComponents: .hourAndMinute) }
            }
            if let testMessage { Section { Text(testMessage).font(.footnote).foregroundStyle(Color.textSecondary) } }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if canUpdate {
                Section {
                    Button("Send test notification") { Task { await sendTest() } }
                }
            }
        }
        .farmBackground()
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(!canUpdate || name.isEmpty) }
            }
        }
        .onAppear(perform: populate)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { config[key] ?? "" }, set: { config[key] = $0 })
    }

    static func time(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts.first ?? 0
        c.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: c) ?? Date()
    }

    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func populate() {
        guard !ready else { return }
        ready = true
        name = provider.name
        enabled = provider.enabled
        attachPhoto = provider.flag("attach_photo")
        printerId = provider.raw["printer_id"]?.int
        config = provider.config
        for group in NotificationEventGroup.all { for e in group.events { events[e.key] = provider.flag(e.key) } }
        quietEnabled = provider.flag("quiet_hours_enabled")
        if let s = provider.text("quiet_hours_start") { quietStart = Self.time(s) }
        if let s = provider.text("quiet_hours_end") { quietEnd = Self.time(s) }
        digestEnabled = provider.flag("daily_digest_enabled")
        if let s = provider.text("daily_digest_time") { digestTime = Self.time(s) }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        var patch: [String: AdminJSON] = [:]
        if name != provider.name { patch["name"] = .string(name) }
        if enabled != provider.enabled { patch["enabled"] = .bool(enabled) }
        if attachPhoto != provider.flag("attach_photo") { patch["attach_photo"] = .bool(attachPhoto) }
        // An explicit null clears the filter (back to all printers); the route applies what was sent.
        if printerId != provider.raw["printer_id"]?.int { patch["printer_id"] = printerId.map { .int($0) } ?? .null }
        for (key, value) in events where value != provider.flag(key) { patch[key] = .bool(value) }
        if quietEnabled != provider.flag("quiet_hours_enabled") { patch["quiet_hours_enabled"] = .bool(quietEnabled) }
        if quietEnabled {
            patch["quiet_hours_start"] = .string(Self.hhmm(quietStart))
            patch["quiet_hours_end"] = .string(Self.hhmm(quietEnd))
        }
        if digestEnabled != provider.flag("daily_digest_enabled") { patch["daily_digest_enabled"] = .bool(digestEnabled) }
        if digestEnabled { patch["daily_digest_time"] = .string(Self.hhmm(digestTime)) }
        if !provider.isThisApp, !fields.isEmpty, config != provider.config {
            // Config replaces the stored one, so start from the full original (keeps non-string keys).
            var merged = provider.raw["config"]?.object ?? [:]
            for field in fields {
                let value = config[field.key] ?? ""
                if value.isEmpty { merged.removeValue(forKey: field.key) } else { merged[field.key] = .string(value) }
            }
            patch["config"] = .object(merged)
        }
        guard !patch.isEmpty else { dismiss(); return }
        do {
            try await session.perform { try await APIClient.shared.updateNotificationProvider(provider.id, patch: .object(patch), bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func sendTest() async {
        testMessage = nil
        error = nil
        do {
            let r = try await session.perform { try await APIClient.shared.testNotificationProvider(provider.id, bearer: $0) }
            testMessage = (r.success ? "Sent: " : "Failed: ") + r.message
            UINotificationFeedbackGenerator().notificationOccurred(r.success ? .success : .error)
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}

// MARK: - Create

private struct ProviderCreateView: View {
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var type = "ntfy"
    @State private var name = ""
    @State private var printerId: Int?
    @State private var config: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?
    @State private var testMessage: String?

    private var fields: [ProviderConfigField] { ProviderConfigField.fields(for: type) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && fields.filter(\.required).allSatisfy { !(config[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $type) {
                    ForEach(ProviderConfigField.creatableTypes, id: \.self) { Text(NotificationProviderItem.typeLabels[$0] ?? $0).tag($0) }
                }
                TextField("Name", text: $name, prompt: Text("e.g. Phone alerts"))
                PrinterFilterPicker(printerId: $printerId)
            }
            Section("\(NotificationProviderItem.typeLabels[type] ?? type) settings") {
                ForEach(fields) { f in
                    ConfigFieldRow(field: f, value: Binding(get: { config[f.key] ?? "" }, set: { config[f.key] = $0 }))
                }
            }
            Section {
                Text("New providers use Bambuddy's default events (finished, failed, stopped and a few more). Pick the rest after adding.")
                    .font(.footnote).foregroundStyle(Color.textSecondary)
            }
            if let testMessage { Section { Text(testMessage).font(.footnote).foregroundStyle(Color.textSecondary) } }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            Section {
                Button("Send test before saving") { Task { await test() } }.disabled(!canSave || saving)
            }
        }
        .farmBackground()
        .navigationTitle("Add provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Add") { Task { await save() } }.disabled(!canSave) }
            }
        }
        .onChange(of: type) { _, _ in config = [:]; testMessage = nil; error = nil }
    }

    private func cleanConfig() -> [String: String] {
        var out: [String: String] = [:]
        for f in fields {
            let v = (config[f.key] ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { out[f.key] = v }
        }
        return out
    }

    private func test() async {
        saving = true
        defer { saving = false }
        testMessage = nil
        error = nil
        do {
            let c = cleanConfig()
            let r = try await session.perform { try await APIClient.shared.testNotificationConfig(type: type, config: c, bearer: $0) }
            testMessage = (r.success ? "Sent: " : "Failed: ") + r.message
            UINotificationFeedbackGenerator().notificationOccurred(r.success ? .success : .error)
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        var fields: [String: AdminJSON] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "provider_type": .string(type),
            "enabled": .bool(true),
            "config": .object(cleanConfig().mapValues { .string($0) }),
        ]
        if let printerId { fields["printer_id"] = .int(printerId) }
        let body = AdminJSON.object(fields)
        do {
            try await session.perform { try await APIClient.shared.createNotificationProvider(body, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
