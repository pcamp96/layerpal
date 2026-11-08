import Foundation

/// Talks to the LayerPal push relay (Cloudflare Worker). The relay holds the
/// APNs keys; Bambuddy only ever sees this phone's private webhook URL.
struct RelayClient {
    static let shared = RelayClient()

    struct Registration: Decodable {
        let relayToken: String
        let webhookUrl: String
        let pushReady: Bool
        let polling: Bool?
    }

    /// Sentinel for Bambuddy servers with login turned off.
    static let noAuth = "-"

    static var environment: String {
        #if DEBUG
            "sandbox" // Xcode installs
        #else
            "production" // TestFlight / App Store
        #endif
    }

    private func post(_ path: String, _ body: [String: Any?]) async throws -> Data {
        guard let relay = ServerConfig.relayURL else {
            throw APIError.http(0, "This build has no push relay configured (RELAY_URL).")
        }
        var request = URLRequest(url: relay.appending(path: path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            throw APIError.http(code, "Push relay: " + String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func register(deviceToken: String, pushToStartToken: String?) async throws -> Registration {
        let data = try await post("v1/register", [
            "device_token": deviceToken,
            "environment": Self.environment,
            "push_to_start_token": pushToStartToken,
            "relay_token": ServerConfig.relayToken,
            // Off = relay stops starting and refreshing Lock Screen cards for this phone.
            "live_activities": LiveActivityPrefs.enabled,
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let registration = try decoder.decode(Registration.self, from: data)
        ServerConfig.relayToken = registration.relayToken
        ServerConfig.webhookURL = URL(string: registration.webhookUrl)
        return registration
    }

    /// Registers the all-prints card's push token.
    func registerActivity(pushToken: String) async throws {
        guard let relayToken = ServerConfig.relayToken else { return }
        _ = try await post("v1/activity", ["relay_token": relayToken, "push_token": pushToken])
    }

    /// Hands the relay a read-only Bambuddy key so it can keep the Lock Screen card current.
    func setPollCredentials(server: URL, apiKey: String) async throws {
        guard let relayToken = ServerConfig.relayToken else { return }
        _ = try await post("v1/poll-credentials", ["relay_token": relayToken, "server_url": server.absoluteString, "api_key": apiKey])
    }

    /// Sends a test event through the same path Bambuddy uses.
    func sendTest() async throws {
        guard let url = ServerConfig.webhookURL else { throw APIError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "event": "test", "title": "LayerPal test", "message": "Notifications are working.", "source": "LayerPal",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
    }
}
