import Foundation

// Response models for phase 4D. Parsed from AdminJSON so a missing or renamed field never
// fails the whole screen. Field names are from the backend routes and schemas.

struct OpsActionResult {
    var success: Bool
    var message: String
    var filename: String?
    var diagnosisMessage: String?
    var commitSHA: String?
    var filesChanged: Int?

    init(json: AdminJSON) {
        // /updates/apply and the backup routes answer {success, message}; /restore may omit success.
        success = json["success"]?.bool ?? true
        message = json["message"]?.string ?? ""
        filename = json["filename"]?.string
        diagnosisMessage = json["diagnosis"]?["message"]?.string
        commitSHA = json["commit_sha"]?.string
        filesChanged = json["files_changed"]?.int
    }
}

// MARK: Discovery

struct OpsDiscoveryInfo {
    var isDocker = false
    var ssdpRunning = false
    var scanRunning = false
    var subnets: [String] = []

    init(json: AdminJSON) {
        isDocker = json["is_docker"]?.bool ?? false
        ssdpRunning = json["ssdp_running"]?.bool ?? false
        scanRunning = json["scan_running"]?.bool ?? false
        subnets = (json["subnets"]?.array ?? []).compactMap { $0.string }
    }
}

struct OpsDiscoveredPrinter: Identifiable, Hashable {
    let serial: String
    let name: String
    let ipAddress: String
    let model: String?
    var id: String { serial + ipAddress }

    init?(json: AdminJSON) {
        guard let serial = json["serial"]?.string, let ip = json["ip_address"]?.string else { return nil }
        self.serial = serial
        name = json["name"]?.string ?? ""
        ipAddress = ip
        model = json["model"]?.string
    }

    /// The discovered model mapped to an add-printer picker value, or "".
    var pickerModel: String {
        guard let model, !model.isEmpty else { return "" }
        if AdminPrinterModels.all.contains(model) { return model }
        if let name = Printer.modelNames[model], AdminPrinterModels.all.contains(name) { return name }
        return ""
    }

    /// Placeholder serials ("unknown-…") aren't real; the user must type the actual one.
    var realSerial: String { serial.hasPrefix("unknown-") ? "" : serial }
}

// MARK: Camera

struct OpsCameraTest {
    var success: Bool
    var message: String?
    var error: String?
    var resolution: String?
    var liveView: Bool

    init(json: AdminJSON) {
        success = json["success"]?.bool ?? false
        message = json["message"]?.string
        error = json["error"]?.string
        resolution = json["resolution"]?.string
        liveView = json["live_view"]?.bool ?? false
    }
}

struct OpsCameraStage: Identifiable {
    let name: String
    let status: String
    let durationMs: Int
    let code: String?
    var id: String { name }

