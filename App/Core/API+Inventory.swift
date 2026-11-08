import Foundation

/// Inventory, spool, AMS-assignment and Spoolman endpoints (phase 2A, Bambuddy 1.3.0).
///
/// Permissions as the server enforces them: reads need `inventory:read` (assignments:
/// `inventory:view_assignments`). Every spool write, including create, delete, archive,
/// assign and unassign, is gated on `inventory:update` (not `inventory:create` or
/// `inventory:delete`), and for an API key additionally needs the `can_manage_inventory`
/// scope. The same `inventory:*` permissions guard the Spoolman proxy routes, so Spoolman
/// writes are possible with the app's key.
///
/// `spoolman: true` switches to `/spoolman/inventory/*`, which answers the same spool shape.
extension APIClient {
    private func base(_ spoolman: Bool) -> String { spoolman ? "spoolman/inventory" : "inventory" }

    // MARK: Mode and settings

    /// GET /settings/ (settings:read; allowed for API keys). Carries `spoolman_enabled`,
    /// `spoolman_url` and the global `low_stock_threshold` (percent).
    func inventorySettings() async throws -> InventorySettings { try await get("settings/") }

    /// GET /spoolman/status (filaments:read). Fallback when settings aren't readable.
    func spoolmanStatus() async throws -> SpoolmanStatus { try await get("spoolman/status") }

    // MARK: Spools

    /// GET /inventory/spools?include_archived= (inventory:read). Spoolman mode: /spoolman/inventory/spools.
    func inventorySpools(includeArchived: Bool, spoolman: Bool) async throws -> [Spool] {
        try await get("\(base(spoolman))/spools", query: [URLQueryItem(name: "include_archived", value: includeArchived ? "true" : "false")])
    }

    /// POST /inventory/spools (server gate: inventory:update). Required: `material`.
    func createInventorySpool(_ body: InventoryPatch, spoolman: Bool) async throws -> Spool {
        try decoder().decode(Spool.self, from: try await request("\(base(spoolman))/spools", method: "POST", body: body))
    }

    /// PATCH /inventory/spools/{id} (inventory:update). Setting `weight_used` also locks the weight
    /// so the AMS remaining-% sync doesn't overwrite it.
    func updateInventorySpool(_ id: Int, _ patch: InventoryPatch, spoolman: Bool) async throws -> Spool {
        try decoder().decode(Spool.self, from: try await request("\(base(spoolman))/spools/\(id)", method: "PATCH", body: patch))
    }

    /// POST /inventory/spools/{id}/archive or /restore (inventory:update). Archiving frees the spool's AMS slots.
    func setSpoolArchived(_ id: Int, archived: Bool, spoolman: Bool) async throws -> Spool {
        try decoder().decode(Spool.self, from: try await request("\(base(spoolman))/spools/\(id)/\(archived ? "archive" : "restore")", method: "POST"))
    }

    /// DELETE /inventory/spools/{id} (inventory:update). Hard delete; frees AMS slots.
    func deleteInventorySpool(_ id: Int, spoolman: Bool) async throws {
        _ = try await request("\(base(spoolman))/spools/\(id)", method: "DELETE")
    }

    // MARK: Color catalog (inventory:read)

    /// GET /inventory/colors/search (both filters are case-insensitive "contains"; at most 100 rows).
    func colorCatalog(manufacturer: String?, material: String?) async throws -> [ColorEntry] {
        var query: [URLQueryItem] = []
        if let manufacturer, !manufacturer.isEmpty { query.append(URLQueryItem(name: "manufacturer", value: manufacturer)) }
        if let material, !material.isEmpty { query.append(URLQueryItem(name: "material", value: material)) }
        return try await get("inventory/colors/search", query: query)
    }

    // MARK: Slot assignments

    /// GET /inventory/assignments (inventory:view_assignments). Spoolman mode: /spoolman/inventory/slot-assignments/all.
    func slotAssignments(spoolman: Bool) async throws -> [SlotAssignment] {
        try await get(spoolman ? "spoolman/inventory/slot-assignments/all" : "inventory/assignments")
    }

    /// POST /inventory/assignments {spool_id, printer_id, ams_id, tray_id, move} (inventory:update).
    /// Spoolman mode: POST /spoolman/inventory/slot-assignments with `spoolman_spool_id`.
    /// `move` also takes the spool out of any other slot it holds.
    func assignSpool(_ spoolId: Int, printerId: Int, amsId: Int, trayId: Int, move: Bool, spoolman: Bool) async throws -> AssignResult {
        struct Local: Encodable { let spoolId: Int; let printerId: Int; let amsId: Int; let trayId: Int; let move: Bool }
        struct Remote: Encodable { let spoolmanSpoolId: Int; let printerId: Int; let amsId: Int; let trayId: Int; let move: Bool }
        let data: Data
        if spoolman {
            data = try await request("spoolman/inventory/slot-assignments", method: "POST",
                                     body: Remote(spoolmanSpoolId: spoolId, printerId: printerId, amsId: amsId, trayId: trayId, move: move))
        } else {
            data = try await request("inventory/assignments", method: "POST",
                                     body: Local(spoolId: spoolId, printerId: printerId, amsId: amsId, trayId: trayId, move: move))
        }
        return (try? decoder().decode(AssignResult.self, from: data)) ?? AssignResult(configured: nil, pendingConfig: nil)
    }

    /// DELETE /inventory/assignments/{printer_id}/{ams_id}/{tray_id} (inventory:update).
    /// Spoolman mode has no per-slot delete: DELETE /spoolman/inventory/slot-assignments/{spoolman_spool_id}.
    func unassignSpool(_ assignment: SlotAssignment, spoolman: Bool) async throws {
        if spoolman {
            _ = try await request("spoolman/inventory/slot-assignments/\(assignment.spoolId)", method: "DELETE")
        } else {
            _ = try await request("inventory/assignments/\(assignment.printerId)/\(assignment.amsId)/\(assignment.trayId)", method: "DELETE")
        }
    }
}
