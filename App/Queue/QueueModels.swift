import Foundation
import SwiftUI

// Queue types (Bambuddy 1.3.0 /queue responses).

/// GET /queue/history
struct QueueHistoryPage: Decodable {
    let items: [QueueItem]
    let total: Int
    let locations: [String]?
}

struct QueueBatchPlate: Decodable, Identifiable {
    let plateId: Int?
    let plateName: String?
    let quantityTarget: Int?
    let dispatched: Int?
    let remaining: Int?
    let pendingCount: Int?
    let printingCount: Int?
    let completedCount: Int?
    let failedCount: Int?
    let canDispatch: Bool?

    var id: Int { plateId ?? -1 }
    var title: String { plateName?.isEmpty == false ? plateName! : (plateId.map { "Plate \($0)" } ?? "Whole file") }
}

/// GET /queue/batches (PrintBatchResponse)
struct QueueBatch: Decodable, Identifiable {
    let id: Int
    let name: String
    let archiveId: Int?
    let libraryFileId: Int?
    let quantity: Int?
    let status: String
    let createdAt: Date?
    let createdByUsername: String?
    let dueDate: Date?
    let notes: String?
    let pendingCount: Int?
    let printingCount: Int?
    let completedCount: Int?
    let failedCount: Int?
    let cancelledCount: Int?
    let skippedCount: Int?
    let hasTargets: Bool?
    let targetCount: Int?
    let remainingCount: Int?
    let dispatchableCount: Int?
    let printTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let plates: [QueueBatchPlate]?

    var total: Int {
        if hasTargets == true, let target = targetCount, target > 0 { return target }
        return max(quantity ?? 0, (pendingCount ?? 0) + (printingCount ?? 0) + (completedCount ?? 0)
            + (failedCount ?? 0) + (cancelledCount ?? 0) + (skippedCount ?? 0))
    }

    var progressPercent: Double {
        guard total > 0 else { return 0 }
        return Double(completedCount ?? 0) / Double(total) * 100
    }

    var thumbnailPath: String? {
        if let archiveId { return "archives/\(archiveId)/thumbnail" }
        if let libraryFileId { return "library/files/\(libraryFileId)/thumbnail" }
        return nil
    }
}

struct BulkUpdateResult: Decodable {
    let updatedCount: Int
    let skippedCount: Int
    let message: String?
}

struct HistoryClearResult: Decodable {
    let cleared: Int
    let kept: Int
}

struct ResumeResult: Decodable {
    let acknowledged: Int?
    let restored: Int?
}

struct DeleteResult: Decodable {
    let deleted: Bool?
}

struct UngroupResult: Decodable {
    let ungroupedCount: Int?
    let message: String?
}

// MARK: Archive plates (GET /archives/{id}/plates)

struct ArchivePlate: Decodable, Identifiable {
    let index: Int
    let name: String?
    let objects: [String]?
    let hasThumbnail: Bool?
    let printTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let bedType: String?

    var id: Int { index }
    var title: String { name?.isEmpty == false ? name! : "Plate \(index)" }
    var thumbnailPath: String? { hasThumbnail == true ? "archives/\(archiveIdForThumb ?? 0)/plate-thumbnail/\(index)" : nil }
    // Filled in by ArchivePlatesResponse so the plate can build its own thumbnail path.
    var archiveIdForThumb: Int?

    enum CodingKeys: String, CodingKey { case index, name, objects, hasThumbnail, printTimeSeconds, filamentUsedGrams, bedType }
}

struct ArchivePlatesResponse: Decodable {
    let archiveId: Int?
    let plates: [ArchivePlate]
    let isMultiPlate: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archiveId = try c.decodeIfPresent(Int.self, forKey: .archiveId)
        isMultiPlate = try c.decodeIfPresent(Bool.self, forKey: .isMultiPlate)
        var list = try c.decodeIfPresent([ArchivePlate].self, forKey: .plates) ?? []
        for i in list.indices { list[i].archiveIdForThumb = archiveId }
        plates = list
    }

    enum CodingKeys: String, CodingKey { case archiveId, plates, isMultiPlate }
}

// MARK: Print options

/// Bambuddy's tri-state calibration option (BambuStudio's "auto" = skip if recently done).
enum TriState: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// The per-job print options Bambuddy's dispatch dialog offers.
struct PrintOptions: Equatable {
    var bedLevelling: TriState = .auto
    var flowCali: TriState = .auto
    var vibrationCali = true
    var layerInspect = false
    var timelapse = false
    var useAms = true

    init() {}

    init(item: QueueItem) {
        bedLevelling = TriState(rawValue: item.bedLevelling ?? "") ?? .auto
        flowCali = TriState(rawValue: item.flowCali ?? "") ?? .auto
        vibrationCali = item.vibrationCali ?? true
        layerInspect = item.layerInspect ?? false
        timelapse = item.timelapse ?? false
        useAms = item.useAms ?? true
    }
}

/// What the user picked in the target picker.
struct QueueTarget: Equatable {
    var printerId: Int?
    var targetModel: String?
}

/// POST /queue/ body (PrintQueueItemCreate). Nil fields are omitted.
struct QueueCreateBody: Encodable {
    var printerId: Int?
    var targetModel: String?
    var archiveId: Int?
    var libraryFileId: Int?
    var scheduledTime: String?
    var requirePreviousSuccess: Bool?
    var manualStart: Bool?
    var insertAtTop: Bool?
    var plateId: Int?
    var bedLevelling: String?
    var flowCali: String?
    var vibrationCali: Bool?
    var layerInspect: Bool?
    var timelapse: Bool?
    var useAms: Bool?
    var quantity: Int?
    /// Global tray id per 3MF filament slot (position = slot_id - 1, -1 = unused).
    var amsMapping: [Int]?
    /// Set when the user mapped a slot onto a tray of another material.
    var skipFilamentCheck: Bool?
    /// H2C nozzle rack: filament group id -> 1-based rack position. Only for a specific rack printer.
    var nozzleRackChoice: [String: Int]?
}

