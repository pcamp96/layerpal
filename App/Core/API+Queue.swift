import Foundation

/// Queue endpoints added in phase 1B (/queue, Bambuddy 1.3.0).
extension APIClient {
    /// GET /queue/?status=pending,printing,skipped (queue:read_all | read_own).
    /// Finished runs come from `queueHistory`, so a big farm's
    /// history is never fetched in one go.
    func activeQueue() async throws -> [QueueItem] {
        try await get("queue/", query: [URLQueryItem(name: "status", value: "pending,printing,skipped")])
    }

    /// GET /queue/history (queue:read_*). status: completed | failed | skipped | cancelled.
    func queueHistory(limit: Int, offset: Int, status: String?, printerId: Int? = nil) async throws -> QueueHistoryPage {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let printerId { query.append(URLQueryItem(name: "printer_id", value: String(printerId))) }
        return try await get("queue/history", query: query)
    }

    /// POST /queue/history/clear (queue:delete_* and queue:read_*). Same filters as the history list.
    func clearQueueHistory(status: String?) async throws -> HistoryClearResult {
        let query = status.map { [URLQueryItem(name: "status", value: $0)] } ?? []
        return try decoder().decode(HistoryClearResult.self, from: try await request("queue/history/clear", method: "POST", query: query))
    }

    /// GET /queue/{id} (queue:read_*).
    func queueItem(_ id: Int) async throws -> QueueItem { try await get("queue/\(id)") }

    /// PATCH /queue/{id} (queue:update_all | update_own). Pending items only; send just what changed.
    func updateQueueItem(_ id: Int, _ patch: SparsePatch) async throws -> QueueItem {
        try decoder().decode(QueueItem.self, from: try await request("queue/\(id)", method: "PATCH", body: patch))
    }

    /// PATCH /queue/bulk (queue:update_all | update_own). Non-pending / not-owned items are skipped server-side.
    func bulkUpdateQueue(ids: [Int], patch: SparsePatch) async throws -> BulkUpdateResult {
        var body = patch
        body["item_ids"] = .intList(ids)
        return try decoder().decode(BulkUpdateResult.self, from: try await request("queue/bulk", method: "PATCH", body: body))
    }

    /// POST /queue/{id}/start (queue:update_*). A 409 means a filament problem; retry with
    /// `skipFilamentCheck` after the user confirms "Print anyway".
    func startQueueItem(_ id: Int, skipFilamentCheck: Bool = false) async throws {
        let query = skipFilamentCheck ? [URLQueryItem(name: "skip_filament_check", value: "true")] : []
        _ = try await request("queue/\(id)/start", method: "POST", query: query)
    }

    /// DELETE /queue/{id} (queue:delete_*). `false` means it was kept as cancelled for its batch order.
    @discardableResult
    func removeQueueItem(_ id: Int) async throws -> Bool {
        let result = try? decoder().decode(DeleteResult.self, from: try await request("queue/\(id)", method: "DELETE"))
        return result?.deleted ?? true
    }

    /// POST /queue/printer/{id}/resume (queue:update_all): clear the failed-print gate, restore skipped jobs.
    func resumePrinterQueue(_ printerId: Int) async throws -> ResumeResult {
        try decoder().decode(ResumeResult.self, from: try await request("queue/printer/\(printerId)/resume", method: "POST"))
    }

    /// POST /queue/model/{model}/resume (queue:update_all): same gate for "Any <model>" jobs.
    func resumeModelQueue(_ model: String) async throws -> ResumeResult {
        let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        return try decoder().decode(ResumeResult.self, from: try await request("queue/model/\(escaped)/resume", method: "POST"))
    }

    /// POST /queue/ (queue:create). Returns nothing useful when quantity > 1 (a batch is created).
    func addToQueue(_ body: QueueCreateBody) async throws {
        _ = try await request("queue/", method: "POST", body: body)
    }

    // MARK: Batches

    /// GET /queue/batches?status=active (queue:read_*).
    func queueBatches(status: String? = "active") async throws -> [QueueBatch] {
        try await get("queue/batches", query: status.map { [URLQueryItem(name: "status", value: $0)] } ?? [])
    }

    /// GET /queue/batches/{id} (queue:read_*).
    func queueBatch(_ id: Int) async throws -> QueueBatch { try await get("queue/batches/\(id)") }

    /// POST /queue/batches/{id}/dispatch (queue:create): queue the runs the order still owes.
    func dispatchBatch(_ id: Int, plateId: Int? = nil, onlyPlate: Bool = false) async throws -> QueueBatch {
        struct Body: Encodable { let plateId: Int?; let onlyPlate: Bool }
        return try decoder().decode(QueueBatch.self, from: try await request("queue/batches/\(id)/dispatch", method: "POST",
                                                                             body: Body(plateId: plateId, onlyPlate: onlyPlate)))
    }

    /// POST /queue/batches/{id}/ungroup (queue:update_own | update_all): disband, items stay queued.
    func ungroupBatch(_ id: Int) async throws -> UngroupResult {
        try decoder().decode(UngroupResult.self, from: try await request("queue/batches/\(id)/ungroup", method: "POST"))
    }

    /// DELETE /queue/batches/{id} (queue:delete_all): cancel the whole batch.
    func cancelBatch(_ id: Int) async throws {
        _ = try await request("queue/batches/\(id)", method: "DELETE")
    }
}

// MARK: AMS mapping inputs

extension APIClient {
    /// GET /archives/{id}/filament-requirements?plate_id= (archives:read_all | read_own).
    func archiveFilamentNeeds(_ id: Int, plateId: Int?) async throws -> [FilamentNeed] {
        let query = plateId.map { [URLQueryItem(name: "plate_id", value: String($0))] } ?? []
        let response: FilamentNeedsResponse = try await get("archives/\(id)/filament-requirements", query: query)
        return response.filaments
    }

    /// GET /library/files/{id}/filament-requirements?plate_id= (library:read_all | read_own).
    func libraryFilamentNeeds(_ id: Int, plateId: Int?) async throws -> [FilamentNeed] {
        let query = plateId.map { [URLQueryItem(name: "plate_id", value: String($0))] } ?? []
        let response: FilamentNeedsResponse = try await get("library/files/\(id)/filament-requirements", query: query)
        return response.filaments
    }

    /// GET /printers/{id}/status (printers:read), reduced to loaded trays for AMS mapping.
    func mappingStatus(printerId: Int) async throws -> MappingPrinterStatus {
        try await get("printers/\(printerId)/status")
    }
}
