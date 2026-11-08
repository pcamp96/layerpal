import ActivityKit
import SwiftUI
import UIKit
import UserNotifications

/// Connect to a Bambuddy server once. LayerPal signs in, creates its own
/// read-only API key, and installs this phone's notification webhook, then
/// forgets the password.
struct SettingsView: View {
    var onSaved: () -> Void
    @EnvironmentObject private var push: PushManager

    @State private var url = ServerConfig.serverURL?.absoluteString ?? ""
    @State private var username = ""
    @State private var password = ""
    @StateObject private var twoFA = TwoFactorFlow()
    @State private var useAPIKey = false
    @AppStorage("setup.allowControl") private var allowControl = true
    @State private var manualKey = ""
    @State private var busy = false
    @State private var message: String?
    @State private var webhookInstalled = ServerConfig.webhookInstalledFor != nil
        && ServerConfig.webhookInstalledFor == ServerConfig.serverURL?.absoluteString
    @State private var connected = ServerConfig.serverURL != nil
    @State private var liveActivities = LiveActivityPrefs.enabled
    @FocusState private var focus: Field?

    private enum Field { case url, username, password, code, key }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if connected {
                    Section {
                        LabeledContent("Server", value: ServerConfig.serverURL?.host() ?? url)
                        Button("Change server or sign in again") {
                            connected = false
                            message = nil
                        }
                        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    } header: {
                        Text("Bambuddy")
                    }
                } else {
                Section {
                    TextField("bambuddy.example.com", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focus = useAPIKey ? .key : .username }
                } header: {
                    Text("Bambuddy server")
                } footer: {
                    Text("Use an address your phone can reach away from home, like your own domain or Tailscale.")
                }

                Section {
                    if useAPIKey {
                        SecureField("API key (bb_…)", text: $manualKey)
                            .focused($focus, equals: .key)
                            .submitLabel(.go)
                            .onSubmit(connect)
                    } else if twoFA.isActive {
                        TwoFactorFields(flow: twoFA, server: normalizedURL) { message = $0 }
                    } else {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(connect)
                    }
                    if !useAPIKey, !twoFA.isActive {
                        Toggle("Allow controlling printers and the queue", isOn: $allowControl)
                    }
                    Button(action: connect) {
                        HStack {
                            Text(twoFA.isActive ? "Verify" : "Connect")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || normalizedURL == nil || (twoFA.isActive && !twoFA.canSubmit))
                    if twoFA.isActive {
                        Button("Start over") { twoFA.reset(); message = nil }.disabled(busy)
                    }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                } header: {
                    Text(useAPIKey ? "API key" : "Sign in")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(useAPIKey
                            ? "With an API key, LayerPal can read your printers but can't set up notifications for you. You'll paste the webhook URL below into Bambuddy yourself."
                            : "LayerPal signs in once to create its own read-only key and turn on notifications. Your password isn't saved. Leave it blank if Bambuddy's login is off.")
                        Button(useAPIKey ? "Sign in instead" : "Use an API key instead") {
                            useAPIKey.toggle()
                            twoFA.reset()
                            message = nil
                        }
                        .font(.footnote)
                    }
                }
                }

