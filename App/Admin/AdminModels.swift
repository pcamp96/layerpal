import Foundation

/// Loose JSON for payloads whose keys are data (notification configs, settings).
/// Parsed with JSONSerialization so key names stay exactly as Bambuddy sends them
/// (the shared decoder would camel-case dictionary keys).
enum AdminJSON: Encodable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AdminJSON])
    case object([String: AdminJSON])

    static func parse(_ data: Data) throws -> AdminJSON {
        AdminJSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 1e15 { self = .int(n.intValue) }
            else { self = .double(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { AdminJSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { AdminJSON(any: $0) })
        default: self = .null
        }
    }

    var object: [String: AdminJSON]? { if case let .object(o) = self { return o } else { return nil } }
    var array: [AdminJSON]? { if case let .array(a) = self { return a } else { return nil } }

    subscript(key: String) -> AdminJSON? { object?[key] }

    var string: String? {
        switch self {
        case let .string(s): s
        case let .int(i): String(i)
        case let .double(d): String(d)
        case let .bool(b): b ? "true" : "false"
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case let .bool(b): b
        case let .string(s): s == "true" ? true : (s == "false" ? false : nil)
        case let .int(i): i != 0
        default: nil
        }
    }

    var int: Int? {
        switch self {
        case let .int(i): i
        case let .double(d): Int(d)
        case let .string(s): Int(s)
        default: nil
        }
    }

    var double: Double? {
        switch self {
        case let .double(d): d
        case let .int(i): Double(i)
        case let .string(s): Double(s)
        default: nil
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case let .bool(b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case let .int(i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case let .double(d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case let .string(s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case let .array(a):
            var c = encoder.unkeyedContainer()
            for item in a { try c.encode(item) }
        case let .object(o):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in o { try c.encode(v, forKey: Key(k)) }
        }
    }
}

enum AdminDate {
    /// Bambuddy timestamps are ISO 8601, often naive UTC.
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFraction = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        for candidate in [raw, raw + "Z", noFraction, noFraction + "Z"] {
            if let d = plain.date(from: candidate) ?? fractional.date(from: candidate) { return d }
        }
        return nil
    }
}

// MARK: - Errors

enum AdminError: LocalizedError {
    case signInRequired
    case message(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in as a Bambuddy admin to continue."
        case let .message(m): m
        }
    }

    /// Pulls FastAPI's `detail` (string, `{message}`, or validation list) out of an error.
    static func friendly(_ error: Error) -> String {
        if let e = error as? AdminError { return e.errorDescription ?? "Something went wrong." }
        if case let APIError.http(code, body) = error {
            if let json = try? AdminJSON.parse(Data(body.utf8)), let detail = json["detail"] {
                if let s = detail.string { return s }
                if let m = detail["message"]?.string { return m }
                if let first = detail.array?.first, let msg = first["msg"]?.string {
                    let field = first["loc"]?.array?.last?.string
                    return field.map { "\($0): \(msg)" } ?? msg
                }
            }
            if code == 401 { return "Your admin session ended. Sign in again." }
            if code == 403 { return "Your Bambuddy account isn't allowed to do that." }
            return "Bambuddy returned \(code)."
        }
        return error.localizedDescription
    }
}

// MARK: - Printers

struct AdminPrinter: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let serialNumber: String?
    let ipAddress: String?
    let model: String?
    let location: String?
    let isActive: Bool?
    let autoArchive: Bool?
    let externalCameraUrl: String?
    let externalCameraType: String?
    let externalCameraEnabled: Bool?
    let externalCameraSnapshotUrl: String?
    let cameraRotation: Int?
    let cameraLightAuto: Bool?
    let plateDetectionEnabled: Bool?
    let wearCostPerHour: Double?
}

enum AdminPrinterModels {
    /// Model names the add/edit printer form offers (names the server accepts).
    static let all: [String] = [
        "A1", "A1 Mini", "A2L", "H2C", "H2D", "H2D Pro", "H2S", "H3C", "P1P", "P1S", "P2S", "X1", "X1C", "X1E", "X2D",
    ]
    static let cameraTypes: [(value: String, label: String)] = [
        ("mjpeg", "MJPEG stream"), ("rtsp", "RTSP"), ("snapshot", "Snapshot URL"), ("usb", "USB camera"),
    ]
}

// MARK: - Notifications

struct NotificationEventToggle: Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

struct NotificationEventGroup: Identifiable {
    let title: String
    let events: [NotificationEventToggle]
    var id: String { title }

    static let all: [NotificationEventGroup] = [
        .init(title: "Print lifecycle", events: [
            .init(key: "on_print_start", label: "Print started"),
            .init(key: "on_print_complete", label: "Print finished"),
            .init(key: "on_print_failed", label: "Print failed"),
            .init(key: "on_print_stopped", label: "Print stopped"),
            .init(key: "on_print_progress", label: "Progress (25 / 50 / 75%)"),
            .init(key: "on_first_layer_complete", label: "First layer done"),
            .init(key: "on_bed_cooled", label: "Bed cooled"),
            .init(key: "on_print_pause_upcoming", label: "Pause coming up"),
            .init(key: "on_print_confirm_request", label: "Outcome confirmation request"),
            .init(key: "on_print_missing_spool_assignment", label: "Missing spool assignment"),
        ]),
        .init(title: "Printer status", events: [
            .init(key: "on_printer_offline", label: "Printer offline"),
            .init(key: "on_printer_error", label: "Printer error"),
            .init(key: "on_ai_failure_detection", label: "AI failure detection"),
            .init(key: "on_filament_low", label: "Filament low"),
            .init(key: "on_maintenance_due", label: "Maintenance due"),
            .init(key: "on_plate_not_empty", label: "Plate not empty"),
            .init(key: "on_plate_clear_required", label: "Plate clear required"),
        ]),
        .init(title: "AMS and sensors", events: [
            .init(key: "on_ams_humidity_high", label: "AMS humidity high"),
            .init(key: "on_ams_temperature_high", label: "AMS temperature high"),
            .init(key: "on_ams_drying_suspended", label: "AMS drying gave up"),
            .init(key: "on_ams_ht_humidity_high", label: "AMS-HT humidity high"),
            .init(key: "on_ams_ht_temperature_high", label: "AMS-HT temperature high"),
            .init(key: "on_ha_sensor_alert", label: "Home Assistant sensor alert"),
            .init(key: "on_location_ha_sensor_alert", label: "Location sensor alert"),
        ]),
        .init(title: "Queue", events: [
            .init(key: "on_queue_job_added", label: "Job added"),
            .init(key: "on_queue_job_assigned", label: "Job assigned to printer"),
            .init(key: "on_queue_job_started", label: "Job started"),
            .init(key: "on_queue_job_waiting", label: "Job waiting"),
            .init(key: "on_queue_job_skipped", label: "Job skipped"),
            .init(key: "on_queue_job_failed", label: "Job failed to start"),
            .init(key: "on_queue_completed", label: "Queue finished"),
        ]),
        .init(title: "Other", events: [
            .init(key: "on_app_message", label: "Messages from connected apps"),
            .init(key: "on_stock_reorder_alert", label: "Stock reorder point"),
            .init(key: "on_stock_break_alert", label: "Stock will run out"),
            .init(key: "on_billing_charge_failed", label: "Print charge failed"),
        ]),
    ]
}

struct NotificationProviderItem: Identifiable, Hashable {
    let id: Int
    var name: String
    var providerType: String
    var enabled: Bool
    var config: [String: String]
    var raw: [String: AdminJSON]
    var lastSuccess: Date?
    var lastError: String?
    var lastErrorAt: Date?

    init?(json: AdminJSON) {
        guard let o = json.object, let id = o["id"]?.int else { return nil }
        self.id = id
        name = o["name"]?.string ?? "Provider \(id)"
        providerType = o["provider_type"]?.string ?? "webhook"
        enabled = o["enabled"]?.bool ?? false
        var cfg: [String: String] = [:]
        for (k, v) in o["config"]?.object ?? [:] { if let s = v.string { cfg[k] = s } }
        config = cfg
        raw = o
        lastSuccess = AdminDate.parse(o["last_success"]?.string)
        lastError = o["last_error"]?.string
        lastErrorAt = AdminDate.parse(o["last_error_at"]?.string)
    }

    func flag(_ key: String) -> Bool { raw[key]?.bool ?? false }
    func text(_ key: String) -> String? { raw[key]?.string }

    /// LayerPal's own relay webhook. Bambuddy masks `webhook_url` in responses,
    /// so the name (set by LayerPal's setup) is the dependable signal; the URL
    /// check covers a response that does show it.
    var isThisApp: Bool {
        if providerType == "webhook" {
            if config["webhook_url"]?.contains("layerpal-relay") == true { return true }
            if let mine = ServerConfig.webhookURL?.absoluteString, config["webhook_url"] == mine { return true }
        }
        return name.hasPrefix("LayerPal")
    }

    static let typeLabels: [String: String] = [
        "ntfy": "ntfy", "pushover": "Pushover", "telegram": "Telegram", "discord": "Discord", "webhook": "Webhook",
        "email": "Email", "homeassistant": "Home Assistant", "callmebot": "CallMeBot", "bark": "Bark",
        "gotify": "Gotify", "notify": "Notify!",
    ]
    var typeLabel: String { Self.typeLabels[providerType] ?? providerType.capitalized }
}

struct ProviderConfigField: Identifiable {
    enum Kind { case text, secret, number, choice([(String, String)]), multiline }
    let key: String
    let label: String
    var placeholder = ""
    var kind: Kind = .text
    var required = false
    var id: String { key }

    /// Config keys the server expects for each `provider_type` LayerPal can create.
    static func fields(for type: String) -> [ProviderConfigField] {
        switch type {
        case "ntfy": [
                .init(key: "server", label: "Server URL", placeholder: "https://ntfy.sh"),
                .init(key: "topic", label: "Topic", placeholder: "my-bambuddy", required: true),
                .init(key: "auth_token", label: "Auth token (optional)", kind: .secret),
            ]
        case "pushover": [
                .init(key: "user_key", label: "User key", kind: .secret, required: true),
                .init(key: "app_token", label: "App token", kind: .secret, required: true),
                .init(key: "priority", label: "Priority", placeholder: "0", kind: .number),
            ]
        case "telegram": [
                .init(key: "bot_token", label: "Bot token", kind: .secret, required: true),
                .init(key: "chat_id", label: "Chat ID", required: true),
                .init(key: "message_thread_id", label: "Forum topic ID (optional)", kind: .number),
            ]
        case "discord": [
                .init(key: "webhook_url", label: "Webhook URL", placeholder: "https://discord.com/api/webhooks/...", kind: .secret, required: true),
            ]
        case "webhook": [
                .init(key: "webhook_url", label: "Webhook URL", placeholder: "https://example.com/webhook", kind: .secret, required: true),
                .init(key: "payload_format", label: "Payload format", kind: .choice([("generic", "Generic JSON"), ("slack", "Slack / Mattermost")])),
                .init(key: "auth_header", label: "Authorization header (optional)", kind: .secret),
            ]
        case "email": [
                .init(key: "smtp_server", label: "SMTP server", placeholder: "smtp.example.com", required: true),
                .init(key: "smtp_port", label: "SMTP port", placeholder: "587", kind: .number),
                .init(key: "security", label: "Security", kind: .choice([("starttls", "STARTTLS (587)"), ("ssl", "SSL/TLS (465)"), ("none", "None (25)")])),
                .init(key: "auth_enabled", label: "Authentication", kind: .choice([("true", "Enabled"), ("false", "Disabled")])),
                .init(key: "username", label: "Username"),
                .init(key: "password", label: "Password", kind: .secret),
                .init(key: "from_email", label: "From address", required: true),
                .init(key: "to_email", label: "To address", required: true),
            ]
        case "homeassistant": [
                .init(key: "service", label: "Service", placeholder: "notify.mobile_app_myphone"),
                .init(key: "data", label: "Data (JSON, optional)", kind: .multiline),
            ]
        default: []
        }
    }

    static let creatableTypes = ["ntfy", "pushover", "telegram", "discord", "webhook", "email", "homeassistant"]
}

// MARK: - Users, groups, keys

struct AdminGroupBrief: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
}

