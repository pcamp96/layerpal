import Foundation

// MARK: - Pipelines

struct PipePipeline: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let targetKind: String?
    let targetPrinterId: Int?
    let targetModelClass: String?
    let fanoutStrategy: String?

    var targetText: String {
        if targetKind == "specific_printer" { return targetPrinterId.map { "Printer #\($0)" } ?? "One printer" }
        return targetModelClass.map { "\($0) class" } ?? "Any printer of the model"
    }

    var fanoutText: String {
        switch fanoutStrategy {
        case "fill_one_first": "Fill one printer first"
        case "round_robin": "Round robin"
        default: "Spread across printers"
        }
    }
}

struct PipeJob: Decodable, Identifiable, Hashable {
    let id: Int
    let copyIndex: Int?
    let assignedPrinterName: String?
    let queueEntryId: Int?
    let status: String
    let errorMessage: String?
    let dispatchedAt: Date?
    let completedAt: Date?
}

struct PipeRun: Decodable, Identifiable, Hashable {
    let id: Int
    let pipelineId: Int?
    let pipelineName: String?
    let sourceFilename: String?
    let parentRunId: Int?
    let copies: Int
    let copiesCompleted: Int?
    let copiesFailed: Int?
    let copiesCancelled: Int?
    let copiesInProgress: Int?
    let status: String
    let eligibilityOverridden: Bool?
    let errorMessage: String?
    let createdAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let jobs: [PipeJob]?
    let targetKind: String?
    let targetModelClass: String?

    var isActive: Bool { ["queued", "slicing", "dispatching", "in_progress"].contains(status) }
    var canRetry: Bool { !isActive && ((copiesFailed ?? 0) + (copiesCancelled ?? 0)) > 0 }

    var statusLabel: String { PipeStatus.label(status) }
    var statusTint: PipeStatus.Tint { PipeStatus.tint(status) }
}

struct PipeRunPage: Decodable {
    let runs: [PipeRun]
    let total: Int?
}

enum PipeStatus {
    enum Tint { case good, busy, bad, warn, neutral }

    static func label(_ status: String) -> String {
        switch status {
        case "partial_failure": "Partly failed"
        case "in_progress": "In progress"
        case "awaiting_printer": "Waiting for printer"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func tint(_ status: String) -> Tint {
        switch status {
        case "completed": .good
        case "failed": .bad
        case "partial_failure": .warn
        case "cancelled", "unknown": .neutral
        default: .busy
        }
    }
}

/// Eligibility report: `POST /slicer-pipelines/{id}/check-eligibility`, or the body of a 409 from /run.
struct PipeEligibility {
    struct Issue { let kind: String; let slot: Int?; let expected: String?; let actual: String? }
    struct PrinterReport { let name: String; let ok: Bool; let issues: [Issue] }

    let ok: Bool
    let issues: [Issue]
    let reports: [PrinterReport]

    init(json: AdminJSON) {
        ok = json["ok"]?.bool ?? false
        issues = Self.issues(json["issues"])
        reports = (json["printer_reports"]?.array ?? []).map {
            PrinterReport(name: $0["printer_name"]?.string ?? "Printer", ok: $0["ok"]?.bool ?? false, issues: Self.issues($0["issues"]))
        }
    }

    private static func issues(_ json: AdminJSON?) -> [Issue] {
        (json?.array ?? []).map {
            Issue(kind: $0["kind"]?.string ?? "unknown", slot: $0["slot_index"]?.int,
                  expected: $0["expected"]?.string, actual: $0["actual"]?.string)
        }
    }

    static func describe(_ issue: Issue) -> String {
        let slot = issue.slot.map { " (slot \($0 + 1))" } ?? ""
        let detail = (issue.expected != nil || issue.actual != nil) ? ": wants \(issue.expected ?? "?"), has \(issue.actual ?? "?")" : ""
        switch issue.kind {
        case "printer_not_set": return "The pipeline has no printer set"
        case "printer_not_found": return "The target printer no longer exists"
        case "printer_disabled": return "The target printer is disabled"
        case "printer_offline": return "The target printer is offline"
        case "filament_type_mismatch": return "Filament type doesn't match" + slot + detail
        case "filament_color_mismatch": return "Filament color doesn't match" + slot + detail
        case "ams_slot_missing": return "AMS slot is missing" + slot
        case "filament_unverified": return "Loaded filament can't be verified" + slot
        case "no_class_matches": return "No printer of that model exists"
        case "class_not_set": return "The pipeline has no model class set"
        default: return issue.kind.replacingOccurrences(of: "_", with: " ").capitalized + slot
        }
    }

    /// Flat lines for display: class-level issues, then each printer's problems.
    var lines: [String] {
        var out = issues.map(Self.describe)
        for report in reports where !report.ok {
            if report.issues.isEmpty { out.append("\(report.name): not eligible") }
            for issue in report.issues { out.append("\(report.name): " + Self.describe(issue)) }
        }
        return out
    }
}

// MARK: - Manyfold

struct MfyStatus: Decodable {
    let configured: Bool
    let url: String
}

struct MfyModelSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct MfyModelPage: Decodable {
    let total: Int
    let page: Int
    let hasNext: Bool
    let hasPrevious: Bool
    let models: [MfyModelSummary]
}

struct MfyLibraryRef: Decodable, Hashable {
    let id: Int
    let filename: String
    let folderId: Int?
}

struct MfyFile: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let mime: String?
    let importable: Bool
    let libraryFile: MfyLibraryRef?
}

struct MfyModel: Decodable, Identifiable {
    let id: String
    let name: String
    let caption: String?
    let description: String?
    let license: String?
    let tags: [String]?
    let url: String?
    let hasPreview: Bool?
    let files: [MfyFile]
}

struct MfyImportResult: Decodable {
    let libraryFileId: Int
    let filename: String
    let folderId: Int?
    let wasExisting: Bool
}

// MARK: - Virtual printers

struct VPStatus: Decodable, Hashable {
    let running: Bool?
    let pendingFiles: Int?
}

struct VPrinter: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let enabled: Bool
    let mode: String?
    let model: String?
    let modelName: String?
    let accessCodeSet: Bool?
    let serial: String?
    let targetPrinterId: Int?
    let autoDispatch: Bool?
    let queueForceColorMatch: Bool?
    let saveAmsMapping: Bool?
    let gcodeInjection: Bool?
    let bindIp: String?
    let remoteInterfaceIp: String?
    let tailscaleDisabled: Bool?
    let status: VPStatus?