    var label: String {
        switch name {
        case "tcp_reachable": "Printer on the network"
        case "first_frame": "Image received"
        case "live_stream_active": "Live stream running"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// What a stage failure code from the diagnose endpoint means.
    var codeHint: String? {
        switch code {
        case "tcp_timeout": "The printer didn't answer in time."
        case "tcp_refused": "The printer refused the connection."
        case "tcp_unreachable": "The printer's address can't be reached."
        case "no_frame": "Connected, but no frame arrived."
        case "capture_exception": "Capturing a frame raised an error."
        case "coalesced_capture": "Frame came from a capture already in progress, so the time isn't a connection time."
        default: nil
        }
    }
}

struct OpsCameraDiagnosis {
    var protocolName: String
    var port: Int
    var profile: String
    var overallOK: Bool
    var stages: [OpsCameraStage]
    var summaryCode: String

    init(json: AdminJSON) {
        protocolName = json["protocol"]?.string ?? ""
        port = json["port"]?.int ?? 0
        profile = json["profile"]?.string ?? ""
        overallOK = json["overall_status"]?.string == "ok"
        summaryCode = json["summary_code"]?.string ?? ""
        stages = (json["stages"]?.array ?? []).map {
            OpsCameraStage(name: $0["name"]?.string ?? "stage", status: $0["status"]?.string ?? "skipped",
                           durationMs: $0["duration_ms"]?.int ?? 0, code: $0["code"]?.string)
        }
    }

    /// Remediation text for the diagnosis's `summary_code`.
    var summary: String {
        switch summaryCode {
        case "all_ok": "The camera is working. Every check passed."
        case "live_stream_active_healthy": "A live stream is already running and sending fresh images, so no extra test was needed."
        case "printer_unreachable": "Can't reach the printer. Check its IP address and your network, and make sure the printer is turned on."
        case "camera_port_closed": "The printer answers, but its camera port is closed. Turn on LAN-only mode and Developer Mode on the printer."
        case "no_frame": "Connected to the camera, but no image came through. Try again, and check that the camera is turned on in the printer's settings."
        default: "The check didn't finish for an unknown reason. The server's support log has the details."
        }
    }
}

struct OpsUSBCamera: Identifiable {
    let device: String
    let name: String
    let driver: String?
    let capabilities: [String]
    let formats: [String]
    var id: String { device }

    init?(json: AdminJSON) {
        guard let device = json["device"]?.string else { return nil }
        self.device = device
        name = json["name"]?.string ?? device
        driver = json["driver"]?.string
        capabilities = (json["capabilities"]?.array ?? []).compactMap { $0.string }
        formats = (json["formats"]?.array ?? []).compactMap { $0.string }
    }
}

// MARK: Local backup

struct OpsLocalBackupStatus {
    var isRunning = false
    var lastBackupAt: Date?
    var lastStatus: String?
    var lastMessage: String?
    var nextRun: Date?
    var enabled = false
    var schedule = "daily"
    var time = "03:00"
    var retention = 5
    var path = ""
    var defaultPath = ""
    var timezone = ""

    init(json: AdminJSON) {
        isRunning = json["is_running"]?.bool ?? false
        lastBackupAt = AdminDate.parse(json["last_backup_at"]?.string)
        lastStatus = json["last_status"]?.string
        lastMessage = json["last_message"]?.string
        nextRun = AdminDate.parse(json["next_run"]?.string)
        enabled = json["enabled"]?.bool ?? false
        schedule = json["schedule"]?.string ?? "daily"
        time = json["time"]?.string ?? "03:00"
        retention = json["retention"]?.int ?? 5
        path = json["path"]?.string ?? ""
        defaultPath = json["default_path"]?.string ?? ""
        timezone = json["timezone"]?.string ?? ""
    }
}

struct OpsPathCheck {
    var writable: Bool
    var path: String
    var code: String
    var message: String
    var detail: String?
    var remedy: String?
    var warning: String?

    init(json: AdminJSON) {
        writable = json["writable"]?.bool ?? false
        path = json["path"]?.string ?? ""
        code = json["code"]?.string ?? ""
        message = json["message"]?.string ?? ""
        detail = json["detail"]?.string
        remedy = json["remedy"]?.string
        warning = json["warning"]?.string
    }
}

struct OpsBackupFile: Identifiable, Hashable {
    let filename: String
    let size: Int64
    let createdAt: Date?
    var id: String { filename }

    init?(json: AdminJSON) {
        guard let name = json["filename"]?.string else { return nil }
        filename = name
        size = Int64(json["size"]?.double ?? 0)
        createdAt = AdminDate.parse(json["created_at"]?.string)
    }
}

// MARK: GitHub backup

struct OpsGitConfig {
    var repositoryURL = ""
    var hasToken = false
    var branch = "main"
    var provider = "github"
    var allowInsecureHTTP = false
    var scheduleEnabled = false
    var scheduleType = "daily"
    var backupKProfiles = true
    var backupCloudProfiles = true
    var backupSettings = false
    var backupSpools = false
    var backupArchives = false
    var enabled = true
    var lastBackupAt: Date?
    var lastStatus: String?
    var lastMessage: String?
    var lastCommit: String?
    var nextRun: Date?

    init() {}

    init(json: AdminJSON) {
        repositoryURL = json["repository_url"]?.string ?? ""
        hasToken = json["has_token"]?.bool ?? false
        branch = json["branch"]?.string ?? "main"
        provider = json["provider"]?.string ?? "github"
        allowInsecureHTTP = json["allow_insecure_http"]?.bool ?? false
        scheduleEnabled = json["schedule_enabled"]?.bool ?? false
        scheduleType = json["schedule_type"]?.string ?? "daily"
        backupKProfiles = json["backup_kprofiles"]?.bool ?? true
        backupCloudProfiles = json["backup_cloud_profiles"]?.bool ?? true
        backupSettings = json["backup_settings"]?.bool ?? false
        backupSpools = json["backup_spools"]?.bool ?? false
        backupArchives = json["backup_archives"]?.bool ?? false
        enabled = json["enabled"]?.bool ?? true
        lastBackupAt = AdminDate.parse(json["last_backup_at"]?.string)
        lastStatus = json["last_backup_status"]?.string
        lastMessage = json["last_backup_message"]?.string
        lastCommit = json["last_backup_commit_sha"]?.string
        nextRun = AdminDate.parse(json["next_scheduled_run"]?.string)
    }
}

struct OpsGitStatus {
    var configured = false
    var enabled = false
    var isRunning = false
    var restoreRunning = false
    var progress: String?

    init(json: AdminJSON) {
        configured = json["configured"]?.bool ?? false
        enabled = json["enabled"]?.bool ?? false
        isRunning = json["is_running"]?.bool ?? false
        restoreRunning = json["restore_running"]?.bool ?? false
        progress = json["progress"]?.string
    }
}

struct OpsGitTest {
    var success: Bool
    var message: String
    var repoName: String?
    var isPrivate: Bool?

    init(json: AdminJSON) {
        success = json["success"]?.bool ?? false
        message = json["message"]?.string ?? ""
        repoName = json["repo_name"]?.string
        isPrivate = json["is_private"]?.bool
    }
}

struct OpsGitLog: Identifiable {
    let id: Int
    let startedAt: Date?
    let completedAt: Date?
    let status: String
    let trigger: String
    let commitSHA: String?
    let filesChanged: Int
    let errorMessage: String?

    init?(json: AdminJSON) {
        guard let id = json["id"]?.int else { return nil }
        self.id = id
        startedAt = AdminDate.parse(json["started_at"]?.string)
        completedAt = AdminDate.parse(json["completed_at"]?.string)
        status = json["status"]?.string ?? "unknown"
        trigger = json["trigger"]?.string ?? ""
        commitSHA = json["commit_sha"]?.string
        filesChanged = json["files_changed"]?.int ?? 0
        errorMessage = json["error_message"]?.string
    }
}

// MARK: Updates

struct OpsUpdateCheck {
    var updateAvailable = false
    var currentVersion = ""
    var latestVersion: String?
    var releaseName: String?
    var releaseNotes: String?
    var releaseURL: URL?
    var publishedAt: Date?
    var updateMethod: String?
    var installerDownloadURL: URL?
    var message: String?
    var error: String?
    var retryAfter: Int?

    init(json: AdminJSON) {
        updateAvailable = json["update_available"]?.bool ?? false
        currentVersion = json["current_version"]?.string ?? ""
        latestVersion = json["latest_version"]?.string
        releaseName = json["release_name"]?.string
        releaseNotes = json["release_notes"]?.string
        releaseURL = json["release_url"]?.string.flatMap(URL.init(string:))
        publishedAt = AdminDate.parse(json["published_at"]?.string)
        updateMethod = json["update_method"]?.string
        installerDownloadURL = json["installer_download_url"]?.string.flatMap(URL.init(string:))
        message = json["message"]?.string
        error = json["error"]?.string
        retryAfter = json["retry_after_seconds"]?.int
    }
}

struct OpsUpdateStatus {
    var status = "idle"
    var progress = 0
    var message = ""
    var error: String?

    init(json: AdminJSON) {
        status = json["status"]?.string ?? "idle"
        progress = json["progress"]?.int ?? 0
        message = json["message"]?.string ?? ""
        error = json["error"]?.string
    }
}

// MARK: Support

struct OpsLogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let level: String
    let logger: String
    let message: String
}

struct OpsLogPage {
    var entries: [OpsLogEntry] = []
    var totalInFile = 0

