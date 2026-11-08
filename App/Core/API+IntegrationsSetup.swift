import Foundation

/// Integration setup (Bambuddy 1.3.0): Home Assistant sensors, Obico, OctoEverywhere, Spoolman, Bambu Cloud,
/// Orca Cloud, message templates and connected apps. The server refuses settings, cloud and connected-app
/// routes for API keys, so callers pass the sign-in session's JWT as `bearer`.
extension APIClient {
    // MARK: Home Assistant, per printer (smart_plugs:read/create/delete)

    /// GET /ha-sensors/?printer_id=
    func haSensors(printerId: Int?, bearer: String?) async throws -> [SetupHASensor] {
        let q = printerId.map { [URLQueryItem(name: "printer_id", value: String($0))] } ?? []
        return try await get("ha-sensors/", query: q, bearer: bearer)
    }

    /// GET /ha-sensors/entities?search=: 400 when Home Assistant has no URL and token in Settings.
    func haEntities(search: String?, bearer: String?) async throws -> [SetupHAEntity] {
        let q = (search ?? "").isEmpty ? [] : [URLQueryItem(name: "search", value: search)]
        return try await get("ha-sensors/entities", query: q, bearer: bearer)
    }

    /// GET /ha-sensors/by-printer/{id}/readings: card-visible sensors only, live from the poller.
    func haReadings(printerId: Int, bearer: String?) async throws -> [SetupHAReading] {
        try await get("ha-sensors/by-printer/\(printerId)/readings", bearer: bearer)
    }

    /// POST /ha-sensors/ (smart_plugs:create). Body keys per PrinterHASensorCreate.
    func haCreate(_ body: AdminJSON, bearer: String?) async throws {
        _ = try await request("ha-sensors/", method: "POST", body: body, bearer: bearer)
    }

    /// DELETE /ha-sensors/{id} (smart_plugs:delete)
    func haDelete(_ id: Int, bearer: String?) async throws {
        _ = try await request("ha-sensors/\(id)", method: "DELETE", bearer: bearer)
    }

    // MARK: Home Assistant, per storage location

    /// GET /inventory/locations (inventory:read)
    func setupStorageLocations(bearer: String?) async throws -> [SetupStorageLocation] {
        try await get("inventory/locations", bearer: bearer)
    }

    /// GET /location-ha-sensors/
    func haLocSensors(bearer: String?) async throws -> [SetupHALocSensor] { try await get("location-ha-sensors/", bearer: bearer) }

    /// GET /location-ha-sensors/entities?search=
    func haLocEntities(search: String?, bearer: String?) async throws -> [SetupHAEntity] {
        let q = (search ?? "").isEmpty ? [] : [URLQueryItem(name: "search", value: search)]
        return try await get("location-ha-sensors/entities", query: q, bearer: bearer)
    }

    /// GET /location-ha-sensors/by-location/{id}/readings?show_on_card=
    func haLocReadings(locationId: Int, bearer: String?) async throws -> [SetupHAReading] {
        try await get("location-ha-sensors/by-location/\(locationId)/readings",
                      query: [URLQueryItem(name: "show_on_card", value: "false")], bearer: bearer)
    }

    /// POST /location-ha-sensors/ (smart_plugs:create). One sensor per category (temperature, humidity, battery) per location.
    func haLocCreate(_ body: AdminJSON, bearer: String?) async throws {
        _ = try await request("location-ha-sensors/", method: "POST", body: body, bearer: bearer)
    }

    /// DELETE /location-ha-sensors/{id} (smart_plugs:delete)
    func haLocDelete(_ id: Int, bearer: String?) async throws {
        _ = try await request("location-ha-sensors/\(id)", method: "DELETE", bearer: bearer)
    }

    // MARK: Obico / OctoEverywhere (status: settings:read; test: settings:update)

    /// GET /obico/status -> enabled, ml_url, sensitivity, action, poll_interval, is_running, last_error, ...
    func obicoStatus(bearer: String?) async throws -> AdminJSON { try AdminJSON.parse(try await request("obico/status", bearer: bearer)) }

