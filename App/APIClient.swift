import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case emptyResponse
    case needsTwoFactor
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Bambuddy server in Settings."
        case .emptyResponse: "Bambuddy sent back nothing. The server may be down or still starting."
        case .needsTwoFactor: "This account uses two-step sign-in. Type the 6-digit code from your authenticator app."
        case let .http(code, body):
            code == 401 || code == 403
                ? "Bambuddy rejected the request (\(code)). Sign in again in Settings."
                : "Bambuddy returned \(code). \(body.prefix(120))"
        }
    }
}

struct APIClient {
    static let shared = APIClient()

    func decoder() -> JSONDecoder { jsonDecoder }

    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Bambuddy often stores naive UTC timestamps ("2026-11-07T14:03:11"), so also try with "Z".
            // Python emits microseconds; drop the fraction as a last resort.
            let noFraction = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            for candidate in [raw, raw + "Z", noFraction, noFraction + "Z"] {
                if let date = plain.date(from: candidate) ?? fractional.date(from: candidate) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
        }
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// `bearer` is a one-time login session used only during setup; normal
    /// calls use the app's own API key from the keychain.
    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Encodable? = nil,
                 bearer: String? = nil, server: URL? = nil) async throws -> Data {
        guard let base = server ?? ServerConfig.serverURL else { throw APIError.notConfigured }
        var url = base.appending(path: "api/v1/" + path)
        if !query.isEmpty { url.append(queryItems: query) }
        // 30 s: some calls (K-profiles, printer commands) wait on the printer's MQTT reply.
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        } else {
            ServerConfig.authorize(&request)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        // A proxy (Cloudflare tunnel) in front of a stopped Bambuddy answers 200 with no body.
        if data.isEmpty, method == "GET" { throw APIError.emptyResponse }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], bearer: String? = nil, server: URL? = nil) async throws -> T {
        try jsonDecoder.decode(T.self, from: try await request(path, query: query, bearer: bearer, server: server))
    }

    func send<T: Decodable>(_ path: String, method: String = "POST", body: Encodable, bearer: String? = nil,
                            server: URL? = nil) async throws -> T {
        try jsonDecoder.decode(T.self, from: try await request(path, method: method, body: body, bearer: bearer, server: server))
    }

    // MARK: Everyday reads (API key)

    func printers() async throws -> [Printer] { try await get("printers/") }

    func status(printerId: Int) async throws -> PrinterStatus { try await get("printers/\(printerId)/status") }

    func archives(limit: Int = 40) async throws -> [Archive] {
        try await get("archives/", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Camera / photo / thumbnail URLs need a short-lived stream token.
    func mediaURL(_ path: String, extra: [URLQueryItem] = []) async -> URL? {
        guard let base = ServerConfig.serverURL else { return nil }
        var url = base.appending(path: "api/v1/" + path)
        if !extra.isEmpty { url.append(queryItems: extra) }
        if let token = await ServerConfig.streamToken() { url.append(queryItems: [URLQueryItem(name: "token", value: token)]) }
        url.append(queryItems: [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970)))])
        return url
    }

    // MARK: One-time setup (login session)

    struct AuthStatus: Decodable { let authEnabled: Bool }

    func authStatus(server: URL) async throws -> AuthStatus { try await get("auth/status", server: server) }

    struct LoginResult: Decodable {
        let accessToken: String?
        // convertFromSnakeCase turns requires_2fa into requires2fa
        let requires2fa: Bool?
        let preAuthToken: String?
        /// totp, email, backup (convertFromSnakeCase turns two_fa_methods into twoFaMethods)
        let twoFaMethods: [String]?
    }

    /// If `requires2fa`, follow up with `verifyTwoFactor` using `preAuthToken`.
    func login(server: URL, username: String, password: String) async throws -> LoginResult {
        struct Body: Encodable { let username: String; let password: String }
        return try await send("auth/login", body: Body(username: username, password: password), server: server)
    }

    /// `method` is totp, email or backup. The server also checks the HttpOnly `2fa_challenge` cookie it
    /// set at login; URLSession.shared keeps cookies, and nothing here strips them.
    func verifyTwoFactor(server: URL, preAuthToken: String, code: String, method: String = "totp") async throws -> String {
        struct Body: Encodable { let preAuthToken: String; let code: String; let method: String }
        struct Result: Decodable { let accessToken: String }
        let result: Result = try await send("auth/2fa/verify",
                                            body: Body(preAuthToken: preAuthToken, code: code, method: method),
                                            server: server)
        return result.accessToken
    }

    /// Creates this phone's own key so we never store the password. Bambuddy
    /// caps what a key can do at its owner's permissions, so asking for control
    /// on a viewer account just yields a read-only key.
    func createAppKey(server: URL, bearer: String, deviceName: String, allowControl: Bool) async throws -> String {
        struct Body: Encodable {
            let name: String
            let canReadStatus = true
            let canControlPrinter: Bool
            let canQueue: Bool
            let canManageMaintenance: Bool
            let canManageArchives: Bool
            let canManageInventory: Bool
            let canManageLibrary: Bool
            let canManageProjects: Bool
        }
        struct Result: Decodable { let key: String }
        let body = Body(name: "LayerPal – \(deviceName)", canControlPrinter: allowControl, canQueue: allowControl,
                        canManageMaintenance: allowControl, canManageArchives: allowControl, canManageInventory: allowControl,
                        canManageLibrary: allowControl, canManageProjects: allowControl)
        let result: Result = try await send("api-keys/", body: body, bearer: bearer, server: server)
        return result.key
    }

    struct Provider: Decodable {
        let id: Int
        let name: String?
        let providerType: String
        let config: [String: LooseString]?
        var webhookURL: String? { config?["webhook_url"]?.value ?? config?["webhookUrl"]?.value }
    }

    /// Adds (or repoints) this phone's webhook in Bambuddy's notification settings.
    @discardableResult
    func installWebhook(server: URL, bearer: String?, webhookURL: URL, deviceName: String) async throws -> Int {
        struct Config: Encodable { let webhookURL: String; let payloadFormat = "generic"
            enum CodingKeys: String, CodingKey { case webhookURL = "webhook_url", payloadFormat = "payload_format" }
        }
        struct Create: Encodable {
            let name: String
            let providerType = "webhook"
            let enabled = true
            let config: Config
            let onPrintStart = true
            let onPrintComplete = true
            let onPrintFailed = true
            let onPrintStopped = true
            let onPrintProgress = true // drives the Lock Screen progress card
            let onPrinterOffline = true
            let onPrinterError = true
            let onAiFailureDetection = true
            let onFilamentLow = true
            let onPlateNotEmpty = true
        }
        struct Patch: Encodable { let config: Config; let enabled = true }
        struct Created: Decodable { let id: Int }

        let config = Config(webhookURL: webhookURL.absoluteString)
        // The relay token (and so the URL) is stable per install, so an exact match means "already installed".
        let existing: [Provider] = try await get("notifications/", bearer: bearer, server: server)
        // Bambuddy masks webhook URLs in lists ("********"), so also match this phone's provider by name.
        let ownName = "LayerPal – \(deviceName)"
        let mine = existing
            .filter { $0.providerType == "webhook" && ($0.webhookURL == webhookURL.absoluteString || $0.name == ownName) }
            .sorted { $0.id < $1.id }
        if let keep = mine.first {
            // Older builds could install this phone's webhook twice, which sends every alert twice.
            for extra in mine.dropFirst() {
                _ = try? await request("notifications/\(extra.id)", method: "DELETE", bearer: bearer, server: server)
            }
            _ = try await request("notifications/\(keep.id)", method: "PATCH", body: Patch(config: config), bearer: bearer, server: server)
            return keep.id
        }
        let created: Created = try await send("notifications/", body: Create(name: "LayerPal – \(deviceName)", config: config),
                                              bearer: bearer, server: server)
        return created.id
    }
}

/// Provider configs mix strings with numbers/bools/objects; keep only strings.
struct LooseString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
