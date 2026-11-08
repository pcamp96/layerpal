import SwiftUI

/// Bambu Cloud and Orca Cloud sign-in (Bambuddy: Cloud profiles). Bambu Cloud needs `cloud:auth` (admin-level);
/// Orca Cloud needs `orca_cloud:auth`. The Bambu password is sent once and never stored or logged; Bambuddy
/// keeps the resulting cloud token, not this app.
struct CloudAccountsView: View {
    var body: some View {
        SessionGate(title: "Cloud accounts") { CloudContent() }
    }
}

private struct CloudContent: View {
    @ObservedObject private var session = AdminSession.shared

    var body: some View {
        Form {
            if session.can("cloud:auth") { BambuCloudSection() }
            if session.can("orca_cloud:auth") { OrcaCloudSection() }
            if !session.can("cloud:auth"), !session.can("orca_cloud:auth") {
                Section { Text("Your Bambuddy account doesn't have cloud:auth or orca_cloud:auth.").font(.footnote) }
            }
        }
        .farmBackground()
    }
}

// MARK: - Bambu Cloud

private struct BambuCloudSection: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var status: SetupCloudStatus?
    @State private var email = ""
    @State private var password = ""
    @State private var region = "global"
    @State private var code = ""
    @State private var pending: SetupCloudLogin?
    @State private var busy = false
    @State private var error: String?
    @State private var captcha = false
    @State private var confirmLogout = false

    var body: some View {
        Section {
            if let status, status.isAuthenticated {
                LabeledContent("Signed in as", value: status.email ?? "Bambu account")
                if let region = status.region { LabeledContent("Region", value: region == "china" ? "China" : "Global") }
                Button("Sign out of Bambu Cloud", role: .destructive) { confirmLogout = true }.disabled(busy)
            } else if pending == nil {
                if status?.signInExpired == true {
                    Text("Your Bambu Cloud sign-in expired. Sign in again.").font(.footnote).foregroundStyle(Color.statusWarning)
                }
                TextField("Bambu account email", text: $email).textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
                Picker("Region", selection: $region) { Text("Global").tag("global"); Text("China").tag("china") }
                Button { Task { await login() } } label: {
                    HStack { Text("Sign in"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
            } else if let pending {
                Text(pending.message ?? "One more step: type the verification code to finish signing in.").font(.footnote).foregroundStyle(Color.textSecondary)
                TextField(pending.verificationType == "totp" ? "Authenticator code" : "Emailed code", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                Button { Task { await verify(pending) } } label: {
                    HStack { Text("Verify"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || code.count < 4)
                Button("Start over", role: .cancel) { self.pending = nil; code = "" }.disabled(busy)
            } else {
                HStack { Text("Loading"); Spacer(); ProgressView() }
            }
            if captcha {
                Text("Bambu is asking this network to pass a captcha, so no password will work right now. Try again later, or sign in from Bambuddy on a different network.")
                    .font(.footnote).foregroundStyle(Color.statusWarning)
            }
            InlineError(message: error)
        } header: { Text("Bambu Cloud") } footer: {
            Text("Used for cloud slicer presets and firmware info. Your password goes straight to Bambu and isn't kept.")
        }
        .task { await load() }
        .confirmationDialog("Sign out of Bambu Cloud?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await logout() } }
        } message: { Text("Bambuddy forgets the cloud token. Cloud presets stay unavailable until you sign in again.") }
    }

    private func load() async {
        do {
            status = try await session.perform { try await APIClient.shared.cloudStatus(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func login() async {
        busy = true
        error = nil
        captcha = false
        defer { busy = false }
        do {
            let mail = email.trimmingCharacters(in: .whitespaces), pass = password, reg = region
            // 401 here means wrong Bambu credentials, not an expired Bambuddy session.
            let result = try await session.performKeepingSession { try await APIClient.shared.cloudLogin(email: mail, password: pass, region: reg, bearer: $0) }
            password = ""
            try await handle(result)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func verify(_ login: SetupCloudLogin) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let mail = email.trimmingCharacters(in: .whitespaces), entered = code, reg = region
            let key = login.verificationType == "totp" ? login.tfaKey : nil
            let result = try await session.performKeepingSession {
                try await APIClient.shared.cloudVerify(email: mail, code: entered, tfaKey: key, region: reg, bearer: $0)
            }
            code = ""
            try await handle(result)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func handle(_ result: SetupCloudLogin) async throws {
        if result.reason == "captcha" { captcha = true }
        if result.success {
            pending = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } else if result.needsVerification == true {
            pending = result
        } else {
            error = result.message ?? "Bambu Cloud didn't accept that."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func logout() async {
        do {
            try await session.perform { try await APIClient.shared.cloudLogout(bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await load()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}

// MARK: - Orca Cloud

private struct OrcaCloudSection: View {
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.openURL) private var openURL
    @State private var status: SetupOrcaStatus?
    @State private var pairing: SetupOrcaStart?
    @State private var waitingText: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmLogout = false

    var body: some View {
        Section {
            if let status, status.connected {
                LabeledContent("Status", value: "Connected")
                if let id = status.userId { LabeledContent("Account", value: id) }
                Button("Sign out of Orca Cloud", role: .destructive) { confirmLogout = true }
            } else if let pairing {
                VStack(spacing: 8) {
                    Text("Confirm this code on Orca Cloud").font(.footnote).foregroundStyle(Color.textSecondary)
                    Text(pairing.userCode).font(.system(.largeTitle, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        .accessibilityLabel("Pairing code \(pairing.userCode.map(String.init).joined(separator: " "))")
                    if let url = safeURL(pairing.verificationUriComplete) ?? safeURL(pairing.verificationUri) {
                        Button { openURL(url) } label: { Label("Open approval page", systemImage: "safari") }.buttonStyle(.borderedProminent).tint(.accentTeal)
                    }
                    HStack(spacing: 8) { ProgressView(); Text(waitingText ?? "Waiting for approval").font(.footnote).foregroundStyle(Color.textMuted) }
                }
                .frame(maxWidth: .infinity)
                Button("Cancel", role: .cancel) { stopPairing() }
            } else if status != nil {
                Button { Task { await start() } } label: {
                    HStack { Text("Sign in with Orca Cloud"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy)
            } else if error == nil {
                HStack { Text("Loading"); Spacer(); ProgressView() }
            }
            InlineError(message: error)
        } header: { Text("Orca Cloud") } footer: {
            Text("Pair Bambuddy with your Orca Cloud account to use its profiles. Approve the code on the Orca Cloud page; no password is entered here.")
        }
        .task { await load() }
        .onDisappear { pollTask?.cancel() }
        .confirmationDialog("Sign out of Orca Cloud?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await logout() } }
        } message: { Text("Bambuddy forgets the Orca Cloud token. You can revoke it on Orca Cloud too.") }
    }

    private func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private func load() async {
        do {
            status = try await session.perform { try await APIClient.shared.orcaStatus(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func start() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let started = try await session.perform { try await APIClient.shared.orcaStart(bearer: $0) }
            pairing = started
            waitingText = nil
            poll(started)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func stopPairing() {
        pollTask?.cancel()
        pairing = nil
    }

    private func poll(_ started: SetupOrcaStart) {
        pollTask?.cancel()
        pollTask = Task {
            var wait = max(started.interval, 2)
            let deadline = Date().addingTimeInterval(Double(started.expiresIn))
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                do {
                    let r = try await session.perform { try await APIClient.shared.orcaPoll(bearer: $0) }
                    switch r.status {
                    case "complete":
                        pairing = nil
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        await load()
                        return
                    case "slow_down":
                        wait += 5
                    case "access_denied":
                        pairing = nil
                        error = "The request was denied on Orca Cloud."
                        return
                    case "expired_token":
                        pairing = nil
                        error = "The code expired. Start again."
                        return
                    default:
                        waitingText = "Waiting for approval"
                    }
                } catch {
                    pairing = nil
                    self.error = AdminError.friendly(error)
                    return
                }
            }
            if !Task.isCancelled { pairing = nil; error = "The code expired. Start again." }
        }
    }

    private func logout() async {
        do {
            try await session.perform { try await APIClient.shared.orcaLogout(bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await load()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}
