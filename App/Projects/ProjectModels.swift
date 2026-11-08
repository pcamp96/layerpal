import Foundation
import SwiftUI

// Project fields. `Project` covers both the list response
// (GET /projects/) and the detail response (GET /projects/{id}); list-only or detail-only
// fields are optional.

struct ProjectStats: Decodable {
    let totalArchives: Int?
    let totalItems: Int?
    let completedPrints: Int?
    let failedPrints: Int?
    let queuedPrints: Int?
    let inProgressPrints: Int?
    let totalPrintTimeHours: Double?
    let totalFilamentGrams: Double?
    let progressPercent: Double?
    let estimatedCost: Double?
    let remainingPrints: Int?
    let partsProgressPercent: Double?
    let remainingParts: Int?
    let totalEnergyKwh: Double?
    let totalEnergyCost: Double?
    let bomTotalItems: Int?
    let bomCompletedItems: Int?
    let bomCost: Double?
}

struct Project: Decodable, Identifiable {
    let id: Int
    let name: String
    let description: String?
    let color: String?
    let status: String
    let targetCount: Int?
    let priority: String?
    let tags: String?
    let notes: String?
    let dueDate: Date?
    let createdAt: Date?
    let parentId: Int?
    let targetPartsCount: Int?
    let targetSets: Int?
    let budget: Double?
    let url: String?
    let isTemplate: Bool?
    let parentName: String?
    // List fields
    let archiveCount: Int?
    let totalItems: Int?
    let completedCount: Int?
    let failedCount: Int?
    let queueCount: Int?
    let progressPercent: Double?
    let childCount: Int?
    // Detail field
    let stats: ProjectStats?

    var progress: Double? { stats?.progressPercent ?? progressPercent }
    var accent: Color { Color(hexRGBA: color?.replacingOccurrences(of: "#", with: "")) ?? .accentTeal }

    var statusLabel: String { status.capitalized }
    var statusTint: Color {
        switch status {
        case "completed": .statusFinished
        case "archived": .textMuted
        default: .accentTeal
        }
    }
}

enum ProjectPriority: String, CaseIterable, Identifiable {
    case low, normal, high, urgent
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