    /// POST /obico/test-connection {url, token?}: omit the token to use the saved one (saved URL only).
    func obicoTest(url: String, bearer: String?) async throws -> AdminJSON {
        struct Body: Encodable { let url: String }
        return try AdminJSON.parse(try await request("obico/test-connection", method: "POST", body: Body(url: url), bearer: bearer))
    }

    /// GET /octoeverywhere/status -> enabled, api_key_configured, confidence, action, poll_interval, notifications, ...
    func octoStatus(bearer: String?) async throws -> AdminJSON { try AdminJSON.parse(try await request("octoeverywhere/status", bearer: bearer)) }

    /// POST /octoeverywhere/test-connection {}: tests the saved key.
    func octoTest(bearer: String?) async throws -> AdminJSON {
        struct Body: Encodable {}
        return try AdminJSON.parse(try await request("octoeverywhere/test-connection", method: "POST", body: Body(), bearer: bearer))
    }

    // MARK: Spoolman (status: filaments:read; connect/disconnect: settings:update; sync: filaments:update)

    /// GET /spoolman/status
    func spoolmanStatus(bearer: String?) async throws -> SetupSpoolmanStatus { try await get("spoolman/status", bearer: bearer) }

    /// POST /spoolman/connect: uses the saved URL; 400 if not enabled or no URL, 503 if unreachable.
    func spoolmanConnect(bearer: String?) async throws {
        _ = try await request("spoolman/connect", method: "POST", bearer: bearer)
    }

    /// POST /spoolman/disconnect
    func spoolmanDisconnect(bearer: String?) async throws {
        _ = try await request("spoolman/disconnect", method: "POST", bearer: bearer)
    }

    /// POST /spoolman/sync/{printer_id}
    func spoolmanSync(printerId: Int, bearer: String?) async throws -> SetupSyncResult {
        try decoder().decode(SetupSyncResult.self, from: try await request("spoolman/sync/\(printerId)", method: "POST", bearer: bearer))
    }

    /// POST /spoolman/sync-all
    func spoolmanSyncAll(bearer: String?) async throws -> SetupSyncResult {
        try decoder().decode(SetupSyncResult.self, from: try await request("spoolman/sync-all", method: "POST", bearer: bearer))
    }

    // MARK: Bambu Cloud (cloud:auth, admin-level)

    /// GET /cloud/status
    func cloudStatus(bearer: String?) async throws -> SetupCloudStatus { try await get("cloud/status", bearer: bearer) }

    /// POST /cloud/login {email, password, region: global|china}. The password goes straight to Bambu and is never kept.
    func cloudLogin(email: String, password: String, region: String, bearer: String?) async throws -> SetupCloudLogin {
        struct Body: Encodable { let email: String; let password: String; let region: String }
        return try decoder().decode(SetupCloudLogin.self, from: try await request(
            "cloud/login", method: "POST", body: Body(email: email, password: password, region: region), bearer: bearer))
    }

    /// POST /cloud/verify {email, code, tfa_key?, region}
    func cloudVerify(email: String, code: String, tfaKey: String?, region: String, bearer: String?) async throws -> SetupCloudLogin {
        struct Body: Encodable { let email: String; let code: String; let tfaKey: String?; let region: String }
        return try decoder().decode(SetupCloudLogin.self, from: try await request(
            "cloud/verify", method: "POST", body: Body(email: email, code: code, tfaKey: tfaKey, region: region), bearer: bearer))
    }

    /// POST /cloud/logout
    func cloudLogout(bearer: String?) async throws {
        _ = try await request("cloud/logout", method: "POST", bearer: bearer)
    }

    // MARK: Orca Cloud (orca_cloud:auth)

    /// GET /orca-cloud/status
    func orcaStatus(bearer: String?) async throws -> SetupOrcaStatus { try await get("orca-cloud/status", bearer: bearer) }

    /// POST /orca-cloud/device/start
    func orcaStart(bearer: String?) async throws -> SetupOrcaStart {
        try decoder().decode(SetupOrcaStart.self, from: try await request("orca-cloud/device/start", method: "POST", bearer: bearer))
    }

