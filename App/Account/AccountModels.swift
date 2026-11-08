import Foundation

/// Response of GET /auth/me. The shared `Me` model leaves out email and groups.
struct AcctProfile: Decodable {
    struct Group: Decodable, Identifiable, Hashable { let id: Int; let name: String }
    let id: Int
    let username: String
    let email: String?
    let isActive: Bool?
    let isAdmin: Bool?
    let authSource: String?
    let groups: [Group]?
    let permissions: [String]?
    let createdAt: String?

    var isLocal: Bool { (authSource ?? "local") == "local" }
}

/// GET /auth/2fa/status
struct AcctTwoFAStatus: Decodable {
    let totpEnabled: Bool
    let emailOtpEnabled: Bool
    let backupCodesRemaining: Int
}

/// POST /auth/2fa/totp/setup. The secret is shown once and never stored by the app.
struct AcctTOTPSetup: Decodable {
    let secret: String
    let issuer: String
}

/// GET/PUT /user-notifications/preferences
struct AcctEmailPrefs: Codable, Equatable {
    var notifyPrintStart: Bool
    var notifyPrintComplete: Bool
    var notifyPrintFailed: Bool
    var notifyPrintStopped: Bool
}

/// One entry of GET /announcements. `texts` maps a language code to title/body (English always exists).
struct AcctAnnouncement: Identifiable, Hashable {
    let id: String
    let level: String
    let title: String
    let body: String
    let linkLabel: String?
    let linkURL: URL?
    let publishedAt: Date?
    let archived: Bool
    var read: Bool

    init?(json: AdminJSON) {
        guard let id = json["id"]?.string else { return nil }
        let texts = json["texts"]?.object ?? [:]
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        guard let text = texts[lang]?.object ?? texts["en"]?.object ?? texts.values.first?.object else { return nil }
        self.id = id
        level = json["level"]?.string ?? "info"
        title = text["title"]?.string ?? "Announcement"
        body = text["body"]?.string ?? ""
        linkLabel = text["link_label"]?.string
        // Only web links open from here; anything else in a feed entry is ignored.
        let link = json["link_url"]?.string.flatMap(URL.init(string:))
        linkURL = link.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        publishedAt = AdminDate.parse(json["published_at"]?.string)
        archived = json["archived"]?.bool ?? false
        read = json["read"]?.bool ?? false
    }
}
