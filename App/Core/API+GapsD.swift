import Foundation

/// Gaps D: virtual printer create/delete and CA certificate, GitHub restore, plate-detection ROI
/// and printer firmware upload (Bambuddy 1.3.0). The server never grants `github:restore`,
/// `firmware:update` or any write here to an API key, so callers pass the admin session's JWT as `bearer`.
extension APIClient {
    // MARK: Virtual printers

    /// POST /virtual-printers (settings:update). 400 on bad mode/model/access code (8 chars)/bind IP in use.
    func vpCreate(_ body: [String: AdminJSON], bearer: String?) async throws {
        _ = try await opsRequest("virtual-printers", method: "POST", body: .object(body), bearer: bearer)
    }

    /// DELETE /virtual-printers/{id} (settings:update) -> {detail, id}
    func vpDelete(_ id: Int, bearer: String?) async throws {
        _ = try await opsRequest("virtual-printers/\(id)", method: "DELETE", bearer: bearer)
    }

    /// GET /virtual-printers/ca-certificate (settings:read) -> {pem, fingerprint_sha256, not_valid_after}
    func vpCACertificate(bearer: String?) async throws -> VPCACertificate {
        let j = try await opsJSON("virtual-printers/ca-certificate", bearer: bearer)
        return VPCACertificate(pem: j["pem"]?.string ?? "", fingerprint: j["fingerprint_sha256"]?.string ?? "",
                               notValidAfter: j["not_valid_after"]?.string)
    }

    /// GET /settings/network-interfaces (settings:read) -> {interfaces: [{name, ip, netmask, subnet, is_alias, label}]}
    func vpNetworkInterfaces(bearer: String?) async throws -> [VPInterface] {
        let j = try await opsJSON("settings/network-interfaces", bearer: bearer)
        return (j["interfaces"]?.array ?? []).compactMap { item in
            guard let ip = item["ip"]?.string, !ip.isEmpty else { return nil }
            return VPInterface(name: item["name"]?.string ?? "", ip: ip, label: item["label"]?.string ?? item["name"]?.string ?? "")
        }
    }

    // MARK: GitHub restore (github:restore; admin session)

    /// GET /github-backup/commits?limit= -> {success, message, branch, commits: [{sha, message, author, date}]}
    func githubCommits(limit: Int = 30, bearer: String?) async throws -> GitCommitList {
        let j = try await opsJSON("github-backup/commits", query: [URLQueryItem(name: "limit", value: String(limit))],
                                  bearer: bearer, timeout: 90)
        let commits = (j["commits"]?.array ?? []).map(GitCommit.init(json:))
        return GitCommitList(success: j["success"]?.bool ?? false, message: j["message"]?.string ?? "",
                             branch: j["branch"]?.string ?? "", commits: commits)
    }

    /// GET /github-backup/restore/preview?ref= -> {success, message, ref, commit, categories: [{category, available, item_count, detail}]}
    func githubRestorePreview(ref: String, bearer: String?) async throws -> GitRestorePreview {
        let j = try await opsJSON("github-backup/restore/preview", query: [URLQueryItem(name: "ref", value: ref)],
                                  bearer: bearer, timeout: 120)
        return GitRestorePreview(json: j)
    }

    /// POST /github-backup/restore {ref, categories, overwrite_existing}. Each category also needs its own
    /// write permission (settings:update, inventory:update, archives:update_all, kprofiles:update).
    func githubRestore(ref: String, categories: [String], overwrite: Bool, bearer: String?) async throws -> GitRestoreResult {
        let body: [String: AdminJSON] = ["ref": .string(ref), "categories": .array(categories.map { .string($0) }),
                                         "overwrite_existing": .bool(overwrite)]
        return GitRestoreResult(json: try await opsJSON("github-backup/restore", method: "POST", body: .object(body),
                                                        bearer: bearer, timeout: 900))
    }

    // MARK: Plate-detection ROI

