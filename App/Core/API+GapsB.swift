import Foundation

/// Gaps B: Manyfold setup, spool catalog, library tags / zip / combine / slice / external folders,
/// external-link management and connection settings (Bambuddy 1.3.0). Calls marked "admin" are
/// settings:update (or a permission API keys can't hold), which Bambuddy refuses for API keys, so they
/// take the sign-in session's JWT as `bearer`.
extension APIClient {
    // MARK: Manyfold connection (GET needs settings:read; PUT/DELETE/test need settings:update; all admin)

    /// GET /manyfold/config -> {url, client_id, has_client_secret, configured}. The secret never comes back.
    func mfyConfig(bearer: String?) async throws -> MfyConfig { try await get("manyfold/config", bearer: bearer) }

    /// PUT /manyfold/config {url, client_id, client_secret?}. An empty/nil secret keeps the stored one.
    func mfySaveConfig(url: String, clientId: String, clientSecret: String?, bearer: String?) async throws -> MfyConfig {
        struct Body: Encodable { let url: String; let clientId: String; let clientSecret: String? }
        return try decoder().decode(MfyConfig.self, from: try await request(
            "manyfold/config", method: "PUT", body: Body(url: url, clientId: clientId, clientSecret: clientSecret), bearer: bearer))
    }

    /// DELETE /manyfold/config -> 204. Files imported earlier stay in the library.
    func mfyDeleteConfig(bearer: String?) async throws { _ = try await request("manyfold/config", method: "DELETE", bearer: bearer) }

    /// POST /manyfold/config/test {url, client_id, client_secret?} -> {model_count}. Nothing is stored.
    func mfyTestConfig(url: String, clientId: String, clientSecret: String?, bearer: String?) async throws -> Int {
        struct Body: Encodable { let url: String; let clientId: String; let clientSecret: String? }
        struct Result: Decodable { let modelCount: Int }
        let data = try await request("manyfold/config/test", method: "POST",
                                     body: Body(url: url, clientId: clientId, clientSecret: clientSecret), bearer: bearer)
        return try decoder().decode(Result.self, from: data).modelCount
    }

    // MARK: Spool catalog (GET inventory:read; writes inventory:update, API key scope can_manage_inventory)

    /// GET /inventory/catalog -> [{id, name, weight, is_default}] ordered by name.
    func spoolCatalog() async throws -> [SpoolCatalogEntry] { try await get("inventory/catalog") }

    /// POST /inventory/catalog {name, weight}
    func createSpoolCatalogEntry(name: String, weight: Int) async throws -> SpoolCatalogEntry {
        struct Body: Encodable { let name: String; let weight: Int }
        return try decoder().decode(SpoolCatalogEntry.self, from: try await request("inventory/catalog", method: "POST", body: Body(name: name, weight: weight)))
    }

    /// PUT /inventory/catalog/{id} {name, weight} (both required by the schema).
    func updateSpoolCatalogEntry(_ id: Int, name: String, weight: Int) async throws -> SpoolCatalogEntry {
        struct Body: Encodable { let name: String; let weight: Int }
        return try decoder().decode(SpoolCatalogEntry.self, from: try await request("inventory/catalog/\(id)", method: "PUT", body: Body(name: name, weight: weight)))
    }

    /// DELETE /inventory/catalog/{id} -> {status: deleted}
    func deleteSpoolCatalogEntry(_ id: Int) async throws { _ = try await request("inventory/catalog/\(id)", method: "DELETE") }

    /// POST /inventory/catalog/bulk-delete {ids} -> {deleted}
    func bulkDeleteSpoolCatalog(_ ids: [Int]) async throws {
        struct Body: Encodable { let ids: [Int] }
        _ = try await request("inventory/catalog/bulk-delete", method: "POST", body: Body(ids: ids))
    }

    /// POST /inventory/catalog/reset: deletes every entry and re-seeds Bambuddy's defaults.
    func resetSpoolCatalog() async throws { _ = try await request("inventory/catalog/reset", method: "POST") }

    // MARK: Library tags (library:update_all; API key scope can_manage_library)

    /// POST /library/tags {name} (1...64 chars) -> 201. Duplicate (case-insensitive) is 409.
    @discardableResult
    func libCreateTag(name: String) async throws -> LibTag {
        struct Body: Encodable { let name: String }
        return try decoder().decode(LibTag.self, from: try await request("library/tags", method: "POST", body: Body(name: name)))
    }

