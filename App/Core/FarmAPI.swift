import Foundation

/// Bambuddy 1.3 endpoints used by the farm UI. Every call uses the app's own API key.
extension APIClient {
    // MARK: Identity & printers

    func me() async throws -> Me { try await get("auth/me") }

    func bulkStatusData(ids: [Int]) async throws -> Data {
        try await request("bulk/printer-statuses", query: [URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ","))])
    }

    func wsToken() async throws -> String {
        struct T: Decodable { let token: String }
        let t: T = try decoder().decode(T.self, from: try await request("auth/ws-token", method: "POST"))
        return t.token
    }

    // MARK: Printer control (printers:control)

    func pause(_ id: Int) async throws { _ = try await request("printers/\(id)/print/pause", method: "POST") }
    func resume(_ id: Int) async throws { _ = try await request("printers/\(id)/print/resume", method: "POST") }
    func stop(_ id: Int) async throws { _ = try await request("printers/\(id)/print/stop", method: "POST") }

    func setLight(_ id: Int, on: Bool) async throws {
        _ = try await request("printers/\(id)/chamber-light", method: "POST", query: [URLQueryItem(name: "on", value: on ? "true" : "false")])
    }

    func setSpeed(_ id: Int, level: Int) async throws {
        _ = try await request("printers/\(id)/print-speed", method: "POST", query: [URLQueryItem(name: "mode", value: String(level))])
    }

    /// kind: nozzle | bed | chamber
    func setTemperature(_ id: Int, kind: String, target: Int, nozzle: Int? = nil) async throws {
        var query = [URLQueryItem(name: "target", value: String(target))]
        if let nozzle { query.append(URLQueryItem(name: "nozzle", value: String(nozzle))) }
        _ = try await request("printers/\(id)/temperature/\(kind)", method: "POST", query: query)
    }

    func clearPlate(_ id: Int) async throws { _ = try await request("printers/\(id)/clear-plate", method: "POST") }

    func clearHMS(_ id: Int) async throws { _ = try await request("printers/\(id)/hms/clear", method: "POST") }

    func stopCamera(_ id: Int) async { _ = try? await request("printers/\(id)/camera/stop", method: "POST") }

    // MARK: Queue (queue:*)

    func queue(status: String? = nil) async throws -> [QueueItem] {
        try await get("queue/", query: status.map { [URLQueryItem(name: "status", value: $0)] } ?? [])
    }

    func queueAction(_ id: Int, _ action: String) async throws {
        _ = try await request("queue/\(id)/\(action)", method: "POST")
    }

    func deleteQueueItem(_ id: Int) async throws { _ = try await request("queue/\(id)", method: "DELETE") }

    func reorderQueue(_ ids: [Int]) async throws {
        struct Pos: Encodable { let id: Int; let position: Int }
        struct Body: Encodable { let items: [Pos] }
        _ = try await request("queue/reorder", method: "POST",
                              body: Body(items: ids.enumerated().map { Pos(id: $0.element, position: $0.offset + 1) }))
    }

    /// Reprint an archive (direct reprint is gone in 1.3; everything goes through the queue).
    func enqueue(archiveId: Int? = nil, libraryFileId: Int? = nil, printerId: Int?, targetModel: String?,
                 quantity: Int = 1, manualStart: Bool = false) async throws {
        struct Body: Encodable {
            let archiveId: Int?
            let libraryFileId: Int?
            let printerId: Int?
            let targetModel: String?
            let quantity: Int
            let manualStart: Bool
        }
        _ = try await request("queue/", method: "POST",
                              body: Body(archiveId: archiveId, libraryFileId: libraryFileId, printerId: printerId,
                                         targetModel: printerId == nil ? targetModel : nil, quantity: quantity,
                                         manualStart: manualStart))
    }

    // MARK: Archives

    func archives(limit: Int = 50, offset: Int = 0, printerId: Int? = nil) async throws -> [Archive] {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let printerId { query.append(URLQueryItem(name: "printer_id", value: String(printerId))) }
        return try await get("archives/", query: query)
    }

    func searchArchives(_ q: String, status: String? = nil) async throws -> [Archive] {
        var query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "50")]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        return try await get("archives/search", query: query)
    }

    func archive(_ id: Int) async throws -> Archive { try await get("archives/\(id)") }

    func toggleFavorite(_ id: Int) async throws -> Archive {
        try decoder().decode(Archive.self, from: try await request("archives/\(id)/favorite", method: "POST"))
    }

    // MARK: Library

    func libraryFolders() async throws -> [LibraryFolder] { try await get("library/folders") }

    func libraryFiles(folderId: Int?) async throws -> [LibraryFile] {
        if let folderId { return try await get("library/files", query: [URLQueryItem(name: "folder_id", value: String(folderId))]) }
        return try await get("library/files", query: [URLQueryItem(name: "include_root", value: "true")])
    }

    // MARK: Inventory, maintenance, stats, activity

    func spools() async throws -> [Spool] { try await get("inventory/spools") }

    func maintenanceOverview() async throws -> [MaintenanceOverview] { try await get("maintenance/overview") }

    func performMaintenance(_ itemId: Int) async throws {
        struct Body: Encodable { let notes: String? }
        _ = try await request("maintenance/items/\(itemId)/perform", method: "POST", body: Body(notes: "Done from LayerPal"))
    }

    func stats(days: Int) async throws -> ArchiveStats {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: to) ?? to
        return try await get("archives/stats", query: [
            URLQueryItem(name: "date_from", value: df.string(from: from)),
            URLQueryItem(name: "date_to", value: df.string(from: to)),
            URLQueryItem(name: "tz", value: TimeZone.current.identifier),
        ])
    }

    func activity(days: Int = 7) async throws -> [NotificationLogEntry] {
        try await get("notifications/logs", query: [URLQueryItem(name: "limit", value: "150"), URLQueryItem(name: "days", value: String(days))])
    }
}