    /// POST /orca-cloud/device/poll: authorization_pending | slow_down | access_denied | expired_token | complete
    func orcaPoll(bearer: String?) async throws -> SetupOrcaPoll {
        try decoder().decode(SetupOrcaPoll.self, from: try await request("orca-cloud/device/poll", method: "POST", bearer: bearer))
    }

    /// POST /orca-cloud/logout
    func orcaLogout(bearer: String?) async throws {
        _ = try await request("orca-cloud/logout", method: "POST", bearer: bearer)
    }

    // MARK: Message templates (notification_templates:read / :update)

    /// GET /notification-templates/
    func templateList(bearer: String?) async throws -> [SetupTemplate] { try await get("notification-templates/", bearer: bearer) }

    /// GET /notification-templates/variables
    func templateVariables(bearer: String?) async throws -> [SetupEventVariables] {
        try await get("notification-templates/variables", bearer: bearer)
    }

    /// PUT /notification-templates/{id} {title_template (1...200), body_template (1...2000)}
    func templateSave(_ id: Int, title: String, body: String, bearer: String?) async throws -> SetupTemplate {
        struct Body: Encodable { let titleTemplate: String; let bodyTemplate: String }
        return try decoder().decode(SetupTemplate.self, from: try await request(
            "notification-templates/\(id)", method: "PUT", body: Body(titleTemplate: title, bodyTemplate: body), bearer: bearer))
    }

    /// POST /notification-templates/{id}/reset
    func templateReset(_ id: Int, bearer: String?) async throws -> SetupTemplate {
        try decoder().decode(SetupTemplate.self, from: try await request("notification-templates/\(id)/reset", method: "POST", bearer: bearer))
    }

    /// POST /notification-templates/preview {event_type, title_template, body_template} -> {title, body} with sample data
    func templatePreview(eventType: String, title: String, body: String, bearer: String?) async throws -> (title: String, body: String) {
        struct Body: Encodable { let eventType: String; let titleTemplate: String; let bodyTemplate: String }
        struct Result: Decodable { let title: String; let body: String }
        let data = try await request("notification-templates/preview", method: "POST",
                                     body: Body(eventType: eventType, titleTemplate: title, bodyTemplate: body), bearer: bearer)
        let result = try decoder().decode(Result.self, from: data)
        return (result.title, result.body)
    }

    // MARK: Connected apps (settings:update + admin; needs Bambuddy login enabled to create)

    /// GET /connect/apps
    func appsList(bearer: String?) async throws -> [SetupConnectedApp] { try await get("connect/apps", bearer: bearer) }

    /// POST /connect/apps {name, redirect_uri}: the client secret is in this response and nowhere else.
    func appsCreate(name: String, redirectURI: String, bearer: String?) async throws -> SetupConnectedApp {
        struct Body: Encodable { let name: String; let redirectUri: String }
        return try decoder().decode(SetupConnectedApp.self, from: try await request(
            "connect/apps", method: "POST", body: Body(name: name, redirectUri: redirectURI), bearer: bearer))
    }

    /// PATCH /connect/apps/{id} {name?, redirect_uri?, enabled?}
    func appsUpdate(_ id: Int, name: String?, redirectURI: String?, enabled: Bool?, bearer: String?) async throws {
        struct Body: Encodable { let name: String?; let redirectUri: String?; let enabled: Bool? }
        _ = try await request("connect/apps/\(id)", method: "PATCH", body: Body(name: name, redirectUri: redirectURI, enabled: enabled), bearer: bearer)
    }

    /// POST /connect/apps/{id}/rotate-secret: the old secret stops working at once; the new one is shown once.
    func appsRotate(_ id: Int, bearer: String?) async throws -> SetupConnectedApp {
        try decoder().decode(SetupConnectedApp.self, from: try await request("connect/apps/\(id)/rotate-secret", method: "POST", bearer: bearer))
    }

    /// DELETE /connect/apps/{id}
    func appsDelete(_ id: Int, bearer: String?) async throws {
        _ = try await request("connect/apps/\(id)", method: "DELETE", bearer: bearer)
    }
}
