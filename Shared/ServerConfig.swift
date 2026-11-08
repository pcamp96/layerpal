import Foundation
import Security

/// Everything the app and its notification extension share: the user's
/// Bambuddy address (App Group defaults), the app's own Bambuddy API key
/// (shared keychain), and this phone's LayerPal relay registration.
enum ServerConfig {
    private static let urlKey = "serverURL"
    private static let relayTokenKey = "relayToken"
    private static let webhookURLKey = "webhookURL"
    private static let webhookInstalledKey = "webhookInstalledFor"
    private static var keychainService: String { "\(bundleBase).apikey" }

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// The app's base bundle ID (LAYERPAL_BUNDLE_ID); keychain names and the shared group derive from it.
    static var bundleBase: String {
        info("BundleBase") ?? (Bundle.main.bundleIdentifier ?? "layerpal").replacingOccurrences(of: ".widgets", with: "")
            .replacingOccurrences(of: ".notificationservice", with: "")
    }

    private static var appGroup: String { info("AppGroup") ?? "group.\(bundleBase)" }

    private static var accessGroup: String? {
        info("AppIdentifierPrefix").map { "\($0)\(bundleBase).shared" }
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    // MARK: Bambuddy server

    static var serverURL: URL? {
        // Standard defaults also covers the `-serverURL <url>` launch argument (simulator testing).
        get { (defaults.string(forKey: urlKey) ?? UserDefaults.standard.string(forKey: urlKey)).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: urlKey) }
    }

    static var apiKey: String? {
        get {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else {
                #if DEBUG
                    // Simulator testing: `-apiKey bb_...` launch argument.
                    return UserDefaults.standard.string(forKey: "apiKey")
                #else
                    return nil
                #endif
            }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery() as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var query = baseQuery()
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// Adds auth to a request to the Bambuddy server.
    static func authorize(_ request: inout URLRequest) {
        if let key = apiKey { request.setValue(key, forHTTPHeaderField: "X-API-Key") }
    }

    // MARK: LayerPal relay

    /// nil when the build has no relay configured (RELAY_URL empty): no push or Live Activity updates.
    static var relayURL: URL? {
        info("RelayURL").flatMap(URL.init(string:))
    }

    /// Secret that identifies this phone to the relay (also the tail of its webhook URL).
    static var relayToken: String? {
        get { defaults.string(forKey: relayTokenKey) }
        set { defaults.set(newValue, forKey: relayTokenKey) }
    }

    /// The URL Bambuddy posts events to for this phone.
    static var webhookURL: URL? {
        get { defaults.string(forKey: webhookURLKey).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: webhookURLKey) }
    }

    /// Which Bambuddy server we last installed the webhook into (so a server change re-prompts setup).
    static var webhookInstalledFor: String? {
        get { defaults.string(forKey: webhookInstalledKey) }
        set { defaults.set(newValue, forKey: webhookInstalledKey) }
    }

    // MARK: Media tokens

    /// Server tokens last 60 minutes; reuse for 50.
    private static var cachedToken: (value: String, expires: Date)?

    /// Short-lived token that camera snapshot / photo / thumbnail URLs need.
    static func streamToken() async -> String? {
        if let cached = cachedToken, cached.expires > Date() { return cached.value }
        let token = await fetchStreamToken()
        if let token { cachedToken = (token, Date().addingTimeInterval(50 * 60)) }
        return token
    }

    private static func fetchStreamToken() async -> String? {
        guard let base = serverURL else { return nil }
        var request = URLRequest(url: base.appending(path: "api/v1/printers/camera/stream-token"))
        request.httpMethod = "POST"
        authorize(&request)
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode([String: String].self, from: result.0) else { return nil }
        return body["token"]
    }
}
