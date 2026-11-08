import Security
import SwiftUI
import UIKit

/// The stream overlay page (`{server}/overlay/{printerId}`) is a standalone web page: with Bambuddy's login on it
/// has no JWT in Safari, so it reads everything through an `overlay`-scoped long-lived token in the URL
/// (`?token=...`, which the overlay page accepts in place of a login). The server only shows a
/// token's plaintext once, so LayerPal mints one on demand (POST /auth/tokens, scope "overlay", needs camera:view
/// and the sign-in session), keeps it in this device's Keychain, and reuses it until it is nearly expired. With
/// Bambuddy's login off the overlay needs no token and the plain URL is used.
@MainActor
enum OverlayLink {
    /// Minted tokens last 30 days; one with less than 2 days left is replaced.
    private static let lifetimeDays = 30
    private static let renewBefore: TimeInterval = 2 * 24 * 3600

    enum Resolution {
        case ready(URL)
        /// A token has to be created first (ask the user, then call `create`).
        case needsToken
    }

    /// Resolves what can be done without side effects: a plain URL (login off), or one with the cached token.
    static func resolve(printerId: Int) async throws -> Resolution {
        let session = AdminSession.shared
        if session.authEnabled == nil { await session.refreshStatus() }
        guard let plain = APIClient.shared.overlayURL(printerId: printerId) else { throw APIError.notConfigured }
        if session.authEnabled == false { return .ready(plain) }
        if let cached = OverlayTokenStore.load(), cached.expiresAt.timeIntervalSinceNow > renewBefore {
            return .ready(withToken(cached.token, to: plain))
        }
        return .needsToken
    }

    /// Mints and stores a token (sign-in session; asks for sign-in when there is none) and returns the URL.
    static func create(printerId: Int) async throws -> URL {
        let session = AdminSession.shared
        guard let plain = APIClient.shared.overlayURL(printerId: printerId) else { throw APIError.notConfigured }
        if session.authEnabled == nil { await session.refreshStatus() }
        guard session.can("camera:view") else {
            throw AdminError.message("Your Bambuddy account needs camera:view to create an overlay token.")
        }
        let name = "LayerPal overlay (\(UIDevice.current.name))"
        let record = try await session.perform { try await APIClient.shared.tokCreate(name: name, days: lifetimeDays, scope: "overlay", bearer: $0) }
        guard let token = record.token else { throw AdminError.message("Bambuddy didn't return the token.") }
        OverlayTokenStore.save(.init(token: token, expiresAt: record.expiresAt ?? Date().addingTimeInterval(Double(lifetimeDays) * 86400)))
        return withToken(token, to: plain)
    }

    private static func withToken(_ token: String, to url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url ?? url
    }
}

/// Device-only Keychain slot for the overlay token, keyed by server so switching servers never sends one server's
/// token to another. Never logged and never synced.
enum OverlayTokenStore {
    struct Stored: Codable { let token: String; let expiresAt: Date }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(ServerConfig.bundleBase).overlaytoken",
         kSecAttrAccount as String: ServerConfig.serverURL?.absoluteString ?? "none"]
    }

    static func load() -> Stored? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func save(_ stored: Stored) {
        SecItemDelete(query() as CFDictionary)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// "Open stream overlay" row for the printer's Advanced section: opens the overlay in the in-app Safari sheet, asking
/// before it creates a token the first time, and offers the link for OBS or a browser source.
struct OverlayLinkRows: View {
    let printerId: Int
    var open: (URL) -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var working = false
    @State private var confirmCreate = false
    @State private var wantsCopy = false
    @State private var awaitingSignIn = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { start(copy: false) } label: { row("Open stream overlay", "rectangle.on.rectangle", trailing: working ? nil : "arrow.up.right") }
                .buttonStyle(.plain).disabled(working)
                .accessibilityHint("Opens the overlay in Safari")
            Divider()
            Button { start(copy: true) } label: { row("Copy overlay link for OBS", "doc.on.doc", trailing: nil) }
                .buttonStyle(.plain).disabled(working)
                .accessibilityHint("Copies a link that contains an overlay token to the clipboard for two minutes")
            if let notice { Text(notice).font(.caption).foregroundStyle(Color.accentTeal).padding(.top, 4) }
            if let error { Text(error).font(.caption).foregroundStyle(Color.statusError).padding(.top, 4) }
        }
        .sheet(isPresented: Binding(get: { session.showSignIn && awaitingSignIn }, set: { session.showSignIn = $0 })) { AdminSignInSheet() }
        .confirmationDialog("Create an overlay token?", isPresented: $confirmCreate, titleVisibility: .visible) {
            Button("Create 30-day token") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The overlay page needs a token to read this printer when Bambuddy's login is on. LayerPal creates one named \"LayerPal overlay\" and keeps it on this iPhone. You can revoke it under Camera tokens.")
        }
    }

    private func row(_ title: String, _ symbol: String, trailing: String?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if working { ProgressView() }
            else if let trailing { Image(systemName: trailing).font(.caption).foregroundStyle(Color.textMuted) }
        }
        .font(.subheadline.weight(.medium))
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func start(copy: Bool) {
        error = nil
        notice = nil
        wantsCopy = copy
        working = true
        Task {
            defer { working = false }
            do {
                switch try await OverlayLink.resolve(printerId: printerId) {
                case let .ready(url): deliver(url)
                case .needsToken: confirmCreate = true
                }
            } catch { self.error = AdminError.friendly(error) }
        }
    }

    private func create() async {
        working = true
        awaitingSignIn = true
        defer { working = false; awaitingSignIn = false }
        do {
            deliver(try await OverlayLink.create(printerId: printerId))
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func deliver(_ url: URL) {
        if wantsCopy {
            copySecretToClipboard(url.absoluteString)
            notice = "Overlay link copied. It contains a token, so it clears from the clipboard in two minutes."
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            open(url)
        }
    }
}
