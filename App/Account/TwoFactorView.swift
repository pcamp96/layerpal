import CoreImage.CIFilterBuiltins
import SwiftUI

/// Two-factor sign-in (Bambuddy: Profile > Security). Authenticator app (TOTP) with backup codes, and
/// email codes when the server can send mail. Secrets and backup codes live only in view state: shown once,
/// never logged or stored.
struct TwoFactorView: View {
    let username: String
    let email: String?
    @ObservedObject private var session = AdminSession.shared
    @State private var status: AcctTwoFAStatus?
    @State private var error: String?
    @State private var sheet: Sheet?
    @State private var busyEmail = false

    private enum Sheet: Identifiable {
        case setup, regenerate, disableTOTP, emailConfirm(String), emailDisable
        var id: String {
            switch self {
            case .setup: "setup"
            case .regenerate: "regen"
            case .disableTOTP: "disable"
            case .emailConfirm: "emailConfirm"
            case .emailDisable: "emailDisable"
            }
        }
    }

    var body: some View {
        Form {
            if let error { Section { InlineError(message: error) } }
            if let status {
                Section {
                    HStack {
                        Label("Authenticator app", systemImage: "iphone.gen3")
                        Spacer()
                        Pill(text: status.totpEnabled ? "On" : "Off", tint: status.totpEnabled ? .accentTeal : .textMuted)
                    }
                    if status.totpEnabled {
                        LabeledContent("Backup codes left", value: "\(status.backupCodesRemaining)")
                        Button("Get new backup codes") { sheet = .regenerate }
                        Button("Turn off authenticator", role: .destructive) { sheet = .disableTOTP }
                    } else {
                        Button("Set up authenticator app") { sheet = .setup }
                    }
                } header: { Text("Authenticator") } footer: {
                    Text("Works with any TOTP app. To switch to a new authenticator, turn this off and set it up again.")
                }
                Section {
                    HStack {
                        Label("Email code", systemImage: "envelope.badge.fill")
                        Spacer()
                        Pill(text: status.emailOtpEnabled ? "On" : "Off", tint: status.emailOtpEnabled ? .accentTeal : .textMuted)
                    }
                    if status.emailOtpEnabled {
                        Button("Turn off email codes", role: .destructive) { sheet = .emailDisable }
                    } else {
                        Button { Task { await startEmail() } } label: {
                            HStack { Text("Turn on email codes"); if busyEmail { Spacer(); ProgressView() } }
                        }
                        .disabled(busyEmail || (email ?? "").isEmpty)
                    }
                } header: { Text("Email") } footer: {
                    Text((email ?? "").isEmpty
                         ? "Your account has no email address. Ask an admin to add one first."
                         : "Bambuddy emails a 6-digit code at sign-in. The server needs outgoing mail (SMTP) set up.")
                }
            } else if error == nil {
                Section { HStack { Text("Loading"); Spacer(); ProgressView() } }
            }
        }
        .farmBackground()
        .navigationTitle("Two-factor sign-in")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $sheet) { which in
            switch which {
            case .setup:
                TOTPSetupSheet(username: username) { await load() }
            case .regenerate:
                CodePromptSheet(title: "New backup codes", message: "Enter a code from your authenticator app, or an unused backup code. The old codes stop working.",
                                label: "Code", action: "Get new codes", destructive: false, reveals: true) { code in
                    try await session.performKeepingSession { try await APIClient.shared.acctRegenerateBackupCodes(code: code, bearer: $0) }
                } onDone: { await load() }
            case .disableTOTP:
                CodePromptSheet(title: "Turn off authenticator", message: "Enter a code from your authenticator app, or a backup code. You'll sign in with just your password afterwards.",
                                label: "Code", action: "Turn off", destructive: true, reveals: false) { code in
                    try await session.performKeepingSession { try await APIClient.shared.acctTOTPDisable(code: code, bearer: $0) }
                    return []
                } onDone: { await load() }
            case let .emailConfirm(token):
                CodePromptSheet(title: "Confirm email code", message: "Enter the 6-digit code Bambuddy just emailed you. It expires in 10 minutes.",
                                label: "6-digit code", action: "Turn on", destructive: false, reveals: false) { code in
                    try await session.performKeepingSession { try await APIClient.shared.acctEmailConfirm(setupToken: token, code: code, bearer: $0) }
                    return []
                } onDone: { await load() }
            case .emailDisable:
                CodePromptSheet(title: "Turn off email codes", message: "Enter your Bambuddy password to confirm.",
                                label: "Password", action: "Turn off", destructive: true, reveals: false, secure: true) { password in
                    // A wrong password answers 401; keep the session.
                    try await session.performKeepingSession { try await APIClient.shared.acctEmailDisable(password: password, bearer: $0) }
                    return []
                } onDone: { await load() }
            }
        }
    }

    private func load() async {
        do {
            status = try await session.perform { try await APIClient.shared.acct2FAStatus(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func startEmail() async {
        busyEmail = true
        error = nil
        defer { busyEmail = false }
        do {
            let token = try await session.performKeepingSession { try await APIClient.shared.acctEmailEnable(bearer: $0) }
            sheet = .emailConfirm(token)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Code prompt

/// Asks for one code (or password), runs `perform`, and shows any backup codes it returns exactly once.
private struct CodePromptSheet: View {
    let title: String
    let message: String
    let label: String
    let action: String
    let destructive: Bool
    let reveals: Bool
    var secure = false
    let perform: (String) async throws -> [String]
    var onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    @State private var codes: [String]?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Group {
                if let codes {
                    BackupCodesView(codes: codes) { Task { await onDone() }; dismiss() }
                } else {
                    Form {
                        Section {
                            if secure {
                                SecureField(label, text: $value).textContentType(.password)
                            } else {
                                TextField(label, text: $value)
                                    .keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled()
                                    .textContentType(.oneTimeCode)
                            }
                        } footer: { Text(message) }
                        if let error { Section { InlineError(message: error) } }
                        Section {
                            Button(action, role: destructive ? .destructive : nil) {
                                if destructive { confirm = true } else { Task { await submit() } }
                            }
                            .disabled(busy || value.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .farmBackground()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if codes == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .confirmationDialog("\(title)?", isPresented: $confirm, titleVisibility: .visible) {
                Button(action, role: .destructive) { Task { await submit() } }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(codes != nil)
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await perform(value.trimmingCharacters(in: .whitespaces))
            value = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if reveals, !result.isEmpty {
                codes = result
            } else {
                await onDone()
                dismiss()
            }
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - TOTP setup

private struct TOTPSetupSheet: View {
    let username: String
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var setup: AcctTOTPSetup?
    @State private var qr: UIImage?
    @State private var uri: URL?
    @State private var code = ""
    @State private var codes: [String]?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let codes {
                    BackupCodesView(codes: codes) { Task { await onDone() }; dismiss() }
                } else {
                    form
                }
            }
            .navigationTitle("Authenticator app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if codes == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(codes != nil)
        .task { await start() }
    }

    private var form: some View {
        Form {
            if let setup {
                Section {
                    if let qr {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 240).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("QR code for your authenticator app")
                    }
                    if let uri { Link("Open in authenticator app", destination: uri) }
                } header: { Text("1. Scan this code") } footer: {
                    Text("Or add it by hand with the key below. The key appears only now.")
                }
                Section("Setup key") {
                    HStack {
                        Text(grouped(setup.secret)).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { copySecretToClipboard(setup.secret) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).accessibilityLabel("Copy setup key")
                    }
                }
                Section {
                    TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                } header: { Text("2. Enter the code it shows") }
                if let error { Section { InlineError(message: error) } }
                Section {
                    Button { Task { await enable() } } label: {
                        HStack { Text("Turn on"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(busy || code.count != 6)
                }
            } else if let error {
                Section { InlineError(message: error) }
                Section { Button("Try again") { Task { await start() } } }
            } else {
                Section { HStack { Text("Preparing"); Spacer(); ProgressView() } }
            }
        }
        .farmBackground()
    }

    private func grouped(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { i in
            String(secret.dropFirst(i).prefix(4))
        }.joined(separator: " ")
    }

    private func start() async {
        error = nil
        do {
            let result = try await session.performKeepingSession { try await APIClient.shared.acctTOTPSetup(code: nil, bearer: $0) }
            var c = URLComponents()
            c.scheme = "otpauth"
            c.host = "totp"
            c.path = "/\(result.issuer):\(username)"
            c.queryItems = [URLQueryItem(name: "secret", value: result.secret), URLQueryItem(name: "issuer", value: result.issuer)]
            uri = c.url
            qr = c.url.flatMap { QRCodeImage.make(from: $0.absoluteString) }
            setup = result
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func enable() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let entered = code
            codes = try await session.performKeepingSession { try await APIClient.shared.acctTOTPEnable(code: entered, bearer: $0) }
            code = ""
            setup = nil
            qr = nil
            uri = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Backup codes (shown once)

private struct BackupCodesView: View {
    let codes: [String]
    var finished: () -> Void
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                ForEach(codes, id: \.self) { code in
                    Text(code).font(.body.monospaced()).textSelection(.enabled)
                }
            } header: { Text("Backup codes") } footer: {
                Text("Each code works once if you lose your authenticator. This is the only time they're shown, so save them somewhere safe now.")
            }
            Section {
                Button { copySecretToClipboard(codes.joined(separator: "\n")); copied = true } label: {
                    Label(copied ? "Copied for 2 minutes" : "Copy all", systemImage: "doc.on.doc")
                }
                ShareLink(item: codes.joined(separator: "\n"), subject: Text("Bambuddy backup codes")) {
                    Label("Share or save", systemImage: "square.and.arrow.up")
                }
            }
            Section {
                Toggle("I've saved these codes", isOn: $saved)
                Button("Done", action: finished).disabled(!saved)
            }
        }
        .farmBackground()
        .navigationBarBackButtonHidden()
    }
}

// MARK: - QR

enum QRCodeImage {
    /// Draws `text` as a QR code on this device with CoreImage; nothing is sent anywhere.
    static func make(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