    /// PATCH /library/tags/{id} {name}
    @discardableResult
    func libRenameTag(_ id: Int, name: String) async throws -> LibTag {
        struct Body: Encodable { let name: String }
        return try decoder().decode(LibTag.self, from: try await request("library/tags/\(id)", method: "PATCH", body: Body(name: name)))
    }

    /// DELETE /library/tags/{id} -> 204. Files keep existing; only the label goes.
    func libDeleteTag(_ id: Int) async throws { _ = try await request("library/tags/\(id)", method: "DELETE") }

    // MARK: Library ZIP / combine (library:upload)

    /// POST /library/files/extract-zip?folder_id&preserve_structure&create_folder_from_zip&generate_stl_thumbnails,
    /// multipart field `file` (must end in .zip). Not into an external folder (the server answers 400/403).
    func libExtractZip(fileURL: URL, folderId: Int?, preserveStructure: Bool, createFolderFromZip: Bool,
                       generateThumbnails: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> LibZipResult {
        var query = [URLQueryItem(name: "preserve_structure", value: preserveStructure ? "true" : "false"),
                     URLQueryItem(name: "create_folder_from_zip", value: createFolderFromZip ? "true" : "false"),
                     URLQueryItem(name: "generate_stl_thumbnails", value: generateThumbnails ? "true" : "false")]
        if let folderId { query.append(URLQueryItem(name: "folder_id", value: String(folderId))) }
        let data = try await uploadMultipart(path: "library/files/extract-zip", query: query, fileURL: fileURL, progress: progress)
        return try decoder().decode(LibZipResult.self, from: data)
    }

    /// POST /library/files/combine {items: [{file_id, copies 1...100}], filename, folder_id}. STL sources only;
    /// writes a new multi-object 3MF and leaves the sources alone.
    func libCombine(items: [(fileId: Int, copies: Int)], filename: String, folderId: Int?) async throws -> LibUploadResult {
        struct Item: Encodable { let fileId: Int; let copies: Int }
        struct Body: Encodable { let items: [Item]; let filename: String; let folderId: Int? }
        let body = Body(items: items.map { Item(fileId: $0.fileId, copies: $0.copies) }, filename: filename, folderId: folderId)
        // Meshes are merged server side before it answers, so give it longer than the default 30 s.
        let data = try await longJSON("library/files/combine", method: "POST", body: body, timeout: 180)
        return try decoder().decode(LibUploadResult.self, from: data)
    }

    // MARK: Library slicing (library:upload; poll with library:read_*)

    /// GET /library/files/{id}/filament-requirements?plate_id&full_slots=true: one entry per project slot (3MF).
    func libSliceSlots(_ id: Int, plateId: Int?) async throws -> [FilamentNeed] {
        var query = [URLQueryItem(name: "full_slots", value: "true")]
        if let plateId { query.append(URLQueryItem(name: "plate_id", value: String(plateId))) }
        let response: FilamentNeedsResponse = try await get("library/files/\(id)/filament-requirements", query: query)
        return response.filaments
    }

    /// POST /library/files/{id}/slice -> 202 {job_id, status, status_url}. STL or 3MF only (STEP is refused).
    func libStartSlice(_ id: Int, options: SliceOptions) async throws -> Int {
        struct Started: Decodable { let jobId: Int }
        return try decoder().decode(Started.self, from: try await request("library/files/\(id)/slice", method: "POST", body: options)).jobId
    }

    /// GET /slice-jobs/{id} -> {status: pending|running|completed|failed, progress, result?, error_detail?}.
    func sliceJob(_ id: Int) async throws -> SliceJobState { try await get("slice-jobs/\(id)") }

    // MARK: External folders (admin: settings:update; scan: library:upload)

    /// POST /library/folders/external {name, external_path, readonly, show_hidden, parent_id}. The path is a
    /// directory on the Bambuddy host and must sit under the operator's BAMBUDDY_EXTERNAL_ROOTS allowlist.
    @discardableResult
    func libLinkExternalFolder(name: String, path: String, readonly: Bool, showHidden: Bool, parentId: Int?,
                               bearer: String?) async throws -> Int {
        struct Body: Encodable { let name: String; let externalPath: String; let readonly: Bool; let showHidden: Bool; let parentId: Int? }
        struct Result: Decodable { let id: Int }
        let data = try await request("library/folders/external", method: "POST",
                                     body: Body(name: name, externalPath: path, readonly: readonly, showHidden: showHidden, parentId: parentId),
                                     bearer: bearer)
        return try decoder().decode(Result.self, from: data).id
    }

    /// POST /library/folders/{id}/scan -> {status, added, removed}: syncs the files found on disk.
    func libScanFolder(_ id: Int) async throws -> (added: Int, removed: Int) {
        struct Result: Decodable { let added: Int?; let removed: Int? }
        let data = try await longJSON("library/folders/\(id)/scan", method: "POST", body: nil, timeout: 180)
        let result = try decoder().decode(Result.self, from: data)
        return (result.added ?? 0, result.removed ?? 0)
    }

    // MARK: External links (create/update/delete/reorder are not API-key mapped: admin session)

    /// POST /external-links/ {name 1...50, url (http/https, 1...500), icon (Lucide name), open_in_new_tab}
    @discardableResult
    func linkCreate(name: String, url: String, icon: String, openInNewTab: Bool, bearer: String?) async throws -> ExtLink {
        struct Body: Encodable { let name: String; let url: String; let icon: String; let openInNewTab: Bool }
        return try decoder().decode(ExtLink.self, from: try await request(
            "external-links/", method: "POST", body: Body(name: name, url: url, icon: icon, openInNewTab: openInNewTab), bearer: bearer))
    }

    /// PATCH /external-links/{id} with only the changed fields (external_links:update).
    @discardableResult
    func linkUpdate(_ id: Int, name: String, url: String, icon: String, openInNewTab: Bool, bearer: String?) async throws -> ExtLink {
        struct Body: Encodable { let name: String; let url: String; let icon: String; let openInNewTab: Bool }
        return try decoder().decode(ExtLink.self, from: try await request(
            "external-links/\(id)", method: "PATCH", body: Body(name: name, url: url, icon: icon, openInNewTab: openInNewTab), bearer: bearer))
    }

    /// DELETE /external-links/{id} (external_links:delete)
    func linkDelete(_ id: Int, bearer: String?) async throws { _ = try await request("external-links/\(id)", method: "DELETE", bearer: bearer) }

    /// PUT /external-links/reorder {ids} (external_links:update): ids in the wanted order.
    func linkReorder(_ ids: [Int], bearer: String?) async throws {
        struct Body: Encodable { let ids: [Int] }
        _ = try await request("external-links/reorder", method: "PUT", body: Body(ids: ids), bearer: bearer)
    }

    // MARK: Home Assistant / Obico connection

    /// POST /smart-plugs/ha/test-connection {url, token} (smart_plugs:control; the "********" placeholder token tests
    /// the saved one and needs settings:update) -> {success, message, error}.
    func haTestConnection(url: String, token: String, bearer: String?) async throws -> AdminJSON {
        struct Body: Encodable { let url: String; let token: String }
        return try AdminJSON.parse(try await request("smart-plugs/ha/test-connection", method: "POST", body: Body(url: url, token: token), bearer: bearer))
    }

    /// POST /obico/test-connection {url, token?}: token omitted = the saved one (saved URL only); "" = no token.
    func obicoTest(url: String, token: String?, bearer: String?) async throws -> AdminJSON {
        struct Body: Encodable { let url: String; let token: String? }
        return try AdminJSON.parse(try await request("obico/test-connection", method: "POST", body: Body(url: url, token: token), bearer: bearer))
    }

    // MARK: Plumbing

    /// JSON call with a longer timeout than `request` (30 s).
    private func longJSON(_ path: String, method: String, body: Encodable?, timeout: TimeInterval) async throws -> Data {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var req = URLRequest(url: base.appending(path: "api/v1/" + path), timeoutInterval: timeout)
        req.httpMethod = method
        ServerConfig.authorize(&req)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            req.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// Multipart upload of one file as field `file`, streamed from a temp body so big archives never sit in memory.
    private func uploadMultipart(path: String, query: [URLQueryItem], fileURL: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var url = base.appending(path: "api/v1/" + path)
        if !query.isEmpty { url.append(queryItems: query) }
        let boundary = "LayerPal-\(UUID().uuidString)"
        let safeName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try input.close()
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var request = URLRequest(url: url, timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        ServerConfig.authorize(&request)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL, delegate: UploadProgressDelegate(progress))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }
}

// MARK: - Models

/// GET /manyfold/config
struct MfyConfig: Decodable {
    let url: String
    let clientId: String
    let hasClientSecret: Bool
    let configured: Bool
}

/// GET /inventory/catalog row: a spool type with its empty-spool weight in grams.
struct SpoolCatalogEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let weight: Int
    let isDefault: Bool
}

/// POST /library/files/extract-zip response.
struct LibZipResult: Decodable {
    struct Item: Decodable, Identifiable { let filename: String; let fileId: Int; var id: Int { fileId } }
    struct Failure: Decodable, Identifiable { let filename: String; let error: String; var id: String { filename + error } }
    let extracted: Int
    let foldersCreated: Int
    let files: [Item]
    let errors: [Failure]
}

/// Body for POST /library/files/{id}/slice. Only fields the app sets are
/// sent; the server's own defaults cover design_overrides, process_overrides and the legacy preset ids.
struct SliceOptions: Encodable {
    struct Ref: Encodable { let source: String; let id: String }
    var printerPreset: Ref
    var processPreset: Ref
    var filamentPresets: [Ref]
    /// "#RRGGBB" per slot, "" for none.
    var filamentColours: [String] = []
    /// nil = the server's default plate 1; 0 = all plates of a 3MF.
    var plate: Int?
    var export3mf = false
    var useEmbeddedSettings = false
    var bedType: String?
    var autoOrient = false
    var autoArrange = false

