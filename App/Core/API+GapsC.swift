import Foundation

/// Endpoints for the sign-in, groups, API-key scope and pipeline-authoring gaps (Bambuddy 1.3.0).
/// Admin-only routes take the admin session's JWT as `bearer`.
extension APIClient {
    // MARK: Two-step sign-in (/mfa)

    /// POST /auth/2fa/email/send (public). Emails a 6-digit code. The server consumes the
    /// pre-auth token and answers with a fresh one (bound to the same `2fa_challenge` cookie),
    /// which the caller must use for the verify step. 400 = no email on the account,
    /// 500 = SMTP not configured, 429 = sent too often.
    func sendEmailTwoFactorCode(preAuthToken: String, server: URL? = nil) async throws -> String {
        struct Body: Encodable { let preAuthToken: String }
        let data = try await request("auth/2fa/email/send", method: "POST", body: Body(preAuthToken: preAuthToken), server: server)
        guard let fresh = try AdminJSON.parse(data)["pre_auth_token"]?.string else {
            throw AdminError.message("Bambuddy didn't send a code. Try again.")
        }
        return fresh
    }

    // MARK: Groups (/groups). Writes need `groups:*` AND an admin account.

    struct PermissionCategory: Decodable, Identifiable {
        struct Item: Decodable, Identifiable { let value: String; let label: String; var id: String { value } }
        let name: String
        let permissions: [Item]
        var id: String { name }
    }

    /// GET /groups/permissions (groups:read): every permission, by area.
    func groupPermissionCategories(bearer: String?) async throws -> [PermissionCategory] {
        struct Response: Decodable { let categories: [PermissionCategory] }
        let response: Response = try await get("groups/permissions", bearer: bearer)
        return response.categories
    }

    struct GroupMember: Decodable, Identifiable, Hashable {
        let id: Int
        let username: String
        let isActive: Bool
    }

    struct GroupDetail: Decodable {
        let id: Int
        let name: String
        let description: String?
        let permissions: [String]
        let isSystem: Bool
        let restrictPrinters: Bool
        let userCount: Int
        let users: [GroupMember]
    }

    /// GET /groups/{id} (groups:read): includes members.
    func groupDetail(_ id: Int, bearer: String?) async throws -> GroupDetail { try await get("groups/\(id)", bearer: bearer) }

    /// POST /groups/ (groups:create + admin). Name must be unique; every permission must be a known one.
    func createGroup(name: String, description: String, permissions: [String], bearer: String?) async throws {
        let body = AdminJSON.object(["name": .string(name), "description": .string(description),
                                     "permissions": .array(permissions.map { .string($0) })])
        _ = try await request("groups/", method: "POST", body: body, bearer: bearer)
    }

    /// PATCH /groups/{id} (groups:update + admin). System groups can't be renamed or have permissions changed.
    func updateGroup(_ id: Int, patch: AdminJSON, bearer: String?) async throws {
        _ = try await request("groups/\(id)", method: "PATCH", body: patch, bearer: bearer)
    }

    /// DELETE /groups/{id} (groups:delete + admin). System groups can't be deleted; answers 204.
    func deleteGroup(_ id: Int, bearer: String?) async throws {
        _ = try await request("groups/\(id)", method: "DELETE", bearer: bearer)
    }

    /// POST /groups/{id}/users/{userId} (groups:update + admin). 400 if already a member.
    func addUserToGroup(_ groupId: Int, userId: Int, bearer: String?) async throws {
        _ = try await request("groups/\(groupId)/users/\(userId)", method: "POST", bearer: bearer)
    }

    /// DELETE /groups/{id}/users/{userId} (groups:update + admin). 400 if not a member.
    func removeUserFromGroup(_ groupId: Int, userId: Int, bearer: String?) async throws {
        _ = try await request("groups/\(groupId)/users/\(userId)", method: "DELETE", bearer: bearer)
    }

    // MARK: API-key printer scope (/api-keys)

    /// GET /api-keys/ read for `printer_ids` only: id -> printers the key is limited to (nil = all printers).
    func adminAPIKeyPrinterScopes(bearer: String?) async throws -> [Int: [Int]] {
        let json = try AdminJSON.parse(try await request("api-keys/", bearer: bearer))
        var scopes: [Int: [Int]] = [:]
        for item in json.array ?? [] {
            guard let id = item["id"]?.int, let ids = item["printer_ids"]?.array else { continue }
            scopes[id] = ids.compactMap(\.int)
        }
        return scopes
    }

    /// PATCH /api-keys/{id} {printer_ids} (api_keys:update). Replaces the list. The route ignores
    /// null, so a restricted key can't be widened back to "all printers" by PATCH.
    func setAPIKeyPrinters(_ id: Int, printerIds: [Int], bearer: String?) async throws {
        let body = AdminJSON.object(["printer_ids": .array(printerIds.map { .int($0) })])
        _ = try await request("api-keys/\(id)", method: "PATCH", body: body, bearer: bearer)
    }

    // MARK: Slicer pipelines, authoring. pipelines:write is admin-only.

    /// GET /slicer/presets with the admin JWT (library:upload). The signed-in user's cloud tiers are included.
    func slicerPresets(bearer: String?) async throws -> SlicerPresetsResponse { try await get("slicer/presets", bearer: bearer) }