/// Everything TargetPicker collects for one queue request.
struct QueueRequest {
    var target: QueueTarget
    var quantity = 1
    var options: PrintOptions?
    var manualStart = false
    var requirePreviousSuccess = false
    var insertAtTop = false
    var scheduledTime: Date?
    var plateId: Int?
    /// Only meaningful for a specific printer; "any <model>" jobs are mapped by the scheduler.
    var amsMapping: [Int]?
    var skipFilamentCheck = false
    /// Rack position per filament group (H2C), only when the user chose; nil lets the dispatcher assign.
    var nozzleRackChoice: [String: Int]?
}

// MARK: Sparse JSON (PATCH bodies)

/// A scalar that can be an explicit JSON null. Bambuddy's PATCH routes use
/// `exclude_unset`, so "clear this field" (ASAP, no printer) needs a real null,
/// which Swift's synthesized Encodable would drop.
enum JSONScalar: Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case intList([Int])
    case intMap([String: Int])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .intList(v): try c.encode(v)
        case let .intMap(v): try c.encode(v)
        }
    }

    static func date(_ date: Date?) -> JSONScalar {
        guard let date else { return .null }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return .string(f.string(from: date))
    }

    static func optionalInt(_ value: Int?) -> JSONScalar { value.map(JSONScalar.int) ?? .null }
}

/// Body with exactly the keys that were set. Keys are already snake_case.
struct SparsePatch: Encodable {
    var fields: [String: JSONScalar] = [:]

    subscript(key: String) -> JSONScalar? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    var isEmpty: Bool { fields.isEmpty }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for key in fields.keys.sorted() { try c.encode(fields[key]!, forKey: Key(key)) }
    }
}

extension SparsePatch {
    mutating func set(options new: PrintOptions, from old: PrintOptions?) {
        if old?.bedLevelling != new.bedLevelling { self["bed_levelling"] = .string(new.bedLevelling.rawValue) }
        if old?.flowCali != new.flowCali { self["flow_cali"] = .string(new.flowCali.rawValue) }
        if old?.vibrationCali != new.vibrationCali { self["vibration_cali"] = .bool(new.vibrationCali) }
        if old?.layerInspect != new.layerInspect { self["layer_inspect"] = .bool(new.layerInspect) }
        if old?.timelapse != new.timelapse { self["timelapse"] = .bool(new.timelapse) }
        if old?.useAms != new.useAms { self["use_ams"] = .bool(new.useAms) }
    }
}

// MARK: Errors

enum FriendlyError {
    /// Bambuddy's FastAPI `detail` string when there is one; HTTP 403 here usually means a
    /// missing permission or API-key scope, not a bad login, so don't say "sign in again".
    static func message(_ error: Error) -> String {
        guard case let APIError.http(code, body) = error else { return error.localizedDescription }
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String { return detail }
            if let list = json["detail"] as? [[String: Any]], let msg = list.first?["msg"] as? String { return msg }
        }
        if code == 403 { return "Your Bambuddy account or this app's API key isn't allowed to do that." }
        return error.localizedDescription
    }

    /// Parsed 409 from POST /queue/{id}/start: the filament problem Bambuddy found.
    static func filamentWarning(_ error: Error) -> String? {
        guard case let APIError.http(409, body) = error,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = json["detail"] as? [String: Any],
              let code = detail["code"] as? String else { return nil }
        switch code {
        case "insufficient_filament":
            let deficits = (detail["deficit"] as? [[String: Any]] ?? []).map { d -> String in
                let type = d["filament_type"] as? String ?? "Filament"
                let need = (d["required_grams"] as? Double).map { String(format: "%.0f g", $0) } ?? "?"
                let have = (d["remaining_grams"] as? Double).map { String(format: "%.0f g", $0) } ?? "unknown"
                return "\(type): needs \(need), loaded \(have)"
            }
            return "The loaded spool may run out before this finishes.\n" + deficits.joined(separator: "\n")
        case "unmatched_filament":
            return "The printer has no tray loaded for a filament this job needs."
        default:
            return nil
        }
    }
}

/// The signed-in user's id, for ownership checks (queue:update_own etc.).
actor IdentityCache {
    static let shared = IdentityCache()
    private var loaded = false
    private var id: Int?

    func userId() async -> Int? {
        if loaded { return id }
        id = try? await APIClient.shared.me().id
        loaded = true
        return id
    }
}

/// Who may do what to one queue item, from the user's permission strings.
@MainActor
struct QueueAccess {
    let farm: FarmStore
    let userId: Int?

    private func owns(_ createdById: Int?) -> Bool { createdById != nil && createdById == userId }

    func canUpdate(_ item: QueueItem) -> Bool {
        farm.can("queue:update_all") || (farm.can("queue:update_own") && (userId == nil || owns(item.createdById)))
    }

    func canDelete(_ item: QueueItem) -> Bool {
        farm.can("queue:delete_all") || (farm.can("queue:delete_own") && (userId == nil || owns(item.createdById)))
    }

    var canUpdateAny: Bool { farm.can("queue:update_all") || farm.can("queue:update_own") }
    var canDeleteAny: Bool { farm.can("queue:delete_all") || farm.can("queue:delete_own") }
    var canReorder: Bool { farm.can("queue:update_all") } // POST /queue/reorder requires queue:update_all
}
