import Foundation
import SwiftUI

// Models for archive merge, compare and the print calendar. Shapes match the Bambuddy 1.3.0
// archive merge, compare and print-log responses.

/// A date that never fails the whole decode: Python emits several ISO shapes.
struct SafeDate: Decodable {
    let date: Date?
    init(from decoder: Decoder) throws { date = try? decoder.singleValueContainer().decode(Date.self) }
}

// MARK: Merge

struct MergeCountResponse: Decodable { let groups: Int }

struct MergeBrief: Decodable, Identifiable {
    let id: Int
    let printName: String?
    let filename: String?
    let createdAt: SafeDate?
    let runCount: Int?

    var name: String {
        (printName ?? filename?.replacingOccurrences(of: ".gcode.3mf", with: "") ?? "Archive \(id)").replacingOccurrences(of: "_", with: " ")
    }
}

struct MergeGroup: Decodable, Identifiable {
    let survivor: MergeBrief
    let merged: [MergeBrief]
    /// "busy" (an archive is printing, queued or just printed) or "conflicting_files"; nil when it can merge now.
    let skipped: String?

    var id: Int { survivor.id }

    var skippedText: String? {
        switch skipped {
        case nil: nil
        case "busy": "An archive in this group is printing, queued or just printed."
        case "conflicting_files": "The files differ, so Bambuddy can't merge them."
        default: "Left out: \(skipped ?? "")."
        }
    }
}

struct MergePreviewResponse: Decodable { let groups: [MergeGroup] }

struct MergeOutcome: Decodable {
    struct Done: Decodable { let survivorId: Int; let mergedIds: [Int] }
    struct Skipped: Decodable { let survivorId: Int; let reason: String }
    let merged: [Done]
    let skipped: [Skipped]
}

// MARK: Compare

/// A comparison cell: the server sends strings, numbers or null.
struct CompareValue: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            text = nil
        } else if let s = try? c.decode(String.self) {
            text = s
        } else if let i = try? c.decode(Int.self) {
            text = String(i)
        } else if let d = try? c.decode(Double.self) {
            text = d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
        } else if let b = try? c.decode(Bool.self) {
            text = b ? "Yes" : "No"
        } else {
            text = nil
        }
    }
}

struct CompareArchive: Decodable, Identifiable {
    let id: Int
    let printName: String?
    let status: String?
    let createdAt: SafeDate?
    let printerId: Int?
    let projectName: String?

    var name: String { (printName ?? "Archive \(id)").replacingOccurrences(of: ".gcode.3mf", with: "").replacingOccurrences(of: "_", with: " ") }
}

struct CompareField: Decodable, Identifiable {
    let field: String
    let label: String
    let unit: String?
    let values: [CompareValue]
    let hasDifference: Bool

    var id: String { field }

    func display(_ index: Int) -> String {
        guard index < values.count, let text = values[index].text else { return "–" }
        if field == "status" { return text.capitalized }
        return unit.map { $0 == "s" ? text : "\(text) \($0)" } ?? text
    }
}

struct CompareInsight: Decodable, Identifiable {
    let field: String
    let label: String?
    let insight: String
    var id: String { field }
}

struct CompareCorrelation: Decodable {
    let hasBothOutcomes: Bool
    let message: String?
    let successfulCount: Int?
    let failedCount: Int?
    let insights: [CompareInsight]?
}

struct ArchiveComparison: Decodable {
    let archives: [CompareArchive]
    let comparison: [CompareField]
    let successCorrelation: CompareCorrelation?
}

// MARK: Calendar

/// One print (run) from GET /archives/prints.
struct PrintLogEntry: Decodable, Identifiable {
    let id: Int
    let archiveId: Int?
    let printName: String?
    let plateId: Int?
    let printerName: String?
    let printerId: Int?
    let status: String
    let startedAt: Date?
    let completedAt: Date?
    let durationSeconds: Int?
    let filamentType: String?
    let filamentUsedGrams: Double?
    let cost: Double?
    let failureReason: String?
    let quantity: Int?
    let createdAt: Date?

    /// When the print ended: the day the calendar puts it on (server: completed_at, else created_at).
    var endedAt: Date? { completedAt ?? createdAt }

    var name: String { (printName ?? "Print \(id)").replacingOccurrences(of: ".gcode.3mf", with: "").replacingOccurrences(of: "_", with: " ") }

    var tint: Color {
        switch status {
        case "completed": .accentTeal
        case "failed": .statusError
        case "cancelled", "aborted", "stopped": .statusWarning
        default: .textMuted
        }
    }

    var statusLabel: String {
        switch status {
        case "completed": "Completed"
        case "failed": "Failed"
        case "cancelled", "aborted", "stopped": "Cancelled"
        default: status.capitalized
        }
    }
}

struct PrintLogPage: Decodable {
    let items: [PrintLogEntry]
    let total: Int
}
