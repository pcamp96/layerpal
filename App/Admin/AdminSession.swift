import Security
import SwiftUI

/// Bambuddy refuses API keys for admin-only permissions, so admin screens use a
/// real login. The JWT lives in the keychain (never the password), with its
/// expiry; when it lapses or the server answers 401 the user signs in again.
@MainActor
final class AdminSession: ObservableObject {
    static let shared = AdminSession()

    @Published private(set) var token: String?
    @Published private(set) var username: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var me: Me?
    /// nil until `refreshStatus()` has answered.
    @Published private(set) var authEnabled: Bool?
    @Published var showSignIn = false

    private init() {
        if let stored = AdminKeychain.load(), stored.expiresAt > Date() {
            token = stored.token
            username = stored.username
            expiresAt = stored.expiresAt
        } else {
            AdminKeychain.clear()
        }
    }

    /// True when no login is needed (auth disabled) or a live JWT is held.
    var isReady: Bool { authEnabled == false || isSignedIn }

    var isSignedIn: Bool {
        guard token != nil, let expiresAt else { return false }
        return expiresAt > Date()
    }

    /// With auth off, `nil` falls back to the app key, which Bambuddy then accepts.
    var bearer: String? { isSignedIn ? token : nil }

    func can(_ permission: String) -> Bool {
        if authEnabled == false { return true }
        guard isSignedIn else { return false }
        guard let me else { return true } // not loaded yet; the server still enforces
        return me.isAdmin == true || (me.permissions ?? []).contains(permission)
    }

    var expiryText: String {
        guard let expiresAt else { return "" }
        let seconds = expiresAt.timeIntervalSinceNow
        if seconds <= 0 { return "expired" }
        let hours = Int((seconds / 3600).rounded(.up))
        return hours >= 2 ? "expires in \(hours) h" : "expires in \(max(1, Int((seconds / 60).rounded(.up)))) min"
    }

    func refreshStatus() async {
        guard let server = ServerConfig.serverURL else { return }
        if let status = try? await APIClient.shared.authStatus(server: server) { authEnabled = status.authEnabled }
        if isSignedIn, me == nil, let token { me = try? await APIClient.shared.adminMe(bearer: token) }
    }

    enum Outcome { case signedIn, needsCode(preAuthToken: String, methods: [String]?) }

    func signIn(username: String, password: String) async throws -> Outcome {
        let result = try await APIClient.shared.adminLogin(username: username.trimmingCharacters(in: .whitespaces), password: password)
        if result.requires2fa == true, let pre = result.preAuthToken { return .needsCode(preAuthToken: pre, methods: result.twoFaMethods) }
        guard let jwt = result.accessToken else { throw AdminError.message("Bambuddy didn't return a session. Check the username and password.") }
        await adopt(jwt, fallbackName: result.user?.username ?? username)
        return .signedIn
    }

    func verify(preAuthToken: String, code: String, method: String = "totp") async throws {
        let result = try await APIClient.shared.adminVerify(preAuthToken: preAuthToken, code: code.trimmingCharacters(in: .whitespaces), method: method)
        guard let jwt = result.accessToken else { throw AdminError.message("Bambuddy didn't return a session.") }
        await adopt(jwt, fallbackName: result.user?.username ?? "")
    }

