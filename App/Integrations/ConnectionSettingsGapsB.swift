import SwiftUI

/// Home Assistant and Obico address and token editing (Bambuddy: Settings > Network). These are the same
/// keys the web settings page saves through PATCH /settings/ (`ha_enabled`, `ha_url`, `ha_token`,
/// `obico_ml_url`, `obico_ml_token`, `bambuddy_internal_url`), all settings:update, so they run on the sign-in
/// session. Tokens are write-only: the server returns "********" when one is stored, the field starts empty,
/// a blank field keeps the saved token, and nothing is logged or echoed. Bambuddy also refuses to keep a saved
/// token when its address changes, so changing the address means typing the token again.
private let secretPlaceholder = "********"

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

// MARK: - Home Assistant

struct HAConnectionView: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var loaded = false
    @State private var enabled = false
    @State private var url = ""
    @State private var token = ""
    @State private var saved: [String: AdminJSON] = [:]
    @State private var busy: String?
    @State private var message: String?
    @State private var isError = false

    private var urlFromEnv: Bool { saved["ha_url_from_env"]?.bool == true }
    private var tokenFromEnv: Bool { saved["ha_token_from_env"]?.bool == true }
    private var envManaged: Bool { saved["ha_env_managed"]?.bool == true }
    private var hasToken: Bool { !(saved["ha_token"]?.string ?? "").isEmpty }
    private var urlChanged: Bool { trimmed(url) != (saved["ha_url"]?.string ?? "") }
    private var typedToken: String { trimmed(token) }
    /// The saved token can't follow a new address; it has to be typed again.
    private var needsToken: Bool { urlChanged && !urlFromEnv && !tokenFromEnv && typedToken.isEmpty && hasToken }
    private var dirty: Bool { enabled != (saved["ha_enabled"]?.bool ?? false) || urlChanged || !typedToken.isEmpty }
    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Home Assistant", isOn: $enabled).disabled(!canEdit || envManaged)
                TextField("Address", text: $url, prompt: Text("http://192.168.1.100:8123"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!canEdit || urlFromEnv)
                SecureField(hasToken ? "New access token (blank keeps the saved one)" : "Long-lived access token", text: $token)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!canEdit || tokenFromEnv)
            } header: { Text("Connection") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a long-lived access token in Home Assistant under your profile. The token is stored on your Bambuddy server and never shown again.")
                    if urlFromEnv || tokenFromEnv {
                        Text("Part of this is set by environment variables on the server (HA_URL / HA_TOKEN), so it can't be changed here.")
                    }
                    if needsToken { Text("The address changed, so type the token again.").foregroundStyle(Color.statusWarning) }
                }
            }
            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(isError ? Color.statusError : Color.accentTeal)
                }
            }
            if canEdit {
                Section {
                    Button { Task { await test() } } label: { progress("Test connection", key: "test") }
                        .disabled(busy != nil || trimmed(url).isEmpty || (typedToken.isEmpty && (!hasToken || needsToken)))
                    Button { Task { await save() } } label: { progress("Save", key: "save") }
                        .disabled(busy != nil || !dirty || needsToken)
                }
            }
        }
        .farmBackground()
        .navigationTitle("Home Assistant connection")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
    }

    private func progress(_ title: String, key: String) -> some View {
        HStack { Text(title); if busy == key { Spacer(); ProgressView() } }
    }

    private func load() async {
        do {
            saved = try await session.perform { try await APIClient.shared.adminSettings(bearer: $0) }
            enabled = saved["ha_enabled"]?.bool ?? false
            url = saved["ha_url"]?.string ?? ""
            token = ""
        } catch { show(AdminError.friendly(error), error: true) }
        loaded = true
    }

    private func test() async {
        busy = "test"
        defer { busy = nil }
        let sendToken = typedToken.isEmpty ? secretPlaceholder : typedToken
        do {
            let result = try await session.perform { try await APIClient.shared.haTestConnection(url: trimmed(url), token: sendToken, bearer: $0) }
            if result["success"]?.bool == true {
                show(result["message"]?.string ?? "Home Assistant answered.", error: false)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                show(result["error"]?.string ?? "Home Assistant didn't accept the connection.", error: true)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func save() async {
        busy = "save"
        defer { busy = nil }
        var patch: [String: AdminJSON] = [:]
        if !envManaged, enabled != (saved["ha_enabled"]?.bool ?? false) { patch["ha_enabled"] = .bool(enabled) }
        if !urlFromEnv, urlChanged { patch["ha_url"] = .string(trimmed(url)) }
        if !tokenFromEnv, !typedToken.isEmpty { patch["ha_token"] = .string(typedToken) }
        guard !patch.isEmpty else { return }
        do {
            _ = try await session.perform { try await APIClient.shared.patchSettings(patch, bearer: $0) }
            show("Saved.", error: false)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func show(_ text: String, error: Bool) { message = text; isError = error }
}

// MARK: - Obico

struct ObicoConnectionView: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var loaded = false
    @State private var mlURL = ""
    @State private var internalURL = ""
    @State private var token = ""
    @State private var saved: [String: AdminJSON] = [:]
    @State private var busy: String?
    @State private var message: String?
    @State private var isError = false

    private var hasToken: Bool { !(saved["obico_ml_token"]?.string ?? "").isEmpty }
    private var typedToken: String { trimmed(token) }
    private var urlChanged: Bool { trimmed(mlURL) != (saved["obico_ml_url"]?.string ?? "") }
    private var internalChanged: Bool { trimmed(internalURL) != (saved["bambuddy_internal_url"]?.string ?? "") }
    private var needsToken: Bool { urlChanged && typedToken.isEmpty && hasToken }
    private var dirty: Bool { urlChanged || internalChanged || !typedToken.isEmpty }
    private var internalOK: Bool { trimmed(internalURL).isEmpty || trimmed(internalURL).hasPrefix("http://") || trimmed(internalURL).hasPrefix("https://") }
    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        Form {
            Section {
                TextField("ML server address", text: $mlURL, prompt: Text("http://192.168.1.10:3333"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!canEdit)
                SecureField(hasToken ? "New token (blank keeps the saved one)" : "ML API token (optional)", text: $token)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!canEdit)
            } header: { Text("Obico server") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your self-hosted Obico ML API. The token matches the server's ML_API_TOKEN, if you set one. It is never shown again after saving.")
                    if needsToken { Text("The address changed, so type the token again (leave it empty only if the server has none).").foregroundStyle(Color.statusWarning) }
                }
            }
            Section {
                TextField("Bambuddy internal address", text: $internalURL, prompt: Text("http://bambuddy:8000"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!canEdit)
                if !internalOK { Text("The address must start with http:// or https://.").font(.footnote).foregroundStyle(Color.statusError) }
            } header: { Text("Snapshots") } footer: {
                Text("How the Obico server reaches Bambuddy for camera snapshots. Leave empty to use Bambuddy's external address.")
            }
            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(isError ? Color.statusError : Color.accentTeal)
                }
            }
            if canEdit {
                Section {
                    Button { Task { await test() } } label: { progress("Test connection", key: "test") }
                        .disabled(busy != nil || trimmed(mlURL).isEmpty || (needsToken && !hasToken))
                    Button { Task { await save() } } label: { progress("Save", key: "save") }
                        .disabled(busy != nil || !dirty || !internalOK)
                }
            }
        }
        .farmBackground()
        .navigationTitle("Obico connection")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
    }

    private func progress(_ title: String, key: String) -> some View {
        HStack { Text(title); if busy == key { Spacer(); ProgressView() } }
    }

    private func load() async {
        do {
            saved = try await session.perform { try await APIClient.shared.adminSettings(bearer: $0) }
            mlURL = saved["obico_ml_url"]?.string ?? ""
            internalURL = saved["bambuddy_internal_url"]?.string ?? ""
            token = ""
        } catch { show(AdminError.friendly(error), error: true) }
        loaded = true
    }

    private func test() async {
        busy = "test"
        defer { busy = nil }
        // Typed token: tested as entered. Otherwise nil tests the saved token against the saved address only.
        let sendToken: String? = typedToken.isEmpty ? (urlChanged ? "" : nil) : typedToken
        do {
            let r = try await session.perform { try await APIClient.shared.obicoTest(url: trimmed(mlURL), token: sendToken, bearer: $0) }
            let ok = r["ok"]?.bool == true
            if ok, r["auth_ok"]?.bool == false {
                show("Obico answered, but it rejected the token.", error: true)
            } else if ok {
                show("Obico answered.", error: false)
            } else {
                show("Obico test failed: \(r["error"]?.string ?? "no answer").", error: true)
            }
            UINotificationFeedbackGenerator().notificationOccurred(ok && r["auth_ok"]?.bool != false ? .success : .error)
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func save() async {
        busy = "save"
        defer { busy = nil }
        var patch: [String: AdminJSON] = [:]
        if urlChanged { patch["obico_ml_url"] = .string(trimmed(mlURL)) }
        if internalChanged { patch["bambuddy_internal_url"] = .string(trimmed(internalURL)) }
        if !typedToken.isEmpty { patch["obico_ml_token"] = .string(typedToken) }
        guard !patch.isEmpty else { return }
        do {
            _ = try await session.perform { try await APIClient.shared.patchSettings(patch, bearer: $0) }
            show("Saved.", error: false)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            show(AdminError.friendly(error), error: true)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func show(_ text: String, error: Bool) { message = text; isError = error }
}
