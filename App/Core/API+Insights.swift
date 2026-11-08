import Foundation

/// Phase 4A endpoints: stats, print log, pending uploads, scheduled drying and sensor history.
/// Bambuddy 1.3.0. Every call uses the app's own API key.
extension APIClient {
    // MARK: Stats (/archives)

    /// Calendar-day filter shared by the stats routes: local YYYY-MM-DD plus the IANA zone they are days in.
    static func insDayQuery(from: String?, to: String?, createdBy: Int?) -> [URLQueryItem] {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "date_from", value: from)) }
        if let to { query.append(URLQueryItem(name: "date_to", value: to)) }
        query.append(URLQueryItem(name: "tz", value: TimeZone.current.identifier))
        if let createdBy { query.append(URLQueryItem(name: "created_by_id", value: String(createdBy))) }
        return query
    }

    /// GET /archives/stats (stats:read). `created_by_id` needs stats:filter_by_user (-1 = no user).
    func insStats(from: String?, to: String?, createdBy: Int?) async throws -> InsStats {
        let data = try await request("archives/stats", query: Self.insDayQuery(from: from, to: to, createdBy: createdBy))
        return try JSONDecoder().decode(InsStats.self, from: data)
    }

    /// GET /archives/analysis/failures (archives:read_own | read_all). Date range, or `days` when no range.
    func insFailureAnalysis(from: String?, to: String?, createdBy: Int?) async throws -> InsFailureAnalysis {
        var query = Self.insDayQuery(from: from, to: to, createdBy: createdBy)
        if from == nil, to == nil { query.append(URLQueryItem(name: "days", value: "3650")) }
        return try JSONDecoder().decode(InsFailureAnalysis.self, from: try await request("archives/analysis/failures", query: query))
    }

    /// GET /archives/slim (archives:read_own | read_all): one row per print event, newest first.
    /// The route caps `limit` at 50000; this pages 10000 at a time up to `maxRows`. Decoding happens on
    /// the calling (non-main) task and dates stay strings: `FastDate` parses them in the aggregator.
    func insSlimRuns(from: String?, to: String?, createdBy: Int?, maxRows: Int = 50000) async throws -> [InsRun] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let pageSize = 10000
        var all: [InsRun] = []
        var offset = 0
        while offset < maxRows {
            try Task.checkCancellation()
            var query = Self.insDayQuery(from: from, to: to, createdBy: createdBy)
            query.append(URLQueryItem(name: "limit", value: String(pageSize)))
            query.append(URLQueryItem(name: "offset", value: String(offset)))
            let page = try decoder.decode([InsRun].self, from: try await request("archives/slim", query: query))
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return all
    }

    /// GET /users/slim (users:read_slim; an API key with can_read_status is accepted). id + username.
    func insUsers() async throws -> [InsUser] { try await get("users/slim") }

    /// GET /settings/ (settings:read). Only the currency is read.
    func insCurrency() async -> String? {
        struct S: Decodable { let currency: String? }
        let s: S? = try? await get("settings/")
        return s?.currency
    }

    // MARK: Print log

    struct InsPrintLogQuery: Hashable {
        var search = ""
        var status: String?
        var printerId: Int?
        var sortBy = "date"
        var descending = true
        /// Naive UTC "YYYY-MM-DDTHH:MM:SS" the route compares to created_at.
        var dateFrom: String?
    }

    /// GET /print-log/ (archives:read_own | read_all). limit 1-500; sort_by one of date, print_name, printer,
    /// user, status, duration, completed_at, filament, filament_used, cost, energy, energy_cost, wear_cost.
    func insPrintLog(_ q: InsPrintLogQuery, limit: Int = 50, offset: Int) async throws -> InsPrintLogPage {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset)),
                     URLQueryItem(name: "sort_by", value: q.sortBy), URLQueryItem(name: "sort_dir", value: q.descending ? "desc" : "asc")]
        let search = q.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let status = q.status { query.append(URLQueryItem(name: "status", value: status)) }
        if let printerId = q.printerId { query.append(URLQueryItem(name: "printer_id", value: String(printerId))) }
        if let from = q.dateFrom { query.append(URLQueryItem(name: "date_from", value: from)) }
        return try await get("print-log/", query: query)
    }

    /// DELETE /print-log/{id} (archives:delete_own | delete_all). Archives are untouched; stats drop the run.
    func insDeletePrintLogEntry(_ id: Int) async throws { _ = try await request("print-log/\(id)", method: "DELETE") }

    /// DELETE /print-log/ (archives:delete_all). Clears the log only (archives and queue stay).
    func insClearPrintLog() async throws -> Int {
        struct R: Decodable { let deleted: Int? }
        let r = try decoder().decode(R.self, from: try await request("print-log/", method: "DELETE"))
        return r.deleted ?? 0
    }

    // MARK: Pending uploads

    /// GET /pending-uploads/ (queue:read_own | read_all).
    func insPendingUploads() async throws -> [InsPendingUpload] { try await get("pending-uploads/") }

    /// GET /pending-uploads/count (queue:read_own | read_all).
    func insPendingCount() async throws -> Int {
        struct R: Decodable { let count: Int }
        let r: R = try await get("pending-uploads/count")
        return r.count
    }

    /// POST /pending-uploads/{id}/archive (queue:create). Optional tags (comma-separated), notes, project.
    func insArchivePending(_ id: Int, tags: String?, notes: String?, projectId: Int?) async throws {
        struct Body: Encodable { let tags: String?; let notes: String?; let projectId: Int? }
        _ = try await request("pending-uploads/\(id)/archive", method: "POST", body: Body(tags: tags, notes: notes, projectId: projectId))
    }

    /// POST /pending-uploads/archive-all (queue:create) -> {archived, failed}.
    func insArchiveAllPending() async throws -> (archived: Int, failed: Int) {
        struct R: Decodable { let archived: Int?; let failed: Int? }
        let r = try decoder().decode(R.self, from: try await request("pending-uploads/archive-all", method: "POST"))
        return (r.archived ?? 0, r.failed ?? 0)
    }

    /// DELETE /pending-uploads/{id} (queue:delete_all). Removes the file; not undoable.
    func insDiscardPending(_ id: Int) async throws { _ = try await request("pending-uploads/\(id)", method: "DELETE") }

    /// DELETE /pending-uploads/discard-all (queue:delete_all).
    func insDiscardAllPending() async throws { _ = try await request("pending-uploads/discard-all", method: "DELETE") }

    // MARK: Scheduled drying

    /// GET /scheduled-dryings?printer_id= (printers:read). Lists pending, running and failed rows.
    func insScheduledDryings(printerId: Int?) async throws -> [InsScheduledDrying] {
        try await get("scheduled-dryings", query: printerId.map { [URLQueryItem(name: "printer_id", value: String($0))] } ?? [])
    }

    /// POST /scheduled-dryings (printers:control). temp 45-85, duration_hours 1-24, filament <= 50 chars,
    /// start_after in the future (UTC; any offset is converted) or nil for as soon as possible.
    @discardableResult
    func insScheduleDrying(printerId: Int, amsId: Int, temp: Int, hours: Int, filament: String, rotateTray: Bool,
                           startAfter: Date?) async throws -> InsScheduledDrying {
        struct Body: Encodable {
            let printerId: Int; let amsId: Int; let temp: Int; let durationHours: Int
            let filament: String; let rotateTray: Bool; let startAfter: String?
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let body = Body(printerId: printerId, amsId: amsId, temp: temp, durationHours: hours, filament: String(filament.prefix(50)),
                        rotateTray: rotateTray, startAfter: startAfter.map { iso.string(from: $0) })
        return try decoder().decode(InsScheduledDrying.self, from: try await request("scheduled-dryings", method: "POST", body: body))
    }

    /// DELETE /scheduled-dryings/{id} (printers:control). Pending/running -> cancelled; failed -> dismissed.
    func insCancelScheduledDrying(_ id: Int) async throws { _ = try await request("scheduled-dryings/\(id)", method: "DELETE") }

    // MARK: History charts (AMS and printer sensor history)

    /// GET /ams-history/{printer_id}/{ams_id}?hours=1-168 (ams_history:read).
    func insAMSHistory(printerId: Int, amsId: Int, hours: Int) async throws -> InsAMSHistory {
        try await get("ams-history/\(printerId)/\(amsId)", query: [URLQueryItem(name: "hours", value: String(hours))])
    }

    /// GET /printer-sensor-history/{printer_id}?hours=1-168&kinds= (printer_sensor_history:read).
    /// Kinds: nozzle, nozzle_2, bed, chamber.
    func insSensorHistory(printerId: Int, hours: Int) async throws -> InsSensorHistory {
        try await get("printer-sensor-history/\(printerId)", query: [URLQueryItem(name: "hours", value: String(hours))])
    }
}

/// The server's `{"detail": "..."}` text from a failed call, else the error's own description.
func insMessage(_ error: Error) -> String {
    if case let APIError.http(_, body) = error,
       let data = body.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let detail = json["detail"] as? String { return detail }
        if let list = json["detail"] as? [[String: Any]], let first = list.first?["msg"] as? String { return first }
    }
    return error.localizedDescription
}
