import Foundation

/// Pipelines, Manyfold, virtual printers, camera tokens and external links (Bambuddy 1.3.0).
/// Permissions the server grants API keys work with the app's key; the rest take
/// the signed-in session's JWT as `bearer`.
extension APIClient {
    // MARK: Pipelines (API key: pipelines:read = can_read_status; pipelines:run = can_queue + can_manage_library)

    /// GET /slicer-pipelines/ (pipelines:read) -> {pipelines: [...]}
    func pipePipelines() async throws -> [PipePipeline] {
        struct Wrapper: Decodable { let pipelines: [PipePipeline] }
        let wrapper: Wrapper = try await get("slicer-pipelines/")
        return wrapper.pipelines
    }

    /// GET /pipeline-runs?limit=&offset=&status= (pipelines:read)
    func pipeRuns(limit: Int, offset: Int, status: String?) async throws -> PipeRunPage {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        return try await get("pipeline-runs", query: query)
    }

    /// GET /pipeline-runs/{id} (pipelines:read)
    func pipeRun(_ id: Int) async throws -> PipeRun { try await get("pipeline-runs/\(id)") }

    /// POST /pipeline-runs/{id}/cancel (pipelines:run). In-flight prints keep going on the printer.
    func pipeCancel(_ id: Int) async throws -> PipeRun {
        try decoder().decode(PipeRun.self, from: try await request("pipeline-runs/\(id)/cancel", method: "POST"))
    }

    /// POST /pipeline-runs/{id}/retry-failed (pipelines:run). Starts a new run for the failed/cancelled copies.
    func pipeRetryFailed(_ id: Int) async throws -> PipeRun {
        try decoder().decode(PipeRun.self, from: try await request("pipeline-runs/\(id)/retry-failed", method: "POST"))
    }

    /// POST /slicer-pipelines/{id}/check-eligibility {source_library_file_id} (pipelines:read) -> report.
    func pipeCheckEligibility(pipelineId: Int, libraryFileId: Int) async throws -> PipeEligibility {
        struct Body: Encodable { let sourceLibraryFileId: Int }
        let data = try await request("slicer-pipelines/\(pipelineId)/check-eligibility", method: "POST",
                                     body: Body(sourceLibraryFileId: libraryFileId))
        return PipeEligibility(json: try AdminJSON.parse(data))
    }

    enum PipeRunOutcome {
        case started(PipeRun)
        /// 409: blocking eligibility issues; resend with force to override.
        case blocked(PipeEligibility)
    }

    /// POST /slicer-pipelines/{id}/run {source_library_file_id, copies, force} (pipelines:run).
    func pipeStartRun(pipelineId: Int, libraryFileId: Int, copies: Int, force: Bool) async throws -> PipeRunOutcome {
        struct Body: Encodable { let sourceLibraryFileId: Int; let copies: Int; let force: Bool }
        do {
            let data = try await request("slicer-pipelines/\(pipelineId)/run", method: "POST",
                                         body: Body(sourceLibraryFileId: libraryFileId, copies: copies, force: force))
            return .started(try decoder().decode(PipeRun.self, from: data))
        } catch APIError.http(409, let body) {
            if let json = try? AdminJSON.parse(Data(body.utf8)), let detail = json["detail"], detail.object != nil {
                return .blocked(PipeEligibility(json: detail))
            }
            throw APIError.http(409, body)
        }
    }

    // MARK: Manyfold (manyfold:view = can_read_status; manyfold:import = can_manage_library)

    /// GET /manyfold/status
    func mfyStatus() async throws -> MfyStatus { try await get("manyfold/status") }

    /// GET /manyfold/models?q=&page= (page size is Manyfold's own setting)
    func mfyModels(query: String, page: Int) async throws -> MfyModelPage {
        try await get("manyfold/models", query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(page))])
    }

    /// GET /manyfold/models/{id}
    func mfyModel(_ id: String) async throws -> MfyModel {
        try await get("manyfold/models/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }

    /// GET /manyfold/models/{id}/preview: image bytes (authenticated, so fetched rather than linked).
    func mfyPreview(_ id: String) async throws -> Data {
        try await request("manyfold/models/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/preview")
    }

    /// POST /manyfold/import {model_id, file_id, folder_id}. Only 3MF, STL and STEP are importable.
    /// The server downloads the file before answering, so this allows a few minutes (APIClient.request stops at 15 s).
    func mfyImport(modelId: String, fileId: String, folderId: Int? = nil) async throws -> MfyImportResult {
        struct Body: Encodable { let modelId: String; let fileId: String; let folderId: Int? }
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var req = URLRequest(url: base.appending(path: "api/v1/manyfold/import"), timeoutInterval: 240)
        req.httpMethod = "POST"
        ServerConfig.authorize(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try encoder.encode(Body(modelId: modelId, fileId: fileId, folderId: folderId))
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return try decoder().decode(MfyImportResult.self, from: data)
    }

    // MARK: Virtual printers (settings:read = can_read_status; writes need settings:update = admin session)

    /// GET /virtual-printers -> {printers: [...], models: {code: name}}
    func vpList(bearer: String?) async throws -> [VPrinter] {
        struct Wrapper: Decodable { let printers: [VPrinter] }
        let wrapper: Wrapper = try await get("virtual-printers", bearer: bearer)
        return wrapper.printers
    }

    /// GET /virtual-printers/tailscale-status (settings:read)
    func vpTailscale(bearer: String?) async throws -> VPTailscale { try await get("virtual-printers/tailscale-status", bearer: bearer) }

    /// GET /virtual-printers/{id}/diagnostic (settings:read)
    func vpDiagnostic(_ id: Int, bearer: String?) async throws -> VPDiagnostic { try await get("virtual-printers/\(id)/diagnostic", bearer: bearer) }

    /// PUT /virtual-printers/{id} (settings:update). Send only what changed.
    func vpUpdate(_ id: Int, patch: AdminJSON, bearer: String?) async throws {
        _ = try await request("virtual-printers/\(id)", method: "PUT", body: patch, bearer: bearer)
    }

    // MARK: Long-lived camera tokens (JWT only: camera:view; the route rejects API keys)

    /// GET /auth/tokens: the caller's own tokens.
    func tokList(bearer: String?) async throws -> [TokRecord] { try await get("auth/tokens", bearer: bearer) }

    /// GET /auth/tokens/all (admins only): every active token.
    func tokListAll(bearer: String?) async throws -> [TokRecord] { try await get("auth/tokens/all", bearer: bearer) }

    /// POST /auth/tokens {name, expires_in_days (1...365), scope: camera_stream|camwall|overlay}. The plaintext comes back once.
    func tokCreate(name: String, days: Int, scope: String, bearer: String?) async throws -> TokRecord {
        struct Body: Encodable { let name: String; let expiresInDays: Int; let scope: String }
        return try decoder().decode(TokRecord.self, from: try await request("auth/tokens", method: "POST",
                                                                           body: Body(name: name, expiresInDays: days, scope: scope), bearer: bearer))
    }

    /// DELETE /auth/tokens/{id} (owner or admin) -> 204
    func tokRevoke(_ id: Int, bearer: String?) async throws {
        _ = try await request("auth/tokens/\(id)", method: "DELETE", bearer: bearer)
    }

    // MARK: External links (external_links:read = can_read_status)

    /// GET /external-links/
    func linkList() async throws -> [ExtLink] { try await get("external-links/") }
}
