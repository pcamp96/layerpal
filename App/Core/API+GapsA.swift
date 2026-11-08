import Foundation

/// Gap-closing endpoints for queue, printing, presets and insights (Bambuddy 1.3.0).
///
/// Routes the server refuses for API keys (printers:update, cloud:auth, orca_cloud:auth)
/// take a `bearer` from `AdminSession.perform`.
extension APIClient {
    // MARK: Spool weights

    /// GET /printers/{id}/inventory-remain (printers:read, API key allowed). Grams left per bound tray.
    func inventoryRemain(printerId: Int) async throws -> InventoryRemain {
        try await get("printers/\(printerId)/inventory-remain")
    }

    // MARK: Slot preset memory

    /// GET /printers/{id}/slot-presets/{ams}/{tray} (printers:read, API key allowed). The body is JSON
    /// `null` when nothing is saved for the slot.
    func savedSlotPreset(printerId: Int, amsId: Int, trayId: Int) async throws -> SavedSlotPreset? {
        let data = try await request("printers/\(printerId)/slot-presets/\(amsId)/\(trayId)")
        return try? decoder().decode(SavedSlotPreset.self, from: data)
    }

    /// PUT /printers/{id}/slot-presets/{ams}/{tray} (printers:update, admin only). Everything travels in
    /// the query string. `preset_source`: local | builtin | cloud | orca_cloud. `tray_info_idx` is what the
    /// slot was configured with, so Bambuddy can notice a later re-configuration from elsewhere.
    func saveSlotPreset(printerId: Int, amsId: Int, trayId: Int, presetId: String, presetName: String,
                        source: String, trayInfoIdx: String?, bearer: String?) async throws {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var items = [("preset_id", presetId), ("preset_name", presetName), ("preset_source", source)]
        if let trayInfoIdx, !trayInfoIdx.isEmpty { items.append(("tray_info_idx", trayInfoIdx)) }
        // URLComponents leaves `+` bare and the server would read it as a space ("PLA+"), so encode by hand.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var components = URLComponents(url: base.appending(path: "api/v1/printers/\(printerId)/slot-presets/\(amsId)/\(trayId)"),
                                       resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
        guard let url = components?.url else { throw APIError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "PUT"
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") } else { ServerConfig.authorize(&request) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
    }

    // MARK: Cloud presets (cloud:auth / orca_cloud:auth, admin only)

    // GET /cloud/status (cloud:auth) is `cloudStatus(bearer:)` in API+IntegrationsSetup.swift.

    /// GET /cloud/settings (cloud:auth): the linked account's presets. 401 when not linked or expired.
    func cloudFilamentPresets(bearer: String?) async throws -> [CloudPreset] {
        let response: CloudSettingsResponse = try await get("cloud/settings", bearer: bearer)
        return response.filament
    }

    /// GET /cloud/settings/{id} (cloud:auth): a user preset's own `filament_id`, which is what puts it in the
    /// slot as itself. Nil when the preset carries none (a preset created in Orca slicer has none).
    func cloudPresetFilamentId(_ settingId: String, bearer: String?) async -> String? {
        guard let data = try? await request("cloud/settings/\(settingId)", bearer: bearer),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let id = root["filament_id"] as? String, !id.isEmpty { return id }
        if let setting = root["setting"] as? [String: Any], let id = setting["filament_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// GET /orca-cloud/status (orca_cloud:auth).
    func orcaCloudStatus(bearer: String?) async throws -> OrcaLinkStatus {
        try await get("orca-cloud/status", bearer: bearer)
    }

    /// GET /orca-cloud/profiles (orca_cloud:auth): filament / printer / process, all user-authored.
    func orcaCloudFilamentPresets(bearer: String?) async throws -> [CloudPreset] {
        let response: CloudSettingsResponse = try await get("orca-cloud/profiles", bearer: bearer)
        return response.filament
    }

    // MARK: Print log edits

    /// PATCH /print-log/{id} (archives:update_own | update_all). Only the keys in `patch` change.
    /// `failure_reason` is one of the canonical keys (empty clears it), `status` one of completed | failed |
    /// stopped | cancelled | skipped, `notes` free text (empty clears it).
    func updatePrintLogEntry(_ id: Int, _ patch: SparsePatch) async throws {
        _ = try await request("print-log/\(id)", method: "PATCH", body: patch)
    }

    /// PATCH /archives/{archiveId} with `run_id` (archives:update_own | update_all): set one run's quality
    /// verdict (good | reject, nil clears it). The verdict is not editable through /print-log/{id}.
    func setRunVerdict(archiveId: Int, runId: Int, verdict: String?) async throws {
        var patch = SparsePatch()
        patch["run_id"] = .int(runId)
        patch["user_verdict"] = verdict.map(JSONScalar.string) ?? .null
        patch["user_verdict_source"] = .string("dialog")
        _ = try await request("archives/\(archiveId)", method: "PATCH", body: patch)
    }

    // MARK: Statistics

    /// GET /archives/stats/export?format=csv|xlsx&days=&created_by_id= (stats:read; created_by_id needs stats:filter_by_user).
    /// The route takes a trailing window in days, not a date range. Saved in a temp folder for the share sheet.
    func exportStatsFile(format: String, days: Int, createdBy: Int?) async throws -> URL {
        var query = [URLQueryItem(name: "format", value: format), URLQueryItem(name: "days", value: String(max(1, days)))]
        if let createdBy { query.append(URLQueryItem(name: "created_by_id", value: String(createdBy))) }
        return try await downloadFile("archives/stats/export", query: query, fallbackName: "statistics.\(format)")
    }

    /// POST /archives/recalculate-costs (archives:update_all; the API key needs can_manage_archives).
    /// Reprices every archive and its runs from current spool and filament prices.
    func recalculateCosts() async throws -> CostRecalculation {
        try decoder().decode(CostRecalculation.self, from: try await request("archives/recalculate-costs", method: "POST"))
    }
}

// MARK: - Types

/// GET /printers/{id}/slot-presets/{ams}/{tray}. `presetId` is `local_<n>`, `builtin_<filament id>`,
/// `orca_<uuid>`, or a Bambu Cloud setting id.
struct SavedSlotPreset: Decodable {
    let amsId: Int
    let trayId: Int
    let presetId: String
    let presetName: String
    let trayInfoIdx: String?
}

/// GET /orca-cloud/status (OrcaAuthStatusResponse).
struct OrcaLinkStatus: Decodable {
    let connected: Bool
    let email: String?
}

/// A Bambu Cloud or Orca Cloud preset (SlicerSetting / OrcaProfileMeta).
struct CloudPreset: Decodable, Identifiable, Hashable {
    let settingId: String
    let name: String
    let isCustom: Bool?
    /// The id Bambu Studio puts in an AMS slot for this preset; absent for Orca profiles.
    let filamentId: String?
    var id: String { settingId }
}

struct CloudSettingsResponse: Decodable {
    let filament: [CloudPreset]

    private enum CodingKeys: String, CodingKey { case filament }

    init(from decoder: Decoder) throws {
        filament = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([CloudPreset].self, forKey: .filament) ?? []
    }
}

/// Result of POST /archives/recalculate-costs.
struct CostRecalculation: Decodable {
    let message: String?
    let updated: Int?
    let preserved: Int?
    let usageRepriced: Int?
    let spoolmanUnreachable: Int?
}
