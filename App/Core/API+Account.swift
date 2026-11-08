import Foundation

/// The signed-in user's own account (Bambuddy 1.3.0): who they are, password, two-factor, email
/// preferences and announcements. Every one of these refuses API keys, so callers pass the sign-in
/// session's JWT as `bearer` (AdminSession.perform). Routes: /users/me, /mfa, /user-notifications,
/// /announcements.
extension APIClient {
    /// GET /auth/me
    func acctProfile(bearer: String?) async throws -> AcctProfile { try await get("auth/me", bearer: bearer) }

    /// POST /users/me/change-password {current_password, new_password}. The new password needs 8+ characters
    /// with upper, lower, digit and symbol. On success the server revokes this session, so sign in again.
    /// LDAP accounts get a 400.
    func acctChangePassword(current: String, new: String, bearer: String?) async throws {
        struct Body: Encodable { let currentPassword: String; let newPassword: String }
        _ = try await request("users/me/change-password", method: "POST",
                              body: Body(currentPassword: current, newPassword: new), bearer: bearer)
    }

    // MARK: Two-factor (/mfa; any active user)

    /// GET /auth/2fa/status
    func acct2FAStatus(bearer: String?) async throws -> AcctTwoFAStatus { try await get("auth/2fa/status", bearer: bearer) }

    /// POST /auth/2fa/totp/setup. `code` (the current authenticator code) is only needed to replace an active one.
    func acctTOTPSetup(code: String?, bearer: String?) async throws -> AcctTOTPSetup {
        struct Body: Encodable { let code: String? }
        let data = try await request("auth/2fa/totp/setup", method: "POST", body: code.map { Body(code: $0) }, bearer: bearer)
        return try decoder().decode(AcctTOTPSetup.self, from: data)
    }

    /// POST /auth/2fa/totp/enable {code (6 digits)} -> backup codes, shown once.
    func acctTOTPEnable(code: String, bearer: String?) async throws -> [String] {
        struct Body: Encodable { let code: String }
        struct Result: Decodable { let backupCodes: [String] }
        let data = try await request("auth/2fa/totp/enable", method: "POST", body: Body(code: code), bearer: bearer)
        return try decoder().decode(Result.self, from: data).backupCodes
    }

    /// POST /auth/2fa/totp/disable {code}: a TOTP code or a backup code.
    func acctTOTPDisable(code: String, bearer: String?) async throws {
        struct Body: Encodable { let code: String }
        _ = try await request("auth/2fa/totp/disable", method: "POST", body: Body(code: code), bearer: bearer)
    }

    /// POST /auth/2fa/totp/regenerate-backup-codes {code} -> ten new codes, shown once.
    func acctRegenerateBackupCodes(code: String, bearer: String?) async throws -> [String] {
        struct Body: Encodable { let code: String }
        struct Result: Decodable { let backupCodes: [String] }
        let data = try await request("auth/2fa/totp/regenerate-backup-codes", method: "POST", body: Body(code: code), bearer: bearer)
        return try decoder().decode(Result.self, from: data).backupCodes
    }

    /// POST /auth/2fa/email/enable -> {setup_token}; the server emails a 6-digit code (needs an email on the
    /// account and SMTP configured).
    func acctEmailEnable(bearer: String?) async throws -> String {
        struct Result: Decodable { let setupToken: String }
        let data = try await request("auth/2fa/email/enable", method: "POST", bearer: bearer)
        return try decoder().decode(Result.self, from: data).setupToken
    }

    /// POST /auth/2fa/email/enable/confirm {setup_token, code}
    func acctEmailConfirm(setupToken: String, code: String, bearer: String?) async throws {
        struct Body: Encodable { let setupToken: String; let code: String }
        _ = try await request("auth/2fa/email/enable/confirm", method: "POST", body: Body(setupToken: setupToken, code: code), bearer: bearer)
    }

    /// POST /auth/2fa/email/disable {password}. A wrong password answers 401, so callers must not treat
    /// that as an expired session.
    func acctEmailDisable(password: String, bearer: String?) async throws {
        struct Body: Encodable { let password: String }
        _ = try await request("auth/2fa/email/disable", method: "POST", body: Body(password: password), bearer: bearer)
    }

    // MARK: Email preferences (notifications:user_email)

    /// GET /user-notifications/preferences
    func acctEmailPrefs(bearer: String?) async throws -> AcctEmailPrefs { try await get("user-notifications/preferences", bearer: bearer) }

    /// PUT /user-notifications/preferences. Needs an email address on the account.
    func acctSaveEmailPrefs(_ prefs: AcctEmailPrefs, bearer: String?) async throws {
        _ = try await request("user-notifications/preferences", method: "PUT", body: prefs, bearer: bearer)
    }

    // MARK: Announcements (/announcements; any signed-in user the server lets see them)

    /// GET /announcements -> {visible, announcements: [...]}. `visible: false` for users who may not see them.
    func acctAnnouncements(bearer: String?) async throws -> (visible: Bool, items: [AcctAnnouncement]) {
        let json = try AdminJSON.parse(try await request("announcements", bearer: bearer))
        let items = (json["announcements"]?.array ?? []).compactMap(AcctAnnouncement.init(json:))
        return (json["visible"]?.bool ?? false, items)
    }

    /// POST /announcements/{id}/read -> 204
    func acctMarkAnnouncementRead(_ id: String, bearer: String?) async throws {
        _ = try await request("announcements/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/read",
                              method: "POST", bearer: bearer)
    }
}

extension AdminSession {
    /// Like `perform`, but a 401 is passed on instead of ending the session. For calls where 401 means "wrong
    /// password" (email 2FA disable) or "wrong Bambu Cloud login", not "your session expired".
    func performKeepingSession<T>(_ operation: (String?) async throws -> T) async throws -> T {
        if authEnabled == nil { await refreshStatus() }
        if authEnabled != false, !isSignedIn {
            showSignIn = true
            throw AdminError.signInRequired
        }
        return try await operation(bearer)
    }
}
