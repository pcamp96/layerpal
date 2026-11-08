import Foundation
import SwiftUI

// Subsets of Bambuddy 1.3 API responses. Optional almost everywhere so a
// server update that drops or renames a field degrades instead of failing.

struct Printer: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let model: String?
    let location: String?
    let isActive: Bool?
    let serialNumber: String?

    var displayModel: String {
        guard let model else { return "" }
        return Self.modelNames[model] ?? model
    }

    /// Internal model code -> display name. Codes are the `model_id`s in BambuStudio's printer definitions.
    static let modelNames: [String: String] = [
        "BL-P001": "X1C", "BL-P002": "X1", "C13": "X1E",
        "C11": "P1P", "C12": "P1S", "N7": "P2S", "N6": "X2D",
        "N1": "A1 Mini", "N2S": "A1", "A11": "A1", "A12": "A1 Mini", "N9": "A2L",
        "O1D": "H2D", "O1E": "H2D Pro", "O2D": "H2D Pro", "O1C": "H2C", "O1C2": "H2C", "O1S": "H2S",
        "N10": "H3C",
    ]
}

struct HMSError: Codable, Hashable {
    let code: String?
    let fullCode: String?
    let severity: Int?
    let description: String?
    let module: Int?
    /// Action keys the printer offers for this fault (e.g. RESUME_PRINTING).
    let actions: [String]?
    /// subtask_id snapshot; echoed back when running an action.
    let jobId: String?
}

struct PrinterStatus: Codable {
    let connected: Bool?
    let state: String?
    let subtaskName: String?
    let gcodeFile: String?
    let progress: Double?
    let remainingTime: Int?
    let layerNum: Int?
    let totalLayers: Int?
    let temperatures: [String: LooseNumber]?
    let hmsErrors: [HMSError]?
    let ams: [AMSUnit]?
    let vtTray: [AMSTray]?
    let stgCurName: String?
    let chamberLight: Bool?
    let speedLevel: Int?
    let developerMode: Bool?
    let awaitingPlateClear: Bool?
    let coverUrl: String?
    let currentArchiveId: Int?
    let doorOpen: Bool?
    let wifiSignal: Int?
    let trayNow: Int?
    let airductMode: Int?
    let activeExtruder: Int?
    let coolingFanSpeed: Int?
    let bigFan1Speed: Int?
    let bigFan2Speed: Int?
    let heatbreakFanSpeed: Int?
    let leftAuxFanSpeed: Int?
    let exhaustFanPresent: Bool?
    let supportsDrying: Bool?
    let supportsDryingWhilePrinting: Bool?
    let dryingScreenOnly: Bool?
    let firmwareVersion: String?
    let printableObjectsCount: Int?
    let printOptions: PrintOptions?
    let filaSwitch: FilaSwitch?
    /// Hardware info for the installed nozzle(s); rack slots only on tool-changer models.
    let nozzles: [AdvNozzleInfo]?
    let nozzleRack: [AdvRackSlot]?
    /// Current stage number (-1 = idle); `stgCurName` is its label.
    let stgCur: Int?

    /// AI detection / print options from the printer's xcam data.
    struct PrintOptions: Codable {
        let spaghettiDetector: Bool?
        let haltPrintSensitivity: String?
        let firstLayerInspector: Bool?
        let printingMonitor: Bool?
        let buildplateMarkerDetector: Bool?
        let allowSkipParts: Bool?
        let nozzleClumpingDetector: Bool?
        let nozzleClumpingSensitivity: String?
        let pileupDetector: Bool?
        let airprintDetector: Bool?
        let airprintSensitivity: String?
        let autoRecoveryStepLoss: Bool?
    }

    /// Filament Track Switch accessory: loads must name the hotend to feed.
    struct FilaSwitch: Codable {
        let installed: Bool?
        let ready: Bool?
    }

    var isConnected: Bool { connected ?? false }