    private func adopt(_ jwt: String, fallbackName: String) async {
        let expiry = AdminJWT.expiry(of: jwt) ?? Date().addingTimeInterval(24 * 3600)
        let name = AdminJWT.subject(of: jwt) ?? fallbackName
        token = jwt
        username = name
        expiresAt = expiry
        AdminKeychain.save(.init(token: jwt, username: name, expiresAt: expiry))
        me = try? await APIClient.shared.adminMe(bearer: jwt)
        if let user = me?.username { username = user }
        showSignIn = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func signOut() {
        if let token { Task { await APIClient.shared.adminLogout(bearer: token) } }
        clear()
    }

    private func clear() {
        token = nil
        username = nil
        expiresAt = nil
        me = nil
        AdminKeychain.clear()
    }

    /// Runs an admin call with the session's bearer. A 401 ends the session and re-prompts.
    func perform<T>(_ operation: (String?) async throws -> T) async throws -> T {
        if authEnabled == nil { await refreshStatus() }
        if authEnabled != false, !isSignedIn {
            clear()
            showSignIn = true
            throw AdminError.signInRequired
        }
        do {
            return try await operation(bearer)
        } catch APIError.http(401, _) where authEnabled != false {
            clear()
            showSignIn = true
            throw AdminError.signInRequired
        }
    }
}

// MARK: - JWT

enum AdminJWT {
    private static func payload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(of jwt: String) -> Date? {
        (payload(jwt)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    static func subject(of jwt: String) -> String? { payload(jwt)?["sub"] as? String }
}

// MARK: - Keychain

enum AdminKeychain {
    struct Stored: Codable { let token: String; let username: String; let expiresAt: Date }

    private static var service: String { "\(ServerConfig.bundleBase).adminsession" }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
           !prefix.isEmpty, !prefix.hasPrefix("$(") {
            query[kSecAttrAccessGroup as String] = "\(prefix)\(ServerConfig.bundleBase).shared"
        }
        return query
    }

    static func load() -> Stored? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func save(_ stored: Stored) {
        clear()
        guard let data = try? JSONEncoder().encode(stored) else { return }
        var query = baseQuery()
        query[kSecValueData as String] = data
        // This device only: an admin session shouldn't ride along in a backup.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(baseQuery() as CFDictionary) }
}

// MARK: - Gate

/// Wraps an admin screen: shows its content once a session exists (or auth is
/// off) and the account holds `permission`; otherwise a "Sign in to manage" card.
struct AdminGate<Content: View>: View {
    var title: String
    var permission: String?
    @ViewBuilder var content: Content
    @ObservedObject private var session = AdminSession.shared

    var body: some View {
        Group {
            if session.authEnabled == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !session.isReady {
                signInCard
            } else if let permission, !session.can(permission) {
                ContentUnavailableView("Not available for your account", systemImage: "lock.fill",
                                       description: Text("Your Bambuddy account doesn't have \(permission)."))
            } else {
                content
            }
        }
        .background(Color.bgPrimary)
        .navigationTitle(title)
        .task { await session.refreshStatus() }
        .sheet(isPresented: $session.showSignIn) { AdminSignInSheet() }
    }

    private var signInCard: some View {
        ScrollView {
            Card {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(Color.accentTeal)
                    Text("Sign in to manage").font(.headline)
                    Text("Bambuddy only lets a signed-in admin change \(title.lowercased()). LayerPal keeps your session on this iPhone, never your password.")
                        .font(.subheadline).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
                    Button { session.showSignIn = true } label: {
                        Text("Sign in").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.accentTeal)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }
}

// MARK: - Sign-in sheet

struct AdminSignInSheet: View {
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var twoFA = TwoFactorFlow()
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case user, pass }

    var body: some View {
        NavigationStack {
            Form {
                if !twoFA.isActive {
                    Section {
                        TextField("Username", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .user)
                        SecureField("Password", text: $password)
                            .textContentType(.password).focused($focus, equals: .pass)
                    } footer: {
                        Text("Your Bambuddy login. The password is used once to get a session and is not stored.")
                    }
                } else {
                    Section {
                        TwoFactorFields(flow: twoFA, server: nil) { error = $0 }
                    } header: {
                        Text("Two-step verification")
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                }
                Section {
                    Button { Task { await submit() } } label: {
                        HStack {
                            Text(twoFA.isActive ? "Verify" : "Sign in")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || (twoFA.isActive ? !twoFA.canSubmit : username.isEmpty || password.isEmpty))
                    if twoFA.isActive {
                        Button("Start over") { twoFA.reset(); error = nil }.disabled(busy)
                    }
                }
            }
            .farmBackground()
            .navigationTitle("Sign in to Bambuddy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.showSignIn = false; dismiss() } } }
            .onAppear { focus = .user }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if let pre = twoFA.preAuthToken {
                try await session.verify(preAuthToken: pre, code: twoFA.trimmedCode, method: twoFA.method.rawValue)
                password = ""
                twoFA.reset()
                dismiss()
            } else {
                switch try await session.signIn(username: username, password: password) {
                case .signedIn:
                    password = ""
                    dismiss()
                case let .needsCode(pre, methods):
                    twoFA.begin(preAuthToken: pre, methods: methods)
                    password = ""
                }
            }
        } catch {
            if TwoFactorFlow.isExpired(error) {
                twoFA.reset()
                self.error = "Sign-in timed out. Enter your password again."
            } else {
                self.error = AdminError.friendly(error)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Session row (More > Admin)

struct AdminSessionRow: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var confirmSignOut = false
    @State private var presentSignIn = false

    var body: some View {
        Group {
            if session.authEnabled == false {
                row(title: "Bambuddy login is off", detail: "Admin screens need no sign-in.", symbol: "lock.open.fill", tint: .statusWarning)
            } else if session.isSignedIn {
                HStack {
                    row(title: "Signed in as \(session.username ?? "admin")",
                        detail: session.expiryText, symbol: "person.badge.key.fill", tint: .accentTeal)
                    Spacer()
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .buttonStyle(.borderless).font(.subheadline)
                }
            } else {
                Button { presentSignIn = true } label: {
                    row(title: "Sign in as admin", detail: "Needed to manage printers, users and settings.", symbol: "lock.fill", tint: .textMuted)
                }
                .foregroundStyle(.primary)
            }
        }
        .task { await session.refreshStatus() }
        .confirmationDialog("Sign out of Bambuddy admin?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { session.signOut() }
        }
        .sheet(isPresented: $presentSignIn) { AdminSignInSheet() }
        .accessibilityElement(children: .contain)
    }

    private func row(title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.textMuted) }
            }
        }
    }
}