struct AdminUser: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    let email: String?
    let role: String
    let isActive: Bool
    let isAdmin: Bool
    let authSource: String?
    let groups: [AdminGroupBrief]
    let permissions: [String]?
}

struct AdminGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let permissions: [String]
    let isSystem: Bool?
    let userCount: Int?
    let restrictPrinters: Bool?
    let locations: [String]?
}

struct AdminAPIKey: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let keyPrefix: String
    let canQueue: Bool
    let canControlPrinter: Bool
    let canReadStatus: Bool
    let canManageLibrary: Bool
    let canManageInventory: Bool
    let canManageMaintenance: Bool
    let canManageArchives: Bool
    let canManageProjects: Bool
    let canAccessCloud: Bool
    let canUpdateEnergyCost: Bool
    let canSendNotifications: Bool
    let enabled: Bool
    let lastUsed: Date?
    let expiresAt: Date?

    var isThisApp: Bool { name.hasPrefix("LayerPal") }

    var scopes: [String] {
        var s: [String] = []
        if canReadStatus { s.append("Read status") }
        if canQueue { s.append("Queue") }
        if canControlPrinter { s.append("Control printers") }
        if canManageLibrary { s.append("Library") }
        if canManageInventory { s.append("Inventory") }
        if canManageMaintenance { s.append("Maintenance") }
        if canManageArchives { s.append("Archives") }
        if canManageProjects { s.append("Projects") }
        if canAccessCloud { s.append("Cloud") }
        if canUpdateEnergyCost { s.append("Energy price") }
        if canSendNotifications { s.append("Send notifications") }
        return s
    }
}

