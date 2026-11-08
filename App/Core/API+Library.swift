import Foundation

/// File Manager, trash and MakerWorld endpoints (phase 2B, Bambuddy 1.3.0). Reads need library:read_all | library:read_own; the write permissions are
/// noted per call. Writes made with an API key also need the key's `can_manage_library` scope.
extension APIClient {
    // MARK: Read

    /// GET /library/folders: the whole visible tree.
    func libFolderTree() async throws -> [LibFolderNode] { try await get("library/folders") }

    /// GET /library/files. `folderId` nil with `includeRoot` lists the root; `includeRoot: false`
    /// with no folder lists every file. `tagIds` (AND) bypasses the folder filter server-side.
    func libFiles(folderId: Int?, includeRoot: Bool = true, recursive: Bool = false, tagIds: [Int] = []) async throws -> [LibFileItem] {
        var query: [URLQueryItem] = []
        if let folderId { query.append(URLQueryItem(name: "folder_id", value: String(folderId))) }
        query.append(URLQueryItem(name: "include_root", value: includeRoot ? "true" : "false"))
        if recursive { query.append(URLQueryItem(name: "recursive", value: "true")) }
        for t in tagIds { query.append(URLQueryItem(name: "tag_ids", value: String(t))) }
        return try await get("library/files", query: query)
    }

    /// GET /library/files/{id}
    func libFile(_ id: Int) async throws -> LibFileDetail { try await get("library/files/\(id)") }

    /// GET /library/files/{id}/plates (3MF only; others return an empty list).
    func libPlates(_ id: Int) async throws -> [LibPlate] {
        let r: LibPlatesResponse = try await get("library/files/\(id)/plates")
        return r.plates
    }

    /// GET /library/tags
    func libTags() async throws -> [LibTag] { try await get("library/tags") }

    // MARK: Files (write)

    /// PUT /library/files/{id} (library:update_all, or update_own on the user's own files).
    /// Send only changed fields: `filename`, `notes` ("" clears), `folder_id` (0 = root).
    func libUpdateFile(_ id: Int, _ patch: LibPatch) async throws -> LibFileDetail {
        try decoder().decode(LibFileDetail.self, from: try await request("library/files/\(id)", method: "PUT", body: patch))
    }

