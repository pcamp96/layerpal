import Foundation

/// Admin endpoints (Bambuddy 1.3.0). The server refuses almost all of these
/// for API keys, so callers pass the admin session's JWT as `bearer`. A `nil`
/// bearer falls back to the app's API key, which is right when auth is disabled.
extension APIClient {
    // MARK: Sign-in (/auth, /mfa)

    struct AdminLoginResponse: Decodable {
        let accessToken: String?
        let requires2fa: Bool?
        let preAuthToken: String?
        /// Which second steps this account has: totp, email, backup (login response).
        let twoFaMethods: [String]?
        let user: AdminLoginUser?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", requires2fa = "requires_2fa", preAuthToken = "pre_auth_token"
            case twoFaMethods = "two_fa_methods", user
        }
    }

    struct AdminLoginUser: Decodable { let username: String? }

    /// POST /auth/login (public). Decoded with plain keys: `requires_2fa` would
    /// not survive the shared decoder's snake-case conversion.
    func adminLogin(username: String, password: String) async throws -> AdminLoginResponse {
        struct Body: Encodable { let username: String; let password: String }
        let data = try await request("auth/login", method: "POST", body: Body(username: username, password: password))
        return try JSONDecoder().decode(AdminLoginResponse.self, from: data)
    }

    /// POST /auth/2fa/verify (public). Methods: totp, email, backup.
    func adminVerify(preAuthToken: String, code: String, method: String = "totp") async throws -> AdminLoginResponse {
        struct Body: Encodable { let preAuthToken: String; let code: String; let method: String }
        let data = try await request("auth/2fa/verify", method: "POST",
                                     body: Body(preAuthToken: preAuthToken, code: code, method: method))
        return try JSONDecoder().decode(AdminLoginResponse.self, from: data)
    }

    /// GET /auth/me with the admin JWT: role, is_admin and the permission list.
    func adminMe(bearer: String) async throws -> Me { try await get("auth/me", bearer: bearer) }

    /// POST /auth/logout: revokes the JWT server-side (best effort).
    func adminLogout(bearer: String) async { _ = try? await request("auth/logout", method: "POST", bearer: bearer) }

    struct AdvancedAuthStatus: Decodable {
        let advancedAuthEnabled: Bool
        let smtpConfigured: Bool
    }

    /// GET /auth/advanced-auth/status (public).
    func advancedAuthStatus() async throws -> AdvancedAuthStatus { try await get("auth/advanced-auth/status") }

    // MARK: Printers (/printers)

    /// GET /printers/ (printers:read). With an admin JWT the response also carries each
    /// printer's access code; AdminPrinter deliberately has no field for it.
    func adminPrinters(bearer: String?) async throws -> [AdminPrinter] { try await get("printers/", bearer: bearer) }

    /// POST /printers/ (printers:create). The server test-connects over MQTT first and
    /// answers 400 `printer_connection_failed` if it can't reach the printer.
    func createPrinter(_ body: AdminJSON, bearer: String?) async throws {
        _ = try await request("printers/", method: "POST", body: body, bearer: bearer)
    }

    /// PATCH /printers/{id} (printers:update). Send only what changed.
    func updatePrinter(_ id: Int, patch: AdminJSON, bearer: String?) async throws {
        _ = try await request("printers/\(id)", method: "PATCH", body: patch, bearer: bearer)
    }

    /// DELETE /printers/{id}?delete_archives= (printers:delete).
    func deletePrinter(_ id: Int, deleteArchives: Bool, bearer: String?) async throws {
        _ = try await request("printers/\(id)", method: "DELETE",
                              query: [URLQueryItem(name: "delete_archives", value: deleteArchives ? "true" : "false")], bearer: bearer)
    }

    /// POST /printers/{id}/connect (printers:control). Returns whether the printer connected.
    func connectPrinter(_ id: Int, bearer: String?) async throws -> Bool {
        let data = try await request("printers/\(id)/connect", method: "POST", bearer: bearer)
        return (try? AdminJSON.parse(data))?["connected"]?.bool ?? false
    }

    /// POST /printers/{id}/disconnect (printers:control).
    func disconnectPrinter(_ id: Int, bearer: String?) async throws {
        _ = try await request("printers/\(id)/disconnect", method: "POST", bearer: bearer)
    }

    /// POST /printers/{id}/refresh-status (printers:read). 400 when the printer isn't connected.
    func refreshPrinterStatus(_ id: Int, bearer: String?) async throws {
        _ = try await request("printers/\(id)/refresh-status", method: "POST", bearer: bearer)
    }

    // MARK: Notification providers (/notifications)

    /// GET /notifications/ (notifications:read).
    func notificationProviders(bearer: String?) async throws -> [NotificationProviderItem] {
        let json = try AdminJSON.parse(try await request("notifications/", bearer: bearer))
        return (json.array ?? []).compactMap(NotificationProviderItem.init(json:))
    }

    /// POST /notifications/ (notifications:create).
    func createNotificationProvider(_ body: AdminJSON, bearer: String?) async throws {
        _ = try await request("notifications/", method: "POST", body: body, bearer: bearer)
    }

    /// PATCH /notifications/{id} (notifications:update). Secrets sent back as "********" are kept.
    func updateNotificationProvider(_ id: Int, patch: AdminJSON, bearer: String?) async throws {
        _ = try await request("notifications/\(id)", method: "PATCH", body: patch, bearer: bearer)
    }

    /// DELETE /notifications/{id} (notifications:delete).
    func deleteNotificationProvider(_ id: Int, bearer: String?) async throws {
        _ = try await request("notifications/\(id)", method: "DELETE", bearer: bearer)
    }

    struct TestResult { let success: Bool; let message: String }

    /// POST /notifications/{id}/test (notifications:update).
    func testNotificationProvider(_ id: Int, bearer: String?) async throws -> TestResult {
        let json = try AdminJSON.parse(try await request("notifications/\(id)/test", method: "POST", bearer: bearer))
        return TestResult(success: json["success"]?.bool ?? false, message: json["message"]?.string ?? "")
    }

    /// POST /notifications/test-config (notifications:create): tests an unsaved config.
    func testNotificationConfig(type: String, config: [String: String], bearer: String?) async throws -> TestResult {
        let body = AdminJSON.object([
            "provider_type": .string(type),
            "config": .object(config.mapValues { .string($0) }),
            "attach_photo": .bool(false),
        ])
        let json = try AdminJSON.parse(try await request("notifications/test-config", method: "POST", body: body, bearer: bearer))
        return TestResult(success: json["success"]?.bool ?? false, message: json["message"]?.string ?? "")
    }

    // MARK: Users and groups (/users, /groups, /auth)

    /// GET /users/ (users:read).
    func adminUsers(bearer: String?) async throws -> [AdminUser] { try await get("users/", bearer: bearer) }

    /// POST /users/ (users:create + admin). With advanced auth the server generates the
    /// password and emails it, and the email is required.
    func createUser(username: String, password: String?, email: String?, role: String, groupIds: [Int], bearer: String?) async throws {
        var o: [String: AdminJSON] = ["username": .string(username), "role": .string(role),
                                      "group_ids": .array(groupIds.map { .int($0) })]
        if let password, !password.isEmpty { o["password"] = .string(password) }
        if let email, !email.isEmpty { o["email"] = .string(email) }
        _ = try await request("users/", method: "POST", body: AdminJSON.object(o), bearer: bearer)
    }

    /// PATCH /users/{id} (users:update + admin). Send only what changed. An empty email clears it.
    func updateUser(_ id: Int, patch: AdminJSON, bearer: String?) async throws {
        _ = try await request("users/\(id)", method: "PATCH", body: patch, bearer: bearer)
    }

    /// DELETE /users/{id}?delete_items= (users:delete + admin). The last admin can't be deleted.
    func deleteUser(_ id: Int, deleteItems: Bool, bearer: String?) async throws {
        _ = try await request("users/\(id)", method: "DELETE",
                              query: [URLQueryItem(name: "delete_items", value: deleteItems ? "true" : "false")], bearer: bearer)
    }

    /// POST /auth/reset-password (admin, advanced auth + SMTP only): emails a one-hour reset link.
    func sendPasswordResetLink(userId: Int, bearer: String?) async throws -> String {
        struct Body: Encodable { let userId: Int }
        let json = try AdminJSON.parse(try await request("auth/reset-password", method: "POST", body: Body(userId: userId), bearer: bearer))
        return json["message"]?.string ?? "Reset link sent."
    }

    /// GET /groups/ (groups:read).
    func adminGroups(bearer: String?) async throws -> [AdminGroup] { try await get("groups/", bearer: bearer) }

    // MARK: API keys (/api-keys)

    /// GET /api-keys/ (api_keys:read).
    func adminAPIKeys(bearer: String?) async throws -> [AdminAPIKey] { try await get("api-keys/", bearer: bearer) }

    struct APIKeyDraft {
        var name = ""
        var canReadStatus = true
        var canQueue = false
        var canControlPrinter = false
        var canManageLibrary = false
        var canManageInventory = false
        var canManageMaintenance = false
        var canManageArchives = false
        var canManageProjects = false
        var canAccessCloud = false
        var canUpdateEnergyCost = false
        var canSendNotifications = false
        var expiresAt: Date?
        /// nil = every printer; otherwise the key only sees these (`printer_ids`).
        var printerIds: [Int]?
    }

    /// POST /api-keys/ (api_keys:create). The full key is in this response only.
    func createAPIKey(_ draft: APIKeyDraft, bearer: String?) async throws -> AdminCreatedKey {
        struct Body: Encodable {
            let name: String
            let canReadStatus, canQueue, canControlPrinter, canManageLibrary, canManageInventory: Bool
            let canManageMaintenance, canManageArchives, canManageProjects, canAccessCloud: Bool
            let canUpdateEnergyCost, canSendNotifications: Bool
            let expiresAt: String?
            let printerIds: [Int]?
        }
        let formatter = ISO8601DateFormatter()
        let body = Body(name: draft.name, canReadStatus: draft.canReadStatus, canQueue: draft.canQueue,
                        canControlPrinter: draft.canControlPrinter, canManageLibrary: draft.canManageLibrary,
                        canManageInventory: draft.canManageInventory, canManageMaintenance: draft.canManageMaintenance,
                        canManageArchives: draft.canManageArchives, canManageProjects: draft.canManageProjects,
                        canAccessCloud: draft.canAccessCloud, canUpdateEnergyCost: draft.canUpdateEnergyCost,
                        canSendNotifications: draft.canSendNotifications,
                        expiresAt: draft.expiresAt.map { formatter.string(from: $0) }, printerIds: draft.printerIds)
        return try await send("api-keys/", body: body, bearer: bearer)
    }

    /// PATCH /api-keys/{id} (api_keys:update): enable or disable a key.
    func setAPIKeyEnabled(_ id: Int, enabled: Bool, bearer: String?) async throws {
        _ = try await request("api-keys/\(id)", method: "PATCH", body: AdminJSON.object(["enabled": .bool(enabled)]), bearer: bearer)
    }

    /// DELETE /api-keys/{id} (api_keys:delete): revoke.
    func revokeAPIKey(_ id: Int, bearer: String?) async throws {
        _ = try await request("api-keys/\(id)", method: "DELETE", bearer: bearer)
    }

    // MARK: Settings (/settings)

    /// GET /settings/ (settings:read). Secrets come back as "********".
    func adminSettings(bearer: String?) async throws -> [String: AdminJSON] {
        try AdminJSON.parse(try await request("settings/", bearer: bearer)).object ?? [:]
    }

    /// PATCH /settings/ (settings:update). Partial: send only changed keys. Returns the new settings.
    func patchSettings(_ patch: [String: AdminJSON], bearer: String?) async throws -> [String: AdminJSON] {
        try AdminJSON.parse(try await request("settings/", method: "PATCH", body: AdminJSON.object(patch), bearer: bearer)).object ?? [:]
    }

    // MARK: System (/system)

    /// GET /system/info (system:read; API keys with read-status are allowed).
    func systemInfo(bearer: String?) async throws -> AdminSystemInfo {
        AdminSystemInfo(json: try AdminJSON.parse(try await request("system/info", bearer: bearer)))
    }
}
