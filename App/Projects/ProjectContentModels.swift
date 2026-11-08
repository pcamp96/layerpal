import Foundation
import SwiftUI

// Project queue, parts list (BOM), file progress and timeline. Shapes match the
// Bambuddy 1.3.0 /projects responses.

/// GET /projects/{id}/queue returns the queue rows as stored (no response model), so every field is optional.
struct ProjectQueueEntry: Decodable, Identifiable {
    let id: Int
    let status: String?
    let printerId: Int?
    let targetModel: String?
    let archiveId: Int?
    let libraryFileId: Int?
    let position: Int?
    let waitingReason: String?
    let manualStart: Bool?

    var statusLabel: String { (status ?? "pending").capitalized }

    var tint: Color {
        switch status {
        case "printing": .statusFinished
        case "completed": .accentTeal
        case "failed": .statusError
        case "cancelled", "skipped": .statusWarning
        default: .textSecondary
        }
    }

    var thumbnailPath: String? {
        if let archiveId { return "archives/\(archiveId)/thumbnail" }
        if let libraryFileId { return "library/files/\(libraryFileId)/thumbnail" }
        return nil
    }
}

struct ProjectFileProgress: Decodable {
    let fileId: Int
    let completedCount: Int
}

struct ProjectTimelineEvent: Decodable, Identifiable {
    let eventType: String
    let timestamp: Date?
    let title: String
    let description: String?

    var id: String { "\(eventType)-\(timestamp?.timeIntervalSince1970 ?? 0)-\(title)" }

    var symbol: String {
        switch eventType {
        case "project_created": "sparkles"
        case "archive_added": "clock.arrow.circlepath"
        case "queue_started": "play.circle"
        case "queue_completed": "checkmark.circle"
        case "status_changed": "arrow.triangle.2.circlepath"
        case "note_updated": "note.text"
        default: "circle"
        }
    }
}

struct BOMItem: Decodable, Identifiable {
    let id: Int
    let name: String
    let quantityNeeded: Int
    let quantityAcquired: Int
    let unitPrice: Double?
    let sourcingUrl: String?
    let archiveId: Int?
    let archiveName: String?
    let stlFilename: String?
    let remarks: String?
    let isComplete: Bool?

    var complete: Bool { isComplete ?? (quantityAcquired >= quantityNeeded) }
    var lineCost: Double? { unitPrice.map { $0 * Double(quantityNeeded) } }
}

/// Editable copy of a parts-list line. Numbers stay text so a field can be empty while typing.
struct BOMDraft {
    var name = ""
    var quantity = "1"
    var unitPrice = ""
    var url = ""
    var remarks = ""

    init() {}

    init(_ item: BOMItem) {
        name = item.name
        quantity = String(item.quantityNeeded)
        unitPrice = item.unitPrice.map { String(format: "%g", $0) } ?? ""
        url = item.sourcingUrl ?? ""
        remarks = item.remarks ?? ""
    }

    var quantityNeeded: Int { max(1, Int(quantity.trimmingCharacters(in: .whitespaces)) ?? 1) }
    var unitPriceValue: Double? { Double(unitPrice.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the part a name." }
        if Int(quantity.trimmingCharacters(in: .whitespaces)) == nil { return "Quantity is a whole number." }
        if !unitPrice.trimmingCharacters(in: .whitespaces).isEmpty, unitPriceValue == nil { return "Price is a number." }
        if !url.isEmpty, !(url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://")) { return "The link must start with http:// or https://." }
        return nil
    }

    /// PATCH body with only what changed against `old`; the server clears price (0), link and remarks (empty text); null is ignored.
    func patch(from old: BOMItem) -> LibPatch {
        var p = LibPatch()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName != old.name { p["name"] = .string(trimmedName) }
        if quantityNeeded != old.quantityNeeded { p["quantity_needed"] = .int(quantityNeeded) }
        if unitPriceValue != old.unitPrice { p["unit_price"] = .double(unitPriceValue ?? 0) }
        if url != (old.sourcingUrl ?? "") { p["sourcing_url"] = .string(url) }
        if remarks != (old.remarks ?? "") { p["remarks"] = .string(remarks) }
        return p
    }
}

struct AddFilesResult: Decodable {
    struct Added: Decodable { let fileId: Int; let filename: String; let queueItemId: Int }
    struct Failure: Decodable { let fileId: Int; let filename: String; let error: String }
    let added: [Added]
    let errors: [Failure]
}