    /// GET /slicer-pipelines/ (pipelines:read) -> {pipelines: [...]}, read loosely to keep preset refs.
    func authoringPipelines(bearer: String?) async throws -> [PipelineConfig] {
        let json = try AdminJSON.parse(try await request("slicer-pipelines/", bearer: bearer))
        return (json["pipelines"]?.array ?? []).compactMap(PipelineConfig.init(json:))
    }

    /// POST /slicer-pipelines/ (pipelines:write). The create schema has no target fields, so a target
    /// is applied with a follow-up PUT. Returns the new id.
    func createPipeline(_ draft: PipelineConfig, bearer: String?) async throws -> Int {
        var body = draft.presetBody()
        body["name"] = .string(draft.name)
        body["description"] = .string(draft.description)
        if !draft.bedType.isEmpty { body["bed_type"] = .string(draft.bedType) }
        let json = try AdminJSON.parse(try await request("slicer-pipelines/", method: "POST", body: AdminJSON.object(body), bearer: bearer))
        guard let id = json["id"]?.int else { throw AdminError.message("Bambuddy didn't return the new pipeline.") }
        try await updatePipeline(id, draft, includePresets: false, bearer: bearer)
        return id
    }

    /// PUT /slicer-pipelines/{id} (pipelines:write). Only sent fields change; presets and filaments are
    /// replaced wholesale. The route ignores null, so "" clears description and bed type, and
    /// target_printer_id 0 clears the printer.
    func updatePipeline(_ id: Int, _ draft: PipelineConfig, includePresets: Bool = true, bearer: String?) async throws {
        var body: [String: AdminJSON] = [
            "name": .string(draft.name),
            "description": .string(draft.description),
            "bed_type": .string(draft.bedType),
            "target_kind": .string(draft.targetKind),
            "target_printer_id": .int(draft.targetKind == "specific_printer" ? (draft.targetPrinterId ?? 0) : 0),
            "target_model_class": .string(draft.targetKind == "printer_class" ? draft.targetModelClass : ""),
            "fanout_strategy": .string(draft.fanoutStrategy),
        ]
        if includePresets { body.merge(draft.presetBody()) { $1 } }
        _ = try await request("slicer-pipelines/\(id)", method: "PUT", body: AdminJSON.object(body), bearer: bearer)
    }

    /// DELETE /slicer-pipelines/{id} (pipelines:write): soft delete; run history keeps resolving it. 204.
    func deletePipeline(_ id: Int, bearer: String?) async throws {
        _ = try await request("slicer-pipelines/\(id)", method: "DELETE", bearer: bearer)
    }

    /// POST /pipeline-runs/clear (pipelines:write): deletes finished runs (completed, failed, cancelled,
    /// partial failure) the caller may cancel; active runs stay. Returns how many were removed.
    func clearPipelineRuns(bearer: String?) async throws -> Int {
        let json = try AdminJSON.parse(try await request("pipeline-runs/clear", method: "POST", bearer: bearer))
        return json["deleted"]?.int ?? 0
    }
}

// MARK: - Pipeline definition

/// One pipeline as the editor sees it. Preset refs are `source` + `id`.
struct PipelineConfig: Identifiable, Hashable {
    struct Ref: Hashable { var source: String; var id: String }

    var id = 0
    var name = ""
    var description = ""
    var printer: Ref?
    var process: Ref?
    var filaments: [Ref] = []
    var bedType = ""
    var targetKind = "printer_class"
    var targetPrinterId: Int?
    var targetModelClass = ""
    var fanoutStrategy = "max_parallel"

    static let bedTypes = ["Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate", "Supertack Plate", "Textured Cool Plate"]
    static let fanouts: [(value: String, label: String)] = [
        ("max_parallel", "Spread across idle printers"), ("round_robin", "Round robin"), ("fill_one_first", "Fill one printer first"),
    ]

    init() {}

    init?(json: AdminJSON) {
        guard let o = json.object, let id = o["id"]?.int else { return nil }
        self.id = id
        name = o["name"]?.string ?? "Pipeline \(id)"
        description = o["description"]?.string ?? ""
        printer = Self.ref(o["printer_preset"])
        process = Self.ref(o["process_preset"])
        filaments = (o["filament_presets"]?.array ?? []).compactMap(Self.ref)
        bedType = o["bed_type"]?.string ?? ""
        targetKind = o["target_kind"]?.string ?? "printer_class"
        targetPrinterId = o["target_printer_id"]?.int
        targetModelClass = o["target_model_class"]?.string ?? ""
        fanoutStrategy = o["fanout_strategy"]?.string ?? "max_parallel"
    }

    private static func ref(_ json: AdminJSON?) -> Ref? {
        guard let source = json?["source"]?.string, let id = json?["id"]?.string else { return nil }
        return Ref(source: source, id: id)
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && printer != nil && process != nil && !filaments.isEmpty
    }

    func presetBody() -> [String: AdminJSON] {
        func obj(_ r: Ref) -> AdminJSON { .object(["source": .string(r.source), "id": .string(r.id)]) }
        var body: [String: AdminJSON] = ["filament_presets": .array(filaments.map(obj))]
        if let printer { body["printer_preset"] = obj(printer) }
        if let process { body["process_preset"] = obj(process) }
        return body
    }
}