    /// GET /printers/{id} (printers:read) -> plate_detection_roi {x,y,w,h} or null.
    func plateROI(_ printerId: Int, bearer: String?) async throws -> PlateROI? {
        let j = try await opsJSON("printers/\(printerId)", bearer: bearer)
        guard let roi = j["plate_detection_roi"], roi.object != nil,
              let x = roi["x"]?.double, let y = roi["y"]?.double, let w = roi["w"]?.double, let h = roi["h"]?.double else { return nil }
        return PlateROI(x: x, y: y, w: w, h: h)
    }

    /// PATCH /printers/{id} {plate_detection_roi: {x,y,w,h}} (printers:update). `nil` clears it.
    func setPlateROI(_ printerId: Int, roi: PlateROI?, bearer: String?) async throws {
        let value: AdminJSON = roi.map { .object(["x": .double($0.x), "y": .double($0.y), "w": .double($0.w), "h": .double($0.h)]) } ?? .null
        _ = try await opsRequest("printers/\(printerId)", method: "PATCH", body: .object(["plate_detection_roi": value]), bearer: bearer)
    }

    /// GET /printers/{id}/camera/check-plate (camera:view). 503 when OpenCV isn't installed on the server.
    func checkPlate(_ printerId: Int, bearer: String?) async throws -> PlateCheckResult {
        PlateCheckResult(json: try await opsJSON("printers/\(printerId)/camera/check-plate", bearer: bearer, timeout: 60))
    }

    // MARK: Printer firmware upload (LAN-only helper)

    /// GET /firmware/updates/{id}/prepare?version= (firmware:read): SD card, space, busy checks.
    func firmwarePrepare(_ printerId: Int, version: String?, bearer: String?) async throws -> FirmwarePrepare {
        FirmwarePrepare(json: try await opsJSON("firmware/updates/\(printerId)/prepare", query: Self.versionQuery(version),
                                                bearer: bearer, timeout: 60))
    }

    /// POST /firmware/updates/{id}/upload?version= (firmware:update) -> {started, message}. Runs in the background.
    func firmwareStartUpload(_ printerId: Int, version: String?, bearer: String?) async throws -> (started: Bool, message: String) {
        let j = try await opsJSON("firmware/updates/\(printerId)/upload", method: "POST", query: Self.versionQuery(version),
                                  bearer: bearer, timeout: 90)
        return (j["started"]?.bool ?? false, j["message"]?.string ?? "")
    }

    /// GET /firmware/updates/{id}/upload/status (firmware:read)
    func firmwareUploadStatus(_ printerId: Int, bearer: String?) async throws -> FirmwareUploadState {
        FirmwareUploadState(json: try await opsJSON("firmware/updates/\(printerId)/upload/status", bearer: bearer))
    }

    private static func versionQuery(_ version: String?) -> [URLQueryItem] {
        guard let version, !version.isEmpty else { return [] }
        return [URLQueryItem(name: "version", value: version)]
    }
}

// MARK: - Models

struct VPCACertificate {
    let pem: String
    let fingerprint: String
    let notValidAfter: String?
}

struct VPInterface: Identifiable, Hashable {
    let name: String
    let ip: String
    let label: String
    var id: String { ip }
}

struct GitCommit: Identifiable, Hashable {
    let sha: String
    let message: String
    let author: String
    let date: Date?
    var id: String { sha }

    init(json: AdminJSON) {
        sha = json["sha"]?.string ?? ""
        message = json["message"]?.string ?? ""
        author = json["author"]?.string ?? ""
        date = json["date"]?.string.flatMap { Self.parse($0) }
    }

    private static func parse(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: raw) ?? fractional.date(from: raw)
    }
}

struct GitCommitList {
    let success: Bool
    let message: String
    let branch: String
    let commits: [GitCommit]
}

struct GitRestoreCategory: Identifiable, Hashable {
    let category: String
    let available: Bool
    let itemCount: Int
    let detail: String?
    var id: String { category }

    var title: String {
        switch category {
        case "kprofiles": "K-profiles"
        case "settings": "App settings"
        case "spools": "Spool inventory"
        case "archives": "Print archive history"
        default: category.capitalized
        }
    }

    /// The write permission the server requires on top of `github:restore`.
    var permission: String? {
        switch category {
        case "settings": "settings:update"
        case "spools": "inventory:update"
        case "archives": "archives:update_all"
        case "kprofiles": "kprofiles:update"
        default: nil
        }
    }
}