    private enum CodingKeys: String, CodingKey {
        case printerPreset, processPreset, filamentPresets, filamentColours, plate, useEmbeddedSettings, bedType, autoOrient, autoArrange
        case export3mf = "export_3mf" // convertToSnakeCase would leave "export3mf" as is
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(printerPreset, forKey: .printerPreset)
        try c.encode(processPreset, forKey: .processPreset)
        try c.encode(filamentPresets, forKey: .filamentPresets)
        try c.encode(filamentColours, forKey: .filamentColours)
        try c.encodeIfPresent(plate, forKey: .plate)
        try c.encode(export3mf, forKey: .export3mf)
        try c.encode(useEmbeddedSettings, forKey: .useEmbeddedSettings)
        try c.encodeIfPresent(bedType, forKey: .bedType)
        try c.encode(autoOrient, forKey: .autoOrient)
        try c.encode(autoArrange, forKey: .autoArrange)
    }
}

/// GET /slice-jobs/{id}. `progress` is whatever the sidecar reports, so it is read loosely.
struct SliceJobState: Decodable {
    let status: String
    let errorDetail: String?
    let progress: AdminJSON?
    let result: AdminJSON?

    var isFinished: Bool { status == "completed" || status == "failed" }

    var progressText: String? {
        guard let progress else { return nil }
        // The server sends {stage, total_percent}; the decoder's snake-case conversion makes it totalPercent.
        let stage = progress["stage"]?.string
        let pct = progress["totalPercent"]?.int.flatMap { $0 > 0 ? $0 : nil }
        switch (stage, pct) {
        case let (s?, p?): return "\(s) (\(p)%)"
        case let (s?, nil): return s
        case let (nil, p?): return "\(p)%"
        default: return nil
        }
    }
}

extension SliceJobState {
    private enum CodingKeys: String, CodingKey { case status, errorDetail, progress, result }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        errorDetail = try c.decodeIfPresent(String.self, forKey: .errorDetail)
        progress = try? c.decodeIfPresent(AdminJSONBox.self, forKey: .progress)?.value
        result = try? c.decodeIfPresent(AdminJSONBox.self, forKey: .result)?.value
    }
}

/// Decodes any JSON value into AdminJSON (AdminJSON itself is encode-only).
struct AdminJSONBox: Decodable {
    let value: AdminJSON

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = .null }
        else if let b = try? c.decode(Bool.self) { value = .bool(b) }
        else if let i = try? c.decode(Int.self) { value = .int(i) }
        else if let d = try? c.decode(Double.self) { value = .double(d) }
        else if let s = try? c.decode(String.self) { value = .string(s) }
        else if let a = try? c.decode([AdminJSONBox].self) { value = .array(a.map(\.value)) }
        else if let o = try? c.decode([String: AdminJSONBox].self) { value = .object(o.mapValues(\.value)) }
        else { value = .null }
    }
}
