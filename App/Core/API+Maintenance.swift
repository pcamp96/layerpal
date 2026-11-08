import Foundation

/// Maintenance endpoints (/maintenance, phase 2B, Bambuddy 1.3.0). Reads need maintenance:read;
/// perform and item edits need maintenance:update; assigning a type needs maintenance:create;
/// removing an item or deleting a type needs maintenance:delete. An API key also needs the
/// `can_manage_maintenance` scope for every write.
extension APIClient {
    /// GET /maintenance/summary
    func maintSummary() async throws -> MaintSummary { try await get("maintenance/summary") }

    /// GET /maintenance/overview: every active printer with its items.
    func maintOverviewAll() async throws -> [MaintOverview] { try await get("maintenance/overview") }

    /// GET /maintenance/printers/{id}
    func maintPrinter(_ id: Int) async throws -> MaintOverview { try await get("maintenance/printers/\(id)") }

    /// GET /maintenance/items/{id}/history (newest first)
    func maintHistory(_ itemId: Int) async throws -> [MaintHistoryEntry] { try await get("maintenance/items/\(itemId)/history") }

    /// POST /maintenance/items/{id}/perform {notes}: resets the counter and logs history.
    @discardableResult
    func maintPerform(_ itemId: Int, notes: String?) async throws -> MaintStatus {
        struct Body: Encodable { let notes: String? }
        let clean = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try decoder().decode(MaintStatus.self, from: try await request(
            "maintenance/items/\(itemId)/perform", method: "POST", body: Body(notes: clean?.isEmpty == true ? nil : clean)))
    }

    /// PATCH /maintenance/items/{id}: `enabled`, `custom_interval_hours` and `custom_interval_type`
    /// (null for either custom field goes back to the type's default).
    func maintUpdateItem(_ itemId: Int, _ patch: LibPatch) async throws {
        _ = try await request("maintenance/items/\(itemId)", method: "PATCH", body: patch)
    }

    /// DELETE /maintenance/items/{id}: unassign a custom type from a printer (system types answer 400).
    func maintRemoveItem(_ itemId: Int) async throws {
        _ = try await request("maintenance/items/\(itemId)", method: "DELETE")
    }

    /// POST /maintenance/printers/{printer}/assign/{type}
    func maintAssign(printerId: Int, typeId: Int) async throws {
        _ = try await request("maintenance/printers/\(printerId)/assign/\(typeId)", method: "POST")
    }

    /// PATCH /maintenance/printers/{id}/hours?total_hours= (maintenance:update): corrects the printer's print-hour total.
    func maintSetHours(printerId: Int, totalHours: Double) async throws {
        _ = try await request("maintenance/printers/\(printerId)/hours", method: "PATCH",
                              query: [URLQueryItem(name: "total_hours", value: String(totalHours))])
    }

    // MARK: Types

    /// GET /maintenance/types
    func maintTypes() async throws -> [MaintType] { try await get("maintenance/types") }

    /// POST /maintenance/types (maintenance:create). intervalType: hours | days.
    func maintCreateType(name: String, description: String?, interval: Double, intervalType: String, icon: String?, wikiUrl: String?) async throws {
        struct Body: Encodable {
            let name: String
            let description: String?
            let defaultIntervalHours: Double
            let intervalType: String
            let icon: String?
            let wikiUrl: String?
        }
        _ = try await request("maintenance/types", method: "POST", body: Body(
            name: name, description: description, defaultIntervalHours: interval, intervalType: intervalType, icon: icon, wikiUrl: wikiUrl))
    }

    /// PATCH /maintenance/types/{id} (maintenance:update). Send only changed fields (snake_case keys).
    func maintUpdateType(_ id: Int, _ patch: LibPatch) async throws {
        _ = try await request("maintenance/types/\(id)", method: "PATCH", body: patch)
    }

    /// DELETE /maintenance/types/{id} (maintenance:delete). System types are hidden, custom ones removed.
    func maintDeleteType(_ id: Int) async throws {
        _ = try await request("maintenance/types/\(id)", method: "DELETE")
    }

    /// POST /maintenance/types/restore-defaults (maintenance:delete). Returns how many came back.
    @discardableResult
    func maintRestoreDefaults() async throws -> Int {
        struct Result: Decodable { let restored: Int }
        let data = try await request("maintenance/types/restore-defaults", method: "POST")
        return (try? decoder().decode(Result.self, from: data))?.restored ?? 0
    }
}