struct GitRestorePreview {
    let success: Bool
    let message: String
    let ref: String
    let commit: GitCommit?
    let categories: [GitRestoreCategory]

    init(json: AdminJSON) {
        success = json["success"]?.bool ?? false
        message = json["message"]?.string ?? ""
        ref = json["ref"]?.string ?? "HEAD"
        commit = json["commit"].flatMap { $0.object == nil ? nil : GitCommit(json: $0) }
        categories = (json["categories"]?.array ?? []).map {
            GitRestoreCategory(category: $0["category"]?.string ?? "", available: $0["available"]?.bool ?? false,
                               itemCount: $0["item_count"]?.int ?? 0, detail: $0["detail"]?.string)
        }
    }
}

struct GitRestoreResult {
    struct Line: Identifiable {
        let category: String
        let restored: Int
        let skipped: Int
        let failed: Int
        let notes: [String]
        var id: String { category }
    }

    let success: Bool
    let message: String
    let lines: [Line]

    init(json: AdminJSON) {
        success = json["success"]?.bool ?? false
        message = json["message"]?.string ?? ""
        lines = (json["results"]?.object ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            Line(category: key, restored: value["restored"]?.int ?? 0, skipped: value["skipped"]?.int ?? 0,
                 failed: value["failed"]?.int ?? 0, notes: (value["notes"]?.array ?? []).compactMap { $0["message"]?.string })
        }
    }
}

struct PlateROI: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    /// The area the server uses when none is saved.
    static let standard = PlateROI(x: 0.15, y: 0.35, w: 0.70, h: 0.55)
}

struct PlateCheckResult {
    let isEmpty: Bool
    let confidence: Double
    let differencePercent: Double
    let message: String
    let needsCalibration: Bool
    let failureReason: String?
    let lightWarning: Bool
    let referenceCount: Int

    init(json: AdminJSON) {
        isEmpty = json["is_empty"]?.bool ?? false
        confidence = json["confidence"]?.double ?? 0
        differencePercent = json["difference_percent"]?.double ?? 0
        message = json["message"]?.string ?? ""
        needsCalibration = json["needs_calibration"]?.bool ?? false
        failureReason = json["failure_reason"]?.string
        lightWarning = json["light_warning"]?.bool ?? false
        referenceCount = json["reference_count"]?.int ?? 0
    }
}

struct FirmwarePrepare {
    let canProceed: Bool
    let sdCardPresent: Bool
    let freeSpace: Int64
    let spaceSufficient: Bool
    let currentVersion: String?
    let latestVersion: String?
    let targetVersion: String?
    let filename: String?
    let errors: [String]

    init(json: AdminJSON) {
        canProceed = json["can_proceed"]?.bool ?? false
        sdCardPresent = json["sd_card_present"]?.bool ?? false
        freeSpace = Int64(json["sd_card_free_space"]?.int ?? -1)
        spaceSufficient = json["space_sufficient"]?.bool ?? false
        currentVersion = json["current_version"]?.string
        latestVersion = json["latest_version"]?.string
        targetVersion = json["target_version"]?.string
        filename = json["firmware_filename"]?.string
        errors = (json["errors"]?.array ?? []).compactMap(\.string)
    }
}

struct FirmwareUploadState {
    /// idle, preparing, downloading, uploading, complete, error
    let status: String
    let progress: Int
    let message: String
    let error: String?
    let version: String?

    init(json: AdminJSON) {
        status = json["status"]?.string ?? "idle"
        progress = json["progress"]?.int ?? 0
        message = json["message"]?.string ?? ""
        error = json["error"]?.string
        version = json["firmware_version"]?.string
    }
}

// MARK: - Virtual printer models

struct VPModelOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

extension APIClient {
    /// GET /virtual-printers -> `models` {ssdp code: display name} (settings:read)
    func vpModels(bearer: String?) async throws -> [VPModelOption] {
        let j = try await opsJSON("virtual-printers", bearer: bearer)
        return (j["models"]?.object ?? [:]).compactMap { code, name in name.string.map { VPModelOption(code: code, name: $0) } }
            .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }
}
