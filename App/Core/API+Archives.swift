import Foundation

/// Archive and project endpoints added in phase 1B (/archives, /projects; Bambuddy 1.3.0).
extension APIClient {
    /// PATCH /archives/{id} (archives:update_all | update_own). Notes, tags (comma-separated),
    /// project_id (null clears), user_verdict ("good" | "reject"), is_favorite.
    func updateArchive(_ id: Int, _ patch: SparsePatch) async throws -> Archive {
        try decoder().decode(Archive.self, from: try await request("archives/\(id)", method: "PATCH", body: patch))
    }

    /// DELETE /archives/{id} (archives:delete_all | delete_own). Soft delete: files go, statistics stay.
    /// 409 if a queue item for it is printing.
    func deleteArchive(_ id: Int) async throws {
        _ = try await request("archives/\(id)", method: "DELETE")
    }

    /// GET /archives/{id}/plates (archives:read_*). Thumbnails: `archives/{id}/plate-thumbnail/{index}`.
    func archivePlates(_ id: Int) async throws -> [ArchivePlate] {
        let response: ArchivePlatesResponse = try await get("archives/\(id)/plates")
        return response.plates
    }

    /// GET /archives/search with the filters the route supports (archives:read_*).
    func searchArchives(_ q: String, status: String?, printerId: Int?, limit: Int = 50, offset: Int = 0) async throws -> [Archive] {
        var query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "offset", value: String(offset))]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let printerId { query.append(URLQueryItem(name: "printer_id", value: String(printerId))) }
        return try await get("archives/search", query: query)
    }

    /// GET /archives/{id}/timelapse (archives:read_*), downloaded to a temp file for AVKit.
    ///
    /// A media token (POST /auth/media-token) cannot be used here: tokens minted by an API key
    /// carry no user and the media routes reject them while auth is on; this app signs in with an
    /// API key. The route accepts the key header directly, so the file is fetched with it.
    func downloadTimelapse(_ id: Int) async throws -> URL {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var request = URLRequest(url: base.appending(path: "api/v1/archives/\(id)/timelapse"), timeoutInterval: 180)
        ServerConfig.authorize(&request)
        let (tmp, response) = try await URLSession.shared.download(for: request)
        let http = response as? HTTPURLResponse
        guard let code = http?.statusCode, (200 ..< 300).contains(code) else {
            let body = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            throw APIError.http(http?.statusCode ?? 0, body)
        }
        let mime = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ext = mime.contains("avi") ? "avi" : (mime.contains("matroska") ? "mkv" : "mp4")
        let dest = FileManager.default.temporaryDirectory.appending(path: "timelapse-\(id)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: Projects

    /// GET /projects/ (projects:read). status: active | completed | archived.
    func projects(status: String? = nil) async throws -> [Project] {
        try await get("projects/", query: status.map { [URLQueryItem(name: "status", value: $0)] } ?? [])
    }

    /// GET /projects/{id} (projects:read).
    func project(_ id: Int) async throws -> Project { try await get("projects/\(id)") }

    /// GET /projects/{id}/archives (projects:read; archives visible to the caller).
    func projectArchives(_ id: Int, limit: Int = 100, offset: Int = 0) async throws -> [Archive] {
        try await get("projects/\(id)/archives", query: [URLQueryItem(name: "limit", value: String(limit)),
                                                          URLQueryItem(name: "offset", value: String(offset))])
    }

    /// POST /projects/ (projects:create; the API key also needs the can_manage_projects scope).
    func createProject(name: String, description: String?, targetCount: Int?, priority: String) async throws -> Project {
        struct Body: Encodable { let name: String; let description: String?; let targetCount: Int?; let priority: String }
        return try decoder().decode(Project.self, from: try await request(
            "projects/", method: "POST",
            body: Body(name: name, description: description?.isEmpty == true ? nil : description, targetCount: targetCount, priority: priority)))
    }

    /// PATCH /projects/{id} (projects:update; API key needs can_manage_projects). status: active | completed | archived.
    func setProjectStatus(_ id: Int, status: String) async throws -> Project {
        var patch = SparsePatch()
        patch["status"] = .string(status)
        return try decoder().decode(Project.self, from: try await request("projects/\(id)", method: "PATCH", body: patch))
    }
}
