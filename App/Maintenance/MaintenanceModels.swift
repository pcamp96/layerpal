import SwiftUI

/// Models for the maintenance screens (phase 2B), matching the Bambuddy 1.3.0 maintenance responses.

/// MaintenanceStatus: one tracked item on one printer, with the computed due values.
struct MaintStatus: Decodable, Identifiable, Hashable {
    let id: Int
    let printerId: Int
    let printerName: String
    let printerModel: String?
    let maintenanceTypeId: Int
    let maintenanceTypeName: String
    let maintenanceTypeIcon: String?
    let maintenanceTypeWikiUrl: String?
    let enabled: Bool
    /// Effective interval: print hours for "hours", calendar days for "days".
    let intervalHours: Double
    let intervalType: String
    let currentHours: Double?
    let hoursSinceMaintenance: Double?
    let hoursUntilDue: Double?
    let daysSinceMaintenance: Double?
    let daysUntilDue: Double?
    let isDue: Bool
    let isWarning: Bool
    let lastPerformedAt: Date?

    var inDays: Bool { intervalType == "days" }
    var unit: String { inDays ? "days" : "print hours" }

    /// 0 due, 1 warning, 2 fine, 3 disabled. Used to put what needs attention first.
    var urgency: Int { !enabled ? 3 : (isDue ? 0 : (isWarning ? 1 : 2)) }

    var tint: Color { !enabled ? .textMuted : (isDue ? .statusError : (isWarning ? .statusWarning : .accentTeal)) }

    var remaining: Double? { inDays ? daysUntilDue : hoursUntilDue }

    var dueText: String {
        if !enabled { return "Disabled" }
        guard let r = remaining else { return isDue ? "Due now" : "Not due" }
        let amount = abs(r) >= 10 ? String(Int(abs(r).rounded())) : String(format: "%.1f", abs(r))
        if r <= 0 { return isDue ? "Overdue by \(amount) \(unit)" : "Due now" }
        return "Due in \(amount) \(unit)"
    }

    var intervalText: String {
        let v = intervalHours.rounded() == intervalHours ? String(Int(intervalHours)) : String(format: "%.1f", intervalHours)
        return "Every \(v) \(unit)"
    }

    var symbol: String { MaintIcon.symbol(maintenanceTypeIcon) }
}

/// PrinterMaintenanceOverview
struct MaintOverview: Decodable, Identifiable, Hashable {
    let printerId: Int
    let printerName: String
    let printerModel: String?
    let totalPrintHours: Double
    let maintenanceItems: [MaintStatus]
    let dueCount: Int
    let warningCount: Int

    var id: Int { printerId }

    /// Worst first: due count, then warnings.
    var severity: Int { dueCount * 1000 + warningCount }

    var activeItems: [MaintStatus] { maintenanceItems.filter(\.enabled).sorted { $0.urgency < $1.urgency } }
}

/// GET /maintenance/summary
struct MaintSummary: Decodable {
    let totalDue: Int
    let totalWarning: Int
    let printersWithIssues: [Issue]

    struct Issue: Decodable, Identifiable, Hashable {
        let printerId: Int
        let printerName: String
        let dueCount: Int
        let warningCount: Int
        var id: Int { printerId }
    }
}

/// MaintenanceHistoryResponse
struct MaintHistoryEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let performedAt: Date
    let hoursAtMaintenance: Double?
    let notes: String?
}

/// MaintenanceTypeResponse
struct MaintType: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let defaultIntervalHours: Double
    let intervalType: String
    let icon: String?
    let wikiUrl: String?
    let isSystem: Bool

    var inDays: Bool { intervalType == "days" }

    var intervalText: String {
        let v = defaultIntervalHours.rounded() == defaultIntervalHours ? String(Int(defaultIntervalHours)) : String(format: "%.1f", defaultIntervalHours)
        return "Every \(v) \(inDays ? "days" : "print hours")"
    }
}

/// Bambuddy stores a Lucide icon name; these map the ones its picker offers to SF Symbols.
enum MaintIcon {
    static let all: [(name: String, symbol: String)] = [
        ("Droplet", "drop.fill"), ("Flame", "flame.fill"), ("Ruler", "ruler"), ("Sparkles", "sparkles"),
        ("Square", "square"), ("Cable", "cable.connector"), ("Wrench", "wrench.fill"), ("Calendar", "calendar"),
        ("Timer", "timer"), ("Cog", "gearshape.fill"), ("Fan", "fan.fill"), ("Zap", "bolt.fill"),
        ("Wind", "wind"), ("Thermometer", "thermometer.medium"), ("Layers", "square.3.layers.3d"), ("Box", "shippingbox"),
        ("Target", "scope"), ("RefreshCw", "arrow.clockwise"), ("Settings", "gearshape"), ("Filter", "line.3.horizontal.decrease"),
        ("CircleDot", "circle.circle"),
    ]

    static func symbol(_ name: String?) -> String {
        all.first { $0.name == name }?.symbol ?? "wrench.fill"
    }
}

/// maintenance:read / create / update / delete from the user's permission strings.
@MainActor
struct MaintAccess {
    let farm: FarmStore
    var canCreate: Bool { farm.can("maintenance:create") }
    var canUpdate: Bool { farm.can("maintenance:update") }
    var canDelete: Bool { farm.can("maintenance:delete") }
}