    init(json: AdminJSON) {
        totalInFile = json["total_in_file"]?.int ?? 0
        entries = (json["entries"]?.array ?? []).map {
            OpsLogEntry(timestamp: $0["timestamp"]?.string ?? "", level: $0["level"]?.string ?? "",
                        logger: $0["logger_name"]?.string ?? "", message: $0["message"]?.string ?? "")
        }
    }

    /// Plain text for the share sheet, oldest first.
    var asText: String {
        entries.reversed().map { "\($0.timestamp) \($0.level) \($0.logger): \($0.message)" }.joined(separator: "\n")
    }
}

struct OpsBugReportResult {
    var success: Bool
    var message: String
    var issueURL: URL?
    var issueNumber: Int?

    init(json: AdminJSON) {
        success = json["success"]?.bool ?? false
        message = json["message"]?.string ?? ""
        issueURL = json["issue_url"]?.string.flatMap(URL.init(string:))
        issueNumber = json["issue_number"]?.int
    }
}

// MARK: Purge

struct OpsPurgePreview {
    var count = 0
    var totalBytes: Int64 = 0
    var samples: [String] = []

    init(json: AdminJSON) {
        count = json["count"]?.int ?? 0
        totalBytes = Int64(json["total_bytes"]?.double ?? 0)
        samples = (json["sample_filenames"]?.array ?? []).compactMap { $0.string }
    }
}

struct OpsArchivePurgeSettings: Equatable {
    var enabled = false
    var days = 365
    var purgeStats = false