                Section {
                    row("Notifications allowed", ok: push.authorization == .authorized,
                        detail: push.authorization == .denied ? "Turn them on in iOS Settings → LayerPal." : nil)
                    row("Connected to LayerPal push", ok: push.relayReady)
                    row("Installed in Bambuddy", ok: webhookInstalled,
                        detail: webhookInstalled ? nil : "Connect above, or add the webhook URL in Bambuddy → Settings → Notifications.")
                    Toggle(isOn: $liveActivities) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lock Screen print activity")
                            Text("One card for all active prints. Tap it once for details, again to open LayerPal.")
                                .font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                    .onChange(of: liveActivities) { _, on in Task { await push.setLiveActivitiesEnabled(on) } }
                    if liveActivities {
                        row("Live Activities allowed", ok: ActivityAuthorizationInfo().areActivitiesEnabled)
                    }
                    if let error = push.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("Send test notification") {
                        Task {
                            do { try await RelayClient.shared.sendTest(); message = "Test sent." }
                            catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(push.webhookURL == nil)
                    if let webhook = push.webhookURL {
                        Button("Copy webhook URL") { UIPasteboard.general.url = webhook }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Bambuddy sends events to LayerPal's push service, which forwards them to this phone. Print and printer names pass through it; nothing is stored beyond what's needed to deliver them.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("LayerPal \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.caption2).foregroundStyle(Color.textMuted).padding(.bottom, 6)
            }
            .farmBackground()
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
        }
    }

    private var normalizedURL: URL? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        if !text.hasSuffix("/") { text += "/" }
        guard let parsed = URL(string: text), parsed.host() != nil else { return nil }
        return parsed
    }

    private func row(_ title: String, ok: Bool, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            if let detail, !ok { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func connect() {
        guard let server = normalizedURL else { return }
        focus = nil
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                var bearer: String?
                var canInstall = false

                if useAPIKey {
                    ServerConfig.apiKey = manualKey
                } else if let pending = twoFA.preAuthToken {
                    bearer = try await APIClient.shared.verifyTwoFactor(server: server, preAuthToken: pending, code: twoFA.trimmedCode,
                                                                        method: twoFA.method.rawValue)
                    twoFA.reset()
                } else if try await APIClient.shared.authStatus(server: server).authEnabled {
                    let result = try await APIClient.shared.login(server: server, username: username, password: password)
                    if result.requires2fa == true, let pre = result.preAuthToken {
                        twoFA.begin(preAuthToken: pre, methods: result.twoFaMethods)
                        password = ""
                        message = nil
                        return
                    }
                    bearer = result.accessToken
                } else {
                    ServerConfig.apiKey = nil
                    canInstall = true // login is off; Bambuddy accepts setup calls without auth
                }

                if let bearer {
                    ServerConfig.apiKey = try await APIClient.shared.createAppKey(server: server, bearer: bearer,
                                                                                    deviceName: UIDevice.current.name,
                                                                                    allowControl: allowControl)
                    canInstall = true
                }
                password = ""

                ServerConfig.serverURL = server
                let printers = try await APIClient.shared.printers()
                onSaved()

                guard let webhook = await push.ensureWebhookURL() else {
                    message = "Connected (\(printers.count) printer\(printers.count == 1 ? "" : "s")). Allow notifications to finish setup."
                    connected = true
                    return
                }
                if canInstall {
                    try await APIClient.shared.installWebhook(server: server, bearer: bearer, webhookURL: webhook,
                                                              deviceName: UIDevice.current.name)
                    ServerConfig.webhookInstalledFor = server.absoluteString
                    webhookInstalled = true
                    connected = true
                    // A separate read-only key lets the relay keep the Lock Screen card current.
                    if let bearer {
                        let relayKey = try await APIClient.shared.createAppKey(
                            server: server, bearer: bearer, deviceName: "relay · " + UIDevice.current.name, allowControl: false)
                        try? await RelayClient.shared.setPollCredentials(server: server, apiKey: relayKey)
                    } else {
                        try? await RelayClient.shared.setPollCredentials(server: server, apiKey: RelayClient.noAuth)
                    }
                    message = "All set. \(printers.count) printer\(printers.count == 1 ? "" : "s") found, notifications on."
                } else {
                    message = "Connected. Copy the webhook URL below into Bambuddy → Settings → Notifications → Webhook."
                    connected = true
                }
            } catch {
                if TwoFactorFlow.isExpired(error) {
                    twoFA.reset()
                    message = "Sign-in timed out. Enter your password again."
                } else {
                    message = twoFA.isActive ? AdminError.friendly(error) : error.localizedDescription
                }
            }
        }
    }
}