    var phase: String {
        switch (state ?? "").uppercased() {
        case "PREPARE", "SLICING": "preparing"
        case "RUNNING": "printing"
        case "PAUSE": "paused"
        case "FINISH": "finished"
        case "FAILED": "failed"
        default: isConnected ? "idle" : "offline"
        }
    }

    var isPrinting: Bool { ["preparing", "printing", "paused"].contains(phase) }

    var jobName: String {
        let raw = subtaskName?.isEmpty == false ? subtaskName! : (gcodeFile ?? "")
        return raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".gcode.3mf", with: "")
    }

    /// Errors and warnings worth surfacing (Bambuddy: severity 1 error, 2 warning, 3 info).
    /// Leaves out the authorization-lock code: on cloud-mode printers it fires
    /// on every rejected command and just means "watch-only", which the
    /// printer screen already says.
    var problems: [HMSError] {
        (hmsErrors ?? []).filter { ($0.severity ?? 1) <= 2 && !Self.isAuthorizationLock($0) }
    }

    /// HMS 0500-0500-0001-0007 "MQTT command verification failed".
    static func isAuthorizationLock(_ e: HMSError) -> Bool {
        (e.fullCode ?? "").uppercased() == "0500050000010007"
            || (e.description ?? "").localizedCaseInsensitiveContains("command verification failed")
    }

    func temperature(_ key: String) -> Double? { temperatures?[key]?.value }

    /// Bambuddy can only control a printer in LAN-only + Developer Mode
    /// (otherwise firmware rejects unsigned control commands). nil = unknown.
    var acceptsControl: Bool { developerMode != false }
}

/// Status bucket for grouping and badges.
enum FarmState: String, CaseIterable, Identifiable {
    case error, printing, paused, finished, idle, offline

    var id: String { rawValue }

    /// Offline when unreachable, error when a severity-1 problem is showing, otherwise by print phase.
    /// A failed print with no active error sits with finished ones.
    init(_ status: PrinterStatus?) {
        guard let status, status.isConnected else { self = .offline; return }
        if status.problems.contains(where: { ($0.severity ?? 1) == 1 }) { self = .error; return }
        switch status.phase {
        case "printing", "preparing": self = .printing
        case "paused": self = .paused
        case "finished", "failed": self = .finished
        default: self = .idle
        }
    }

    var label: String {
        switch self {
        case .error: "Error"
        case .printing: "Printing"
        case .paused: "Paused"
        case .finished: "Finished"
        case .idle: "Idle"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch self {
        case .error: .statusError
        case .printing, .idle: .accentTeal
        case .paused: .statusWarning
        case .finished: .statusFinished
        case .offline: .gray
        }
    }

    var symbol: String {
        switch self {
        case .error: "exclamationmark.triangle.fill"
        case .printing: "printer.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .idle: "circle"
        case .offline: "wifi.slash"
        }
    }
}

struct AMSUnit: Codable, Identifiable {
    let id: Int
    let humidity: Int?
    let temp: Double?
    let isAmsHt: Bool?
    let tray: [AMSTray]?
    /// Bambuddy 1.3+ with rack AMS support: unit type from the `info` field (6 AMS-3H, 7 AMS-B).
    let amsType: Int?
    let amsTypeName: String?
    /// Rack AMS on the H3C: slot n feeds nozzle n, no unload, tray ids 28+slot (AMS-3H) / 37+slot (AMS-B).
    let isRack: Bool?
    let canAutoFeed: Bool?
    let canAutoRetract: Bool?
    let moduleType: String?
    /// Minutes remaining in the active drying cycle (0 = not drying).
    let dryTime: Int?
    /// 0 off, 1 checking, 2 drying, 3 cooling, 4 stopping, 5 error.
    let dryStatus: Int?
    /// 0 off, 1 heating, 2 dehumidify.
    let drySubStatus: Int?
    let dryTargetTemp: Int?
    let dryFilament: String?
    let drySfReason: [Int]?
    /// dry_time is set but the countdown isn't ticking (parked or paused cycle).
    let dryCountdownStalled: Bool?
}

struct AMSTray: Codable, Identifiable {
    let id: Int
    let trayColor: String?
    let trayType: String?
    let traySubBrands: String?
    let remain: Int?
    let tagUid: String?
    let trayUuid: String?
    let dryingTemp: Int?
    let dryingTime: Int?
    /// Firmware's "spool physically present" bit (nil = unknown).
    let exists: Bool?
    /// Nozzle this slot or external input feeds (0-based), on direct-connected racks like the H3C.
    let nozzleAddr: Int?

