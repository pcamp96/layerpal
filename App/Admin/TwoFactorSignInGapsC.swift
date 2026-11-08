import SwiftUI
import UIKit

/// State for the second step of a Bambuddy sign-in, shared by the onboarding screen and the admin
/// sign-in sheet. Login answers with `requires_2fa`, a `pre_auth_token` and `two_fa_methods`
/// (totp, email, backup). Emailing a code swaps in a fresh token, so the token lives here.
/// Codes are never logged or stored.
@MainActor
final class TwoFactorFlow: ObservableObject {
    enum Method: String, CaseIterable, Identifiable {
        case totp, email, backup
        var id: String { rawValue }

        var label: String {
            switch self {
            case .totp: "Authenticator"
            case .email: "Email"
            case .backup: "Backup code"
            }
        }

        var maxLength: Int { self == .backup ? 8 : 6 }
    }

    @Published private(set) var preAuthToken: String?
    @Published private(set) var methods: [Method] = []
    @Published var method: Method = .totp {
        didSet { if method != oldValue { code = "" } }
    }
    @Published var code = ""
    @Published private(set) var emailSent = false
    @Published private(set) var sending = false
    @Published private(set) var canResend = true
    @Published var notice: String?

    private var resendTask: Task<Void, Never>?

    var isActive: Bool { preAuthToken != nil }

    /// Starts (or restarts) the challenge from a login response. An older server that sends no
    /// method list only ever offered an authenticator code.
    func begin(preAuthToken: String, methods raw: [String]?) {
        let parsed = (raw ?? []).compactMap(Method.init(rawValue:))
        methods = parsed.isEmpty ? [.totp] : parsed
        method = methods.contains(.totp) ? .totp : (methods.first ?? .totp)
        self.preAuthToken = preAuthToken
        code = ""
        emailSent = false
        canResend = true
        notice = nil
    }

    func reset() {
        resendTask?.cancel()
        preAuthToken = nil
        methods = []
        code = ""
        emailSent = false
        canResend = true
        notice = nil
    }

    /// The code as the server wants it: trimmed; backup codes are case-insensitive.
    var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSubmit: Bool {
        guard isActive else { return false }
        if method == .email, !emailSent { return false }
        return trimmedCode.count >= 6
    }

    /// True when a verify/send failed because the login's challenge ran out (about 5 minutes), so the
    /// only way forward is signing in again.
    static func isExpired(_ error: Error) -> Bool {
        if case let APIError.http(401, body) = error { return body.localizedCaseInsensitiveContains("pre-auth token") }
        return false
    }

    /// Emails a code and keeps the replacement token. Returns an error message, or nil on success.
    func sendEmail(server: URL?) async -> String? {
        guard let token = preAuthToken, !sending else { return nil }
        sending = true
        notice = nil
        defer { sending = false }
        do {
            preAuthToken = try await APIClient.shared.sendEmailTwoFactorCode(preAuthToken: token, server: server)
            emailSent = true
            code = ""
            notice = "Code sent. It's good for a few minutes."
            canResend = false
            resendTask?.cancel()
            resendTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { self?.canResend = true }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return Self.isExpired(error) ? "Sign-in timed out. Start over." : AdminError.friendly(error)
        }
    }
}

/// Rows for a Form section: method picker (when the account has more than one), instructions, the
/// code field, and the email send/resend button.
struct TwoFactorFields: View {
    @ObservedObject var flow: TwoFactorFlow
    /// nil = the configured server (admin sheet); onboarding passes the address being set up.
    var server: URL?
    var onError: (String) -> Void
    @FocusState private var codeFocused: Bool

    var body: some View {
        if flow.methods.count > 1 {
            Picker("Method", selection: $flow.method) {
                ForEach(flow.methods) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Verification method")
        }
        Text(instructions).font(.footnote).foregroundStyle(Color.textSecondary)
        if flow.method == .email {
            Button {
                Task {
                    if let message = await flow.sendEmail(server: server) { onError(message) } else { codeFocused = true }
                }
            } label: {
                HStack {
                    Text(flow.emailSent ? "Send a new code" : "Email me a code")
                    if flow.sending { Spacer(); ProgressView() }
                }
            }
            .disabled(flow.sending || (flow.emailSent && !flow.canResend))
        }
        if let notice = flow.notice { Text(notice).font(.footnote).foregroundStyle(Color.textSecondary) }
        TextField(flow.method == .backup ? "8-character backup code" : "6-digit code", text: $flow.code)
            .keyboardType(flow.method == .backup ? .asciiCapable : .numberPad)
            .textContentType(flow.method == .backup ? nil : .oneTimeCode)
            .textInputAutocapitalization(flow.method == .backup ? .characters : .never)
            .autocorrectionDisabled()
            .focused($codeFocused)
            .disabled(flow.method == .email && !flow.emailSent)
            .onChange(of: flow.code) { _, new in
                let limit = flow.method.maxLength
                if new.count > limit { flow.code = String(new.prefix(limit)) }
            }
            .onAppear { codeFocused = flow.method != .email }
            .onChange(of: flow.method) { _, new in codeFocused = new != .email }
    }

    private var instructions: String {
        switch flow.method {
        case .totp: "Type the 6-digit code shown in your authenticator app."
        case .email:
            flow.emailSent
                ? "Enter the 6-digit code Bambuddy emailed you."
                : "Bambuddy will email a 6-digit code to the address on your account."
        case .backup: "Enter one of your 8-character backup codes. Each one works once."
        }
    }
}
