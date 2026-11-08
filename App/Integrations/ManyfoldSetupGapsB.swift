import SwiftUI

/// Connect, test and disconnect Manyfold (Bambuddy: Settings > Model sources). Reading the saved connection
/// needs settings:read and every change needs settings:update, which Bambuddy refuses for API keys, so this runs on
/// the sign-in session. The client secret is write-only: it is never shown, and a blank field keeps the saved one.
struct ManyfoldSetupSheet: View {
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionGate(title: "Manyfold connection", permission: "settings:update") {
                ManyfoldSetupForm(onChanged: onChanged)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct ManyfoldSetupForm: View {
    let onChanged: () -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var config: MfyConfig?
    @State private var url = ""
    @State private var clientId = ""
    @State private var secret = ""
    @State private var loaded = false
    @State private var busy: String?
    @State private var message: String?
    @State private var isError = false
    @State private var confirmDisconnect = false

    private var canSave: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && (config?.hasClientSecret == true || !secret.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("Manyfold address", text: $url, prompt: Text("https://manyfold.example.com"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.URL)
                TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(config?.hasClientSecret == true ? "New client secret (blank keeps the saved one)" : "Client secret", text: $secret)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Connection") } footer: {
                Text("Create an OAuth application in Manyfold (Settings > Developer) and paste its client ID and secret. The secret is stored on your Bambuddy server and never shown again.")
            }
            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(isError ? Color.statusError : Color.accentTeal)
                }
            }
            Section {
                Button { Task { await test() } } label: { progressLabel("Test connection", key: "test") }
                    .disabled(busy != nil || !canSave)
                Button { Task { await save() } } label: { progressLabel("Save", key: "save") }
                    .disabled(busy != nil || !canSave)
            }
            if config?.configured == true {
                Section {
                    Button(role: .destructive) { confirmDisconnect = true } label: { progressLabel("Disconnect Manyfold", key: "delete") }
                        .disabled(busy != nil)
                } footer: { Text("Files you already imported stay in the library.") }
            }
        }
        .farmBackground()
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
        .confirmationDialog("Disconnect Manyfold?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
        } message: { Text("The saved address, client ID and secret are removed from Bambuddy.") }
    }

    private func progressLabel(_ title: String, key: String) -> some View {
        HStack { Text(title); if busy == key { Spacer(); ProgressView() } }
    }

    private func load() async {
        do {
            let loadedConfig = try await session.perform { try await APIClient.shared.mfyConfig(bearer: $0) }
            config = loadedConfig
            url = loadedConfig.url
            clientId = loadedConfig.clientId
        } catch { show(AdminError.friendly(error), error: true) }
        loaded = true
    }

    private func secretOrNil() -> String? {
        let trimmed = secret.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func test() async {
        busy = "test"
        defer { busy = nil }
        do {
            let count = try await session.perform {
                try await APIClient.shared.mfyTestConfig(url: url.trimmingCharacters(in: .whitespaces),
                                                         clientId: clientId.trimmingCharacters(in: .whitespaces),
                                                         clientSecret: secretOrNil(), bearer: $0)
            }
            show("Connected. Bambuddy can see \(count) model\(count == 1 ? "" : "s"). Nothing was saved.", error: false)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func save() async {
        busy = "save"
        defer { busy = nil }
        do {
            config = try await session.perform {
                try await APIClient.shared.mfySaveConfig(url: url.trimmingCharacters(in: .whitespaces),
                                                         clientId: clientId.trimmingCharacters(in: .whitespaces),
                                                         clientSecret: secretOrNil(), bearer: $0)
            }
            url = config?.url ?? url
            secret = ""
            show("Saved. Manyfold is connected.", error: false)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onChanged()
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func disconnect() async {
        busy = "delete"
        defer { busy = nil }
        do {
            try await session.perform { try await APIClient.shared.mfyDeleteConfig(bearer: $0) }
            config = nil
            url = ""
            clientId = ""
            secret = ""
            show("Manyfold is disconnected.", error: false)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onChanged()
            await load()
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