    /// POST /library/files/move {file_ids, folder_id} (library:update_*). nil folder = root.
    /// Returns how many moved; the server skips files the caller doesn't own.
    @discardableResult
    func libMoveFiles(_ ids: [Int], to folderId: Int?) async throws -> Int {
        struct Body: Encodable {
            let fileIds: [Int]
            let folderId: Int?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(fileIds, forKey: .fileIds)
                try c.encode(folderId, forKey: .folderId) // explicit null = library root
            }

            enum Keys: String, CodingKey { case fileIds = "file_ids", folderId = "folder_id" }
        }
        struct Result: Decodable { let moved: Int }
        let data = try await request("library/files/move", method: "POST", body: Body(fileIds: ids, folderId: folderId))
        return (try? decoder().decode(Result.self, from: data))?.moved ?? 0
    }

    /// DELETE /library/files/{id} (library:delete_all | delete_own). Managed files go to the trash
    /// (`true`); files in linked external folders are removed outright (`false`).
    @discardableResult
    func libDeleteFile(_ id: Int) async throws -> Bool {
        let data = try await request("library/files/\(id)", method: "DELETE")
        return (try? decoder().decode(LibDeleteResult.self, from: data))?.trashed ?? true
    }

    /// POST /library/tags/bulk-assign (library:update_all | update_own). action: add | remove | replace.
    func libAssignTags(fileIds: [Int], tagIds: [Int], action: String) async throws {
        struct Body: Encodable { let fileIds: [Int]; let tagIds: [Int]; let action: String }
        _ = try await request("library/tags/bulk-assign", method: "POST", body: Body(fileIds: fileIds, tagIds: tagIds, action: action))
    }

    // MARK: Folders (write)

    /// POST /library/folders {name, parent_id} (library:upload).
    func libCreateFolder(name: String, parentId: Int?) async throws {
        struct Body: Encodable { let name: String; let parentId: Int? }
        _ = try await request("library/folders", method: "POST", body: Body(name: name, parentId: parentId))
    }

    /// PUT /library/folders/{id} {name} (library:update_all | update_own for the owner).
    func libRenameFolder(_ id: Int, name: String) async throws {
        var patch = LibPatch()
        patch["name"] = .string(name)
        _ = try await request("library/folders/\(id)", method: "PUT", body: patch)
    }

    /// PUT /library/folders/{id} {parent_id} (0 = root). Same permission as rename.
    func libMoveFolder(_ id: Int, to parentId: Int?) async throws {
        var patch = LibPatch()
        patch["parent_id"] = .int(parentId ?? 0)
        _ = try await request("library/folders/\(id)", method: "PUT", body: patch)
    }

    /// DELETE /library/folders/{id} (library:delete_all | delete_own): the folder and everything in it.
    func libDeleteFolder(_ id: Int) async throws {
        _ = try await request("library/folders/\(id)", method: "DELETE")
    }

    // MARK: Trash (library:delete_all | delete_own; "own" sees only the user's files)

    /// GET /library/trash
    func libTrash(limit: Int = 200, offset: Int = 0) async throws -> LibTrashPage {
        try await get("library/trash", query: [URLQueryItem(name: "limit", value: String(limit)),
                                               URLQueryItem(name: "offset", value: String(offset))])
    }

    /// POST /library/trash/{id}/restore
    func libRestore(_ id: Int) async throws { _ = try await request("library/trash/\(id)/restore", method: "POST") }

    /// DELETE /library/trash/{id}: permanent.
    func libPurge(_ id: Int) async throws { _ = try await request("library/trash/\(id)", method: "DELETE") }

    /// DELETE /library/trash: permanently deletes everything in the caller's scope.
    @discardableResult
    func libEmptyTrash() async throws -> Int {
        struct Result: Decodable { let deleted: Int }
        let data = try await request("library/trash", method: "DELETE")
        return (try? decoder().decode(Result.self, from: data))?.deleted ?? 0
    }

    // MARK: Upload (library:upload; API key scope can_manage_library)

    /// POST /library/files?folder_id=... multipart field `file` (folder_id is a query parameter).
    /// The server accepts 3MF (zip), `.gcode.3mf`, STL, images and PDF; a raw `.gcode` is rejected
    /// with 400. `progress` receives 0...1 as the body goes out.
    func libUpload(fileURL: URL, folderId: Int?, progress: @escaping @Sendable (Double) -> Void) async throws -> LibUploadResult {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var url = base.appending(path: "api/v1/library/files")
        if let folderId { url.append(queryItems: [URLQueryItem(name: "folder_id", value: String(folderId))]) }

        let boundary = "LayerPal-\(UUID().uuidString)"
        let safeName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        // Stream the file into a temp body so a large 3MF never sits fully in memory.
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

        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        ServerConfig.authorize(&request)

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL, delegate: UploadProgressDelegate(progress))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return try decoder().decode(LibUploadResult.self, from: data)
    }

    // MARK: MakerWorld (makerworld:view to resolve and list, makerworld:import to import)

    /// GET /makerworld/status: whether the server has a Bambu Cloud token (imports need one).
    func makerWorldStatus() async throws -> MWStatus { try await get("makerworld/status") }

    /// POST /makerworld/resolve {url}
    func makerWorldResolve(url: String) async throws -> MWResolved {
        struct Body: Encodable { let url: String }
        return try decoder().decode(MWResolved.self, from: try await slowPost("makerworld/resolve", body: Body(url: url), timeout: 60))
    }

    /// POST /makerworld/import {model_id, profile_id, instance_id, folder_id}
    func makerWorldImport(modelId: Int, instanceId: Int?, profileId: Int?, folderId: Int?) async throws -> MWImportResult {
        struct Body: Encodable {
            let modelId: Int
            let instanceId: Int?
            let profileId: Int?
            let folderId: Int?
        }
        // The server downloads the 3MF from MakerWorld before it answers, so allow a few minutes.
        return try decoder().decode(MWImportResult.self, from: try await slowPost(
            "makerworld/import", body: Body(modelId: modelId, instanceId: instanceId, profileId: profileId, folderId: folderId),
            timeout: 240))
    }

    /// GET /makerworld/recent-imports?limit= (server clamps to 1...50)
    func makerWorldRecent(limit: Int = 15) async throws -> [MWRecentImport] {
        try await get("makerworld/recent-imports", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// JSON POST with a longer timeout than `request` (which allows 15 seconds).
    private func slowPost(_ path: String, body: Encodable, timeout: TimeInterval) async throws -> Data {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var request = URLRequest(url: base.appending(path: "api/v1/" + path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        ServerConfig.authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// MakerWorld CDN image through Bambuddy's unauthenticated proxy: GET /makerworld/thumbnail?url=
    func makerWorldImageURL(_ cdn: String) -> URL? {
        guard let base = ServerConfig.serverURL else { return nil }
        var url = base.appending(path: "api/v1/makerworld/thumbnail")
        url.append(queryItems: [URLQueryItem(name: "url", value: cdn)])
        return url
    }
}

/// PUT/PATCH body holding only the keys that were set; nulls are real nulls and doubles are allowed.
struct LibPatch: Encodable {
    enum Value: Encodable {
        case null, bool(Bool), int(Int), double(Double), string(String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case let .bool(v): try c.encode(v)
            case let .int(v): try c.encode(v)
            case let .double(v): try c.encode(v)
            case let .string(v): try c.encode(v)
            }
        }
    }

    var fields: [String: Value] = [:]

    subscript(key: String) -> Value? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    var isEmpty: Bool { fields.isEmpty }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for key in fields.keys.sorted() { try c.encode(fields[key]!, forKey: Key(key)) }
    }
}

/// Reports upload progress for one `URLSession.upload` call.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_: URLSession, task _: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