struct AdminCreatedKey: Decodable {
    let id: Int
    let name: String
    let key: String
}

// MARK: - System

struct AdminSystemInfo {
    struct Row: Identifiable { let id = UUID(); let label: String; let value: String }
    struct ConnectedPrinter: Identifiable { let id: Int; let name: String; let state: String; let model: String }

    var version = ""
    var uptime = ""
    var dbEngine = ""
    var dbSize = ""
    var archiveSize = ""
    var diskUsedPercent: Double = 0
    var diskFree = ""
    var diskTotal = ""
    var memoryPercent: Double = 0
    var memoryUsed = ""
    var memoryTotal = ""
    var cpuPercent: Double = 0
    var platform = ""
    var hostname = ""
    var printersTotal = 0
    var printersConnected = 0
    var connected: [ConnectedPrinter] = []
    var archives = 0
    var archivesCompleted = 0
    var archivesFailed = 0
    var projects = 0
    var filaments = 0
    var smartPlugs = 0
    var totalPrintTime = ""
    var totalFilamentKg: Double = 0

    init(json: AdminJSON) {
        func s(_ section: String, _ key: String) -> String { json[section]?[key]?.string ?? "–" }
        func d(_ section: String, _ key: String) -> Double { json[section]?[key]?.double ?? 0 }
        func i(_ section: String, _ key: String) -> Int { json[section]?[key]?.int ?? 0 }
        version = s("app", "version")
        uptime = s("system", "uptime_formatted")
        dbEngine = "\(s("database", "engine")) \(json["database"]?["version"]?.string ?? "")"
        dbSize = s("storage", "database_size_formatted")
        archiveSize = s("storage", "archive_size_formatted")
        diskUsedPercent = d("storage", "disk_percent_used")
        diskFree = s("storage", "disk_free_formatted")
        diskTotal = s("storage", "disk_total_formatted")
        memoryPercent = d("memory", "percent_used")
        memoryUsed = s("memory", "used_formatted")
        memoryTotal = s("memory", "total_formatted")
        cpuPercent = d("cpu", "percent")
        platform = "\(s("system", "platform")) \(json["system"]?["architecture"]?.string ?? "")"
        hostname = s("system", "hostname")
        printersTotal = i("printers", "total")
        printersConnected = i("printers", "connected")
        connected = (json["printers"]?["connected_list"]?.array ?? []).compactMap { p in
            guard let id = p["id"]?.int else { return nil }
            return ConnectedPrinter(id: id, name: p["name"]?.string ?? "Printer \(id)", state: p["state"]?.string ?? "", model: p["model"]?.string ?? "")
        }
        archives = i("database", "archives")
        archivesCompleted = i("database", "archives_completed")
        archivesFailed = i("database", "archives_failed")
        projects = i("database", "projects")
        filaments = i("database", "filaments")
        smartPlugs = i("database", "smart_plugs")
        totalPrintTime = s("database", "total_print_time_formatted")
        totalFilamentKg = d("database", "total_filament_kg")
    }
}
