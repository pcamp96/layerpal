import SwiftUI
import UIKit

/// Spools, slot assignments and the settings that shape them (global low-stock threshold,
/// Spoolman mode). One instance per screen; the printer screen's tray sheet makes its own.
@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var spools: [Spool] = []
    @Published private(set) var assignments: [SlotAssignment] = []
    @Published private(set) var lowStockThreshold = 20.0
    @Published private(set) var spoolman = false
    @Published private(set) var loaded = false
    @Published var error: String?

    private var includeArchived = false

    // MARK: Permissions (server gates every spool write on inventory:update)

    var canRead: Bool { FarmStore.shared.can("inventory:read") }
    var canWrite: Bool { FarmStore.shared.can("inventory:update") }
    var canViewAssignments: Bool { FarmStore.shared.can("inventory:view_assignments") }

    // MARK: Lookups

    func spool(_ id: Int) -> Spool? { spools.first { $0.id == id } }

    func slots(for spoolId: Int) -> [SlotAssignment] {
        assignments.filter { $0.spoolId == spoolId }.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    func assignment(printerId: Int, amsId: Int, trayId: Int) -> SlotAssignment? {
        assignments.first { $0.printerId == printerId && $0.amsId == amsId && $0.trayId == trayId }
    }

    /// Name for a slot's spool: the nested spool (built-in mode) or the loaded list (Spoolman).
    func spool(for assignment: SlotAssignment) -> Spool? { assignment.spool ?? spool(assignment.spoolId) }

    // MARK: Loading

    /// Spoolman mode: the server reports it enabled and a URL is set.
    private func detectMode() async {
        if let settings = try? await APIClient.shared.inventorySettings() {
            spoolman = settings.spoolmanEnabled == true && !(settings.spoolmanUrl ?? "").isEmpty
            if let t = settings.lowStockThreshold, t > 0 { lowStockThreshold = t }
        } else if let status = try? await APIClient.shared.spoolmanStatus() {
            spoolman = status.enabled == true && !(status.url ?? "").isEmpty
        }
    }

    func load(includeArchived: Bool? = nil) async {
        if let includeArchived { self.includeArchived = includeArchived }
        await detectMode()
        let allowed = canViewAssignments, mode = spoolman
        async let assigned = Self.fetchAssignments(allowed: allowed, spoolman: mode)
        if canRead {
            do {
                spools = try await APIClient.shared.inventorySpools(includeArchived: self.includeArchived, spoolman: spoolman)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            error = "Your account can't view inventory."
        }
        if let list = await assigned { assignments = list }
        loaded = true
    }

    private nonisolated static func fetchAssignments(allowed: Bool, spoolman: Bool) async -> [SlotAssignment]? {
        guard allowed else { return nil }
        return try? await APIClient.shared.slotAssignments(spoolman: spoolman)
    }

    /// For the printer screen: slot assignments, plus spool names only where the list doesn't carry them.
    func loadAssignments() async {
        await detectMode()
        guard canViewAssignments else { return }
        if let list = try? await APIClient.shared.slotAssignments(spoolman: spoolman) { assignments = list }
        if spoolman, canRead, spools.isEmpty {
            spools = (try? await APIClient.shared.inventorySpools(includeArchived: false, spoolman: true)) ?? []
        }
        loaded = true
    }

    func reloadAssignments() async {
        guard canViewAssignments else { return }
        if let list = try? await APIClient.shared.slotAssignments(spoolman: spoolman) { assignments = list }
    }

    // MARK: Writes (each returns after the local copy is current)

    @discardableResult
    func create(_ draft: SpoolDraft) async throws -> Spool {
        let spool = try await APIClient.shared.createInventorySpool(draft.createBody(spoolman: spoolman), spoolman: spoolman)
        spools.append(spool)
        return spool
    }

    @discardableResult
    func update(_ id: Int, _ patch: InventoryPatch) async throws -> Spool {
        let spool = try await APIClient.shared.updateInventorySpool(id, patch, spoolman: spoolman)
        replace(spool)
        return spool
    }

    @discardableResult
    func setArchived(_ id: Int, _ archived: Bool) async throws -> Spool {
        let spool = try await APIClient.shared.setSpoolArchived(id, archived: archived, spoolman: spoolman)
        if archived, !includeArchived {
            spools.removeAll { $0.id == id }
        } else {
            replace(spool)
        }
        if archived { assignments.removeAll { $0.spoolId == id } } // the server frees the slots
        return spool
    }

    func delete(_ id: Int) async throws {
        try await APIClient.shared.deleteInventorySpool(id, spoolman: spoolman)
        spools.removeAll { $0.id == id }
        assignments.removeAll { $0.spoolId == id }
    }

    /// Moves the spool: it leaves any slot it already holds.
    @discardableResult
    func assign(_ spoolId: Int, printerId: Int, amsId: Int, trayId: Int) async throws -> AssignResult {
        let result = try await APIClient.shared.assignSpool(spoolId, printerId: printerId, amsId: amsId, trayId: trayId, move: true, spoolman: spoolman)
        await reloadAssignments()
        return result
    }

    func unassign(_ assignment: SlotAssignment) async throws {
        try await APIClient.shared.unassignSpool(assignment, spoolman: spoolman)
        assignments.removeAll { $0.id == assignment.id }
    }

    // MARK: Bulk actions (inventory:update)

    /// action: archive | restore | delete. Reloads so the list matches the server (slots are freed there).
    func bulk(_ action: String, ids: [Int]) async throws {
        try await APIClient.shared.bulkSpoolAction(action, ids: ids, spoolman: spoolman)
        await load()
    }

    /// Moves the spools to a storage location; nil clears it (both inventories take a null).
    func bulkSetLocation(_ name: String?, ids: [Int]) async throws {
        var patch = InventoryPatch()
        patch["storage_location"] = name.map(PatchValue.string) ?? .null
        try await APIClient.shared.bulkUpdateSpools(ids: ids, update: patch, spoolman: spoolman)
        await load()
    }

    private func replace(_ spool: Spool) {
        if let i = spools.firstIndex(where: { $0.id == spool.id }) { spools[i] = spool } else { spools.append(spool) }
    }
}

enum InventoryHaptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