    init() {}

    init(json: AdminJSON) {
        enabled = json["enabled"]?.bool ?? false
        days = json["days"]?.int ?? 365
        purgeStats = json["purge_stats"]?.bool ?? false
    }
}

struct OpsTrashSettings: Equatable {
    var retentionDays = 30
    var autoPurgeEnabled = false
    var autoPurgeDays = 90
    var autoPurgeIncludeNeverPrinted = true

    init() {}

    init(json: AdminJSON) {
        retentionDays = json["retention_days"]?.int ?? 30
        autoPurgeEnabled = json["auto_purge_enabled"]?.bool ?? false
        autoPurgeDays = json["auto_purge_days"]?.int ?? 90
        autoPurgeIncludeNeverPrinted = json["auto_purge_include_never_printed"]?.bool ?? true
    }
}

// MARK: System

struct OpsFinding: Identifiable {
    let id: String
    let severity: String
    let category: String
    let count: Int
    let firstSeen: String
    let lastSeen: String
    let sample: String
    let wikiAnchor: String
}

struct OpsHealth {
    var findings: [OpsFinding] = []
    var scanned = 0
    var logAvailable = true

    init(json: AdminJSON) {
        scanned = json["scanned_entries"]?.int ?? 0
        logAvailable = json["log_available"]?.bool ?? true
        findings = (json["findings"]?.array ?? []).map {
            OpsFinding(id: $0["signature_id"]?.string ?? UUID().uuidString, severity: $0["severity"]?.string ?? "warning",
                       category: $0["category"]?.string ?? "", count: $0["count"]?.int ?? 0,
                       firstSeen: $0["first_seen"]?.string ?? "", lastSeen: $0["last_seen"]?.string ?? "",
                       sample: $0["sample"]?.string ?? "", wikiAnchor: $0["wiki_anchor"]?.string ?? "")
        }
    }
}

struct OpsStorageCategory: Identifiable {
    let key: String
    let label: String
    let bytes: Int64
    let formatted: String
    let percent: Double
    var id: String { key }
}

struct OpsStorage {
    var total = ""
    var totalBytes: Int64 = 0
    var categories: [OpsStorageCategory] = []
    var other: [OpsStorageCategory] = []
    var scanErrors = 0
    var generatedAt: Date?
    var cacheHit = false

    init(json: AdminJSON) {
        total = json["total_formatted"]?.string ?? ""
        totalBytes = Int64(json["total_bytes"]?.double ?? 0)
        scanErrors = json["scan_errors"]?.int ?? 0
        generatedAt = AdminDate.parse(json["generated_at"]?.string)
        cacheHit = json["cache"]?["hit"]?.bool ?? false
        func parse(_ item: AdminJSON, key: String, label: String) -> OpsStorageCategory {
            OpsStorageCategory(key: item[key]?.string ?? item["bucket"]?.string ?? UUID().uuidString,
                               label: item[label]?.string ?? "",
                               bytes: Int64(item["bytes"]?.double ?? 0), formatted: item["formatted"]?.string ?? "",
                               percent: item["percent_of_total"]?.double ?? 0)
        }
        categories = (json["categories"]?.array ?? []).map { parse($0, key: "key", label: "label") }
        other = (json["other_breakdown"]?.array ?? []).map { parse($0, key: "bucket", label: "label") }
    }
}

struct OpsDBPool {
    var dialect = ""
    var checkedOut: Int?
    var checkedIn: Int?
    var overflow: Int?
    var currentSize: Int?
    var poolSize: Int?
    var maxOverflow: Int?
    var serverMax: Int?

    init(json: AdminJSON) {
        dialect = json["dialect"]?.string ?? ""
        checkedOut = json["checked_out"]?.int
        checkedIn = json["checked_in"]?.int
        overflow = json["overflow"]?.int
        currentSize = json["current_size"]?.int
        poolSize = json["config"]?["pool_size"]?.int
        maxOverflow = json["config"]?["max_overflow"]?.int
        serverMax = json["server_limits"]?["max_connections"]?.int
    }
}