    var isEmpty: Bool { (trayType ?? "").isEmpty }
    var label: String { traySubBrands?.isEmpty == false ? traySubBrands! : (trayType ?? "Empty") }
}

struct Me: Codable {
    let id: Int?
    let username: String?
    let role: String?
    let isAdmin: Bool?
    let permissions: [String]?
}

struct QueueItem: Codable, Identifiable {
    let id: Int
    let printerId: Int?
    let printerName: String?
    let targetModel: String?
    let targetLocation: String?
    let waitingReason: String?
    let position: Int?
    let archiveId: Int?
    let libraryFileId: Int?
    let archiveName: String?
    let libraryFileName: String?
    let scheduledTime: Date?
    let startedAt: Date?
    let completedAt: Date?
    let createdAt: Date?
    let status: String
    let errorMessage: String?
    let manualStart: Bool?
    let printTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let filamentType: String?
    let filamentColor: String?
    let createdByUsername: String?
    let batchName: String?
    let filamentShort: Bool?
    let batchId: Int?
    let requirePreviousSuccess: Bool?
    let plateId: Int?
    let bedLevelling: String?
    let flowCali: String?
    let vibrationCali: Bool?
    let layerInspect: Bool?
    let timelapse: Bool?
    let useAms: Bool?
    let archiveDeleted: Bool?
    let layerHeight: Double?
    let nozzleDiameter: Double?
    let slicedForModel: String?
    let bedType: String?
    let createdById: Int?
    let skipFilamentCheck: Bool?
    /// Global tray id per 3MF filament slot (position = slot_id - 1, -1 = unmapped). Nil = the scheduler maps at dispatch.
    let amsMapping: [Int]?
    /// H2C nozzle rack: filament group id -> 1-based rack position (JSON object keys are strings).
    let nozzleRackChoice: [String: Int]?

    var name: String { archiveName ?? libraryFileName ?? "Print job" }

    var target: String {
        if let printerName { return printerName }
        if let targetModel {
            let model = Printer.modelNames[targetModel] ?? targetModel
            return targetLocation.map { "Any \(model) · \($0)" } ?? "Any \(model)"
        }
        return "Unassigned"
    }

    var thumbnailPath: String? {
        if let archiveId { return "archives/\(archiveId)/thumbnail" }
        if let libraryFileId { return "library/files/\(libraryFileId)/thumbnail" }
        return nil
    }
}

struct Archive: Codable, Identifiable {
    let id: Int
    let printerId: Int?
    let printName: String?
    let filename: String?
    let status: String
    let startedAt: Date?
    let completedAt: Date?
    let printTimeSeconds: Int?
    let actualTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let filamentType: String?
    let filamentColor: String?
    let layerHeight: Double?
    let totalLayers: Int?
    let nozzleDiameter: Double?
    let failureReason: String?
    let makerworldUrl: String?
    let isFavorite: Bool?
    let photos: [String]?
    let projectName: String?
    let slicedForModel: String?
    let cost: Double?
    let notes: String?
    let tags: String?
    let projectId: Int?
    let userVerdict: String?
    let userVerdictSource: String?
    let confirmRequested: Bool?
    let timelapseCount: Int?
    let timelapsePath: String?
    let plateId: Int?
    let quantity: Int?
    let createdById: Int?
    let createdByUsername: String?
    let externalUrl: String?
    let runCount: Int?
    let bedType: String?
    let designer: String?