    var modeLabel: String {
        switch mode {
        case "archive": "Archive"
        case "queue": "Queue"
        case "review": "Review"
        case "proxy": "Proxy"
        case let other?: other.capitalized
        default: "Unknown"
        }
    }
}

struct VPTailscale: Decodable {
    let available: Bool
    let fqdn: String?
    let hostname: String?
    let tailnetName: String?
    let tailscaleIps: [String]?
    let error: String?
}

struct VPCheck: Decodable, Identifiable, Hashable {
    let id: String
    let status: String
}

struct VPDiagnostic: Decodable {
    let overall: String
    let checks: [VPCheck]
}

// MARK: - Camera tokens

struct TokRecord: Decodable, Identifiable, Hashable {
    let id: Int
    let userId: Int?
    let name: String
    let scope: String
    let lookupPrefix: String?
    let createdAt: Date?
    let expiresAt: Date?
    let lastUsedAt: Date?
    /// Present only in the create response.
    let token: String?

    var scopeLabel: String {
        switch scope {
        case "camwall": "Cam Wall"
        case "overlay": "Streaming overlay"
        case "camera_stream": "Camera stream"
        default: scope
        }
    }

    var isExpired: Bool { (expiresAt ?? .distantFuture) <= Date() }
}

// MARK: - External links

struct ExtLink: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let url: String
    let icon: String?
    let openInNewTab: Bool?
    let customIcon: String?
    let sortOrder: Int?
    let badgeCount: Int?

    /// Bambuddy stores a Lucide icon name; map the common ones to SF Symbols.
    var symbol: String {
        let map = ["link": "link", "globe": "globe", "home": "house", "server": "server.rack", "camera": "camera", "video": "video",
                   "printer": "printer", "box": "shippingbox", "package": "shippingbox", "shopping-cart": "cart", "cart": "cart",
                   "book": "book", "file-text": "doc.text", "settings": "gearshape", "wrench": "wrench", "chart-bar": "chart.bar",
                   "bar-chart": "chart.bar", "database": "cylinder", "cloud": "cloud", "github": "chevron.left.forwardslash.chevron.right",
                   "mail": "envelope", "calendar": "calendar", "image": "photo", "music": "music.note", "cpu": "cpu",
                   "wifi": "wifi", "lock": "lock", "key": "key", "terminal": "terminal", "monitor": "display", "layers": "square.stack.3d.up",
                   "zap": "bolt", "bell": "bell", "star": "star", "heart": "heart", "users": "person.2", "user": "person"]
        return map[(icon ?? "link").lowercased()] ?? "link"
    }
}
