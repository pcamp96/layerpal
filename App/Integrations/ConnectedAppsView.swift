import SwiftUI

/// Connected apps (Bambuddy: Settings > Connected apps). Registers external apps that sign users in with
/// Bambuddy (OAuth code flow with PKCE). Managing them needs `settings:update` and an admin account, and
/// creating one needs Bambuddy's login switched on. The client secret is shown once, on create or rotate.
struct ConnectedAppsView: View {
    var body: some View {
        SessionGate(title: "Connected apps", permission: "settings:update", needsLogin: true) { AppsContent() }
    }
}

private struct AppsContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var apps: [SetupConnectedApp] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false
    @State private var secret: SetupConnectedApp?
    @State private var pendingDelete: SetupConnectedApp?
    @State private var pendingRotate: SetupConnectedApp?

    var body: some View {
        Group {
            if session.me?.isAdmin == false {
                ContentUnavailableView("Admins only", systemImage: "lock.fill",
                                       description: Text("Bambuddy only lets administrators register connected apps."))
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if let error { Section { InlineError(message: error) } }
            ForEach(apps) { app in
                NavigationLink {
                    AppEditor(app: app, onRotate: { pendingRotate = app }, onDelete: { pendingDelete = app }) { await load() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Pill(text: app.enabled ? "On" : "Off", tint: app.enabled ? .accentTeal : .textMuted)
                        }
                        Text(app.redirectUri).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                        Text(app.lastUsedAt.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                            .font(.caption).foregroundStyle(Color.textMuted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, apps.isEmpty, error == nil {
                ContentUnavailableView("No connected apps", systemImage: "app.connected.to.app.below.fill",
                                       description: Text("Register an app that should sign users in with Bambuddy, using +."))
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Register app")
            }
        }
        .sheet(isPresented: $creating) { CreateAppSheet { created in secret = created; await load() } }
        .sheet(item: $secret) { SecretSheet(app: $0) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "app")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete app", role: .destructive) { if let a = pendingDelete { delete(a) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The app can no longer sign anyone in, and its granted access is removed.") }
        .confirmationDialog("Make a new secret for \(pendingRotate?.name ?? "app")?",
                            isPresented: Binding(get: { pendingRotate != nil }, set: { if !$0 { pendingRotate = nil } }),
                            titleVisibility: .visible) {
            Button("Replace secret", role: .destructive) { if let a = pendingRotate { rotate(a) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current secret stops working immediately. Update the app with the new one.") }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            apps = try await session.perform { try await APIClient.shared.appsList(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func delete(_ app: SetupConnectedApp) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.appsDelete(app.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
            pendingDelete = nil
        }
    }

    private func rotate(_ app: SetupConnectedApp) {
        Task {
            do {
                secret = try await session.perform { try await APIClient.shared.appsRotate(app.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = AdminError.friendly(error)
            }
            pendingRotate = nil
        }
    }
}

private func validCallback(_ text: String) -> Bool {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
    return ["http", "https"].contains(scheme) && url.host != nil && url.fragment == nil && url.user == nil
}

private struct CreateAppSheet: View {
    var created: (SetupConnectedApp) async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var callback = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("https://app.example.com/callback", text: $callback).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("The callback URL must match exactly what the app sends, with no #fragment. Plain http works on a home network.")
                }
                if let error { Section { InlineError(message: error) } }
            }
            .farmBackground()
            .navigationTitle("Register app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Add") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !validCallback(callback))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let n = name.trimmingCharacters(in: .whitespaces), c = callback.trimmingCharacters(in: .whitespaces)
            let app = try await session.perform { try await APIClient.shared.appsCreate(name: n, redirectURI: c, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            // Let this sheet finish closing before the secret sheet opens.
            try? await Task.sleep(for: .milliseconds(500))
            await created(app)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

private struct AppEditor: View {
    let app: SetupConnectedApp
    var onRotate: () -> Void
    var onDelete: () -> Void
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var callback = ""
    @State private var enabled = true
    @State private var ready = false
    @State private var busy = false
    @State private var error: String?

    private var changed: Bool { name != app.name || callback != app.redirectUri || enabled != app.enabled }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Callback URL", text: $callback).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Allow sign-in", isOn: $enabled)
            }
            Section("Client ID") {
                Text(app.clientId).font(.callout.monospaced()).textSelection(.enabled)
            }
            if let error { Section { InlineError(message: error) } }
            Section {
                Button("Replace client secret") { dismiss(); onRotate() }
                Button("Delete app", role: .destructive) { dismiss(); onDelete() }
            } footer: { Text("The secret isn't stored anywhere you can read it. Replacing it shows a new one once.") }
        }
        .farmBackground()
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!changed || name.trimmingCharacters(in: .whitespaces).isEmpty || !validCallback(callback))
                }
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            name = app.name
            callback = app.redirectUri
            enabled = app.enabled
        }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let n = name.trimmingCharacters(in: .whitespaces), c = callback.trimmingCharacters(in: .whitespaces), e = enabled
            try await session.perform {
                try await APIClient.shared.appsUpdate(app.id, name: n != app.name ? n : nil, redirectURI: c != app.redirectUri ? c : nil,
                                                      enabled: e != app.enabled ? e : nil, bearer: $0)
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

/// Shows client id and secret once.
private struct SecretSheet: View {
    let app: SetupConnectedApp
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Client ID") { Text(app.clientId).font(.callout.monospaced()).textSelection(.enabled) }
                Section {
                    Text(app.clientSecret ?? "").font(.callout.monospaced()).textSelection(.enabled)
                    Button { copySecretToClipboard(app.clientSecret ?? "") } label: { Label("Copy secret", systemImage: "doc.on.doc") }
                } header: { Text("Client secret") } footer: {
                    Text("This is the only time the secret is shown. Put it in the app's settings now.")
                }
                Section {
                    Toggle("I've saved the secret", isOn: $saved)
                    Button("Done") { dismiss() }.disabled(!saved)
                }
            }
            .farmBackground()
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(!saved)
    }
}