    var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var name: String {
        (printName ?? filename?.replacingOccurrences(of: ".gcode.3mf", with: "") ?? "Untitled print")
            .replacingOccurrences(of: "_", with: " ")
    }

    var stateColor: Color {
        switch status {
        case "completed": .accentTeal
        case "failed": .statusError
        case "cancelled", "aborted", "stopped": .statusWarning
        case "printing": .statusFinished
        default: .textMuted
        }
    }

    var stateLabel: String {
        switch status {
        case "completed": "Completed"
        case "failed": "Failed"
        case "cancelled", "aborted", "stopped": "Cancelled"
        case "printing": "Printing"
        default: status.capitalized
        }
    }
}

struct LibraryFolder: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let parentId: Int?
    let fileCount: Int?
    let children: [LibraryFolder]?
}

struct LibraryFile: Codable, Identifiable {
    let id: Int
    let folderId: Int?
    let filename: String
    let fileType: String?
    let printName: String?
    let printTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let printCount: Int?
    let slicedForModel: String?
    let createdAt: Date?

    var name: String { printName ?? filename }
    var isSliced: Bool { filename.hasSuffix(".gcode") || filename.hasSuffix(".gcode.3mf") }
}

struct Spool: Codable, Identifiable {
    let id: Int
    let material: String?
    let subtype: String?
    let colorName: String?
    let rgba: String?
    let brand: String?
    let labelWeight: Double?
    let weightUsed: Double?
    let lowStockThresholdPct: Double?
    let lastUsed: Date?
    // Phase 2A: the rest of Bambuddy's SpoolResponse that the inventory screens use.
    let extraColors: String?
    let effectType: String?
    let coreWeight: Double?
    let nozzleTempMin: Int?
    let nozzleTempMax: Int?
    let note: String?
    let costPerKg: Double?
    let category: String?
    let storageLocation: String?
    let materialNumber: String?
    let weightLocked: Bool?
    /// Raw timestamp string; non-nil means archived.
    let archivedAt: String?

    var remainingGrams: Double { max(0, (labelWeight ?? 1000) - (weightUsed ?? 0)) }
    var remainingFraction: Double { (labelWeight ?? 0) > 0 ? remainingGrams / (labelWeight ?? 1000) : 0 }
    var title: String { [brand, material, subtype].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
}

struct MaintenanceOverview: Codable, Identifiable {
    let printerId: Int
    let printerName: String
    let printerModel: String?
    let totalPrintHours: Double?
    let dueCount: Int?
    let warningCount: Int?
    let maintenanceItems: [MaintenanceItem]?

    var id: Int { printerId }
}

struct MaintenanceItem: Codable, Identifiable {
    let id: Int
    let maintenanceTypeName: String?
    let maintenanceTypeIcon: String?
    let enabled: Bool?
    let intervalHours: Double?
    let intervalType: String?
    let hoursUntilDue: Double?
    let daysUntilDue: Double?
    let isDue: Bool?
    let isWarning: Bool?
    let lastPerformedAt: Date?
}

struct ArchiveStats: Codable {
    let totalPrints: Int?
    let successfulPrints: Int?
    let failedPrints: Int?
    let cancelledPrints: Int?
    let totalPrintTimeHours: Double?
    let totalFilamentGrams: Double?
    let totalCost: Double?
    let totalEnergyKwh: Double?

    var successRate: Double? {
        guard let total = totalPrints, total > 0 else { return nil }
        return Double(successfulPrints ?? 0) / Double(total)
    }
}

struct NotificationLogEntry: Codable, Identifiable {
    let id: Int
    let eventType: String?
    let title: String?
    let message: String?
    let success: Bool?
    let printerName: String?
    let createdAt: Date?
}

/// A JSON value that's usually a number but might be a bool, string, or null.
/// Bambuddy's `temperatures` dict mixes `"nozzle": 215.0` with `"chamber_heating": true`.
struct LooseNumber: Codable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}
