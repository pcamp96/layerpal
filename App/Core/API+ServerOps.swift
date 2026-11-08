import Foundation

/// Server operations (phase 4D): discovery, camera diagnostics, backups, updates, support,
/// purge and system health (Bambuddy 1.3.0). The server refuses these admin routes for API keys,
/// except system:read, settings:read and printers:read/camera:view, so callers pass the admin session's JWT.
extension APIClient {
    // MARK: Long-running transport

    /// Same as `request` but with a caller-chosen timeout (backup run, restore, git push).
    func opsRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: AdminJSON? = nil,
                    bearer: String?, timeout: TimeInterval = 30) async throws -> Data {
        var request = try opsURLRequest(path, method: method, query: query, bearer: bearer, timeout: timeout)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// Downloads a file response to a temp file named `filename` and returns its URL.
    func opsDownload(_ path: String, filename: String, query: [URLQueryItem] = [], bearer: String?,
                     timeout: TimeInterval = 300) async throws -> URL {
        let request = try opsURLRequest(path, method: "GET", query: query, bearer: bearer, timeout: timeout)
        let (tmp, response) = try await URLSession.shared.download(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            let body = (try? Data(contentsOf: tmp)).map { String(decoding: $0.prefix(2000), as: UTF8.self) } ?? ""
            try? FileManager.default.removeItem(at: tmp)
            throw APIError.http(code, body)
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "layerpal-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appending(path: safeName)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func opsURLRequest(_ path: String, method: String, query: [URLQueryItem], bearer: String?,
                               timeout: TimeInterval) throws -> URLRequest {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var url = base.appending(path: "api/v1/" + path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") } else { ServerConfig.authorize(&request) }
        return request
    }

    func opsJSON(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: AdminJSON? = nil,
                         bearer: String?, timeout: TimeInterval = 30) async throws -> AdminJSON {
        try AdminJSON.parse(try await opsRequest(path, method: method, query: query, body: body, bearer: bearer, timeout: timeout))
    }

    // MARK: Discovery (/discovery, discovery:scan)

    /// GET /discovery/info
    func discoveryInfo(bearer: String?) async throws -> OpsDiscoveryInfo {
        OpsDiscoveryInfo(json: try await opsJSON("discovery/info", bearer: bearer))
    }

    /// POST /discovery/start?duration= (SSDP; native installs only, multicast doesn't cross Docker).
    func startDiscovery(duration: Int, bearer: String?) async throws {
        _ = try await opsRequest("discovery/start", method: "POST", query: [URLQueryItem(name: "duration", value: String(duration))], bearer: bearer)
    }

    /// POST /discovery/stop
    func stopDiscovery(bearer: String?) async throws { _ = try await opsRequest("discovery/stop", method: "POST", bearer: bearer) }

    /// GET /discovery/printers: SSDP and subnet-scan results combined.
    func discoveredPrinters(bearer: String?) async throws -> [OpsDiscoveredPrinter] {
        (try await opsJSON("discovery/printers", bearer: bearer).array ?? []).compactMap(OpsDiscoveredPrinter.init(json:))
    }

    /// POST /discovery/scan {subnet, timeout}: starts a background subnet scan (Docker).
    func startSubnetScan(subnet: String, bearer: String?) async throws {
        _ = try await opsRequest("discovery/scan", method: "POST",
                                 body: .object(["subnet": .string(subnet), "timeout": .double(1.0)]), bearer: bearer)
    }

    /// GET /discovery/scan/status -> {running, scanned, total}
    func subnetScanStatus(bearer: String?) async throws -> (running: Bool, scanned: Int, total: Int) {
        let j = try await opsJSON("discovery/scan/status", bearer: bearer)
        return (j["running"]?.bool ?? false, j["scanned"]?.int ?? 0, j["total"]?.int ?? 0)
    }

    /// POST /discovery/scan/stop
    func stopSubnetScan(bearer: String?) async throws { _ = try await opsRequest("discovery/scan/stop", method: "POST", bearer: bearer) }

    // MARK: Printers extras (/printers)

    /// GET /printers/developer-mode-warnings (printers:read) -> [{printer_id, name}]
    func developerModeWarnings(bearer: String?) async throws -> [Int: String] {
        var out: [Int: String] = [:]
        for item in try await opsJSON("printers/developer-mode-warnings", bearer: bearer).array ?? [] {
            if let id = item["printer_id"]?.int { out[id] = item["name"]?.string ?? "Printer \(id)" }
        }
        return out
    }

    /// GET /printers/usb-cameras (printers:read) -> {cameras: [{device, name, driver?, capabilities, formats?}]}
    func usbCameras(bearer: String?) async throws -> [OpsUSBCamera] {
        (try await opsJSON("printers/usb-cameras", bearer: bearer, timeout: 60)["cameras"]?.array ?? []).compactMap(OpsUSBCamera.init(json:))
    }

    // MARK: Camera (camera:view)

    /// GET /printers/{id}/camera/test: one frame capture, up to 15 s.
    func cameraTest(_ id: Int, bearer: String?) async throws -> OpsCameraTest {
        OpsCameraTest(json: try await opsJSON("printers/\(id)/camera/test", bearer: bearer, timeout: 45))
    }

    /// POST /printers/{id}/camera/diagnose: staged TCP then frame-capture check.
    func cameraDiagnose(_ id: Int, bearer: String?) async throws -> OpsCameraDiagnosis {
        OpsCameraDiagnosis(json: try await opsJSON("printers/\(id)/camera/diagnose", method: "POST", bearer: bearer, timeout: 60))
    }

    /// POST /printers/{id}/camera/external/test {url, camera_type} -> {success, error?, resolution?, ...}
    func externalCameraTest(_ id: Int, url: String, type: String, bearer: String?) async throws -> OpsCameraTest {
        let j = try await opsJSON("printers/\(id)/camera/external/test", method: "POST",
                                  body: .object(["url": .string(url), "camera_type": .string(type)]), bearer: bearer, timeout: 45)
        return OpsCameraTest(json: j)
    }

    // MARK: Local backup (settings:backup, download/restore also admin)

    /// GET /local-backup/status
    func localBackupStatus(bearer: String?) async throws -> OpsLocalBackupStatus {
        OpsLocalBackupStatus(json: try await opsJSON("local-backup/status", bearer: bearer))
    }

    /// GET /local-backup/path-check: writes and removes a probe file.
    func localBackupPathCheck(bearer: String?) async throws -> OpsPathCheck {
        OpsPathCheck(json: try await opsJSON("local-backup/path-check", bearer: bearer))
    }

    /// POST /local-backup/run -> {success, message, filename?, diagnosis?}
    func runLocalBackup(bearer: String?) async throws -> OpsActionResult {
        OpsActionResult(json: try await opsJSON("local-backup/run", method: "POST", bearer: bearer, timeout: 600))
    }

    /// GET /local-backup/backups -> [{filename, size, created_at}]
    func localBackups(bearer: String?) async throws -> [OpsBackupFile] {
        (try await opsJSON("local-backup/backups", bearer: bearer).array ?? []).compactMap(OpsBackupFile.init(json:))
    }

    /// GET /local-backup/backups/{filename}/download (admin + settings:backup)
    func downloadLocalBackup(_ filename: String, bearer: String?) async throws -> URL {
        try await opsDownload("local-backup/backups/\(filename)/download", filename: filename, bearer: bearer, timeout: 900)
    }

    /// POST /local-backup/backups/{filename}/restore (admin + settings:restore). Replaces the
    /// database and data directories; the server needs a restart afterwards.
    func restoreLocalBackup(_ filename: String, bearer: String?) async throws -> OpsActionResult {
        OpsActionResult(json: try await opsJSON("local-backup/backups/\(filename)/restore", method: "POST", bearer: bearer, timeout: 900))
    }

    /// DELETE /local-backup/backups/{filename} (settings:backup) -> {success, message}
    func deleteLocalBackup(_ filename: String, bearer: String?) async throws -> OpsActionResult {
        OpsActionResult(json: try await opsJSON("local-backup/backups/\(filename)", method: "DELETE", bearer: bearer))
    }

    // MARK: GitHub backup (github:backup)

    /// GET /github-backup/config -> config or null when never saved.
    func githubBackupConfig(bearer: String?) async throws -> OpsGitConfig? {
        let j = try await opsJSON("github-backup/config", bearer: bearer)
        return j.object == nil ? nil : OpsGitConfig(json: j)
    }

    /// GET /github-backup/cloud-accounts -> {bambu, orca} counts only.
    func githubCloudAccounts(bearer: String?) async throws -> (bambu: Int, orca: Int) {
        let j = try await opsJSON("github-backup/cloud-accounts", bearer: bearer)
        return (j["bambu"]?.int ?? 0, j["orca"]?.int ?? 0)
    }

    /// GET /github-backup/status
    func githubBackupStatus(bearer: String?) async throws -> OpsGitStatus {
        OpsGitStatus(json: try await opsJSON("github-backup/status", bearer: bearer))
    }

    /// POST /github-backup/config (create or replace; token required) or PATCH (partial).
    func saveGithubConfig(_ body: [String: AdminJSON], create: Bool, bearer: String?) async throws -> OpsGitConfig {
        OpsGitConfig(json: try await opsJSON("github-backup/config", method: create ? "POST" : "PATCH", body: .object(body), bearer: bearer))
    }

    /// DELETE /github-backup/config
    func deleteGithubConfig(bearer: String?) async throws { _ = try await opsRequest("github-backup/config", method: "DELETE", bearer: bearer) }

    /// POST /github-backup/test {repo_url, token, provider} or /test-stored (uses the saved token).
    func testGithub(repoURL: String, token: String?, provider: String, bearer: String?) async throws -> OpsGitTest {
        let j: AdminJSON
        if let token, !token.isEmpty {
            j = try await opsJSON("github-backup/test", method: "POST",
                                  body: .object(["repo_url": .string(repoURL), "token": .string(token), "provider": .string(provider)]),
                                  bearer: bearer, timeout: 60)
        } else {
            j = try await opsJSON("github-backup/test-stored", method: "POST", bearer: bearer, timeout: 60)
        }
        return OpsGitTest(json: j)
    }

    /// POST /github-backup/run -> {success, message, log_id?, commit_sha?, files_changed}
    func runGithubBackup(bearer: String?) async throws -> OpsActionResult {
        OpsActionResult(json: try await opsJSON("github-backup/run", method: "POST", bearer: bearer, timeout: 900))
    }

    /// GET /github-backup/logs?limit=&offset=
    func githubBackupLogs(limit: Int = 50, bearer: String?) async throws -> [OpsGitLog] {
        let q = [URLQueryItem(name: "limit", value: String(limit))]
        return (try await opsJSON("github-backup/logs", query: q, bearer: bearer).array ?? []).compactMap(OpsGitLog.init(json:))
    }

    /// DELETE /github-backup/logs?keep_last= -> {deleted, message}
    func clearGithubBackupLogs(keepLast: Int, bearer: String?) async throws -> Int {
        let j = try await opsJSON("github-backup/logs", method: "DELETE",
                                  query: [URLQueryItem(name: "keep_last", value: String(keepLast))], bearer: bearer)
        return j["deleted"]?.int ?? 0
    }

    // MARK: Updates (/updates)

    /// GET /updates/version (public) -> {version, repo}
    func serverVersion(bearer: String?) async throws -> String {
        try await opsJSON("updates/version", bearer: bearer)["version"]?.string ?? ""
    }

    /// GET /updates/check (system:read). Asks GitHub from the server, so it can be rate limited.
    func checkForUpdates(bearer: String?) async throws -> OpsUpdateCheck {
        OpsUpdateCheck(json: try await opsJSON("updates/check", bearer: bearer, timeout: 45))
    }

    /// GET /updates/status (system:read) -> {status, progress, message, error}
    func updateStatus(bearer: String?) async throws -> OpsUpdateStatus {
        OpsUpdateStatus(json: try await opsJSON("updates/status", bearer: bearer, timeout: 10))
    }

    /// POST /updates/apply (settings:update). Git installs only; Docker, HA add-on and the
    /// Windows installer answer success=false with instructions.
    func applyUpdate(bearer: String?) async throws -> OpsActionResult {
        OpsActionResult(json: try await opsJSON("updates/apply", method: "POST", bearer: bearer, timeout: 60))
    }

    // MARK: Support and bug report

    /// GET /support/debug-logging (settings:read) -> {enabled, enabled_at?, duration_seconds?}
    func debugLogging(bearer: String?) async throws -> (enabled: Bool, since: Date?) {
        let j = try await opsJSON("support/debug-logging", bearer: bearer)
        return (j["enabled"]?.bool ?? false, AdminDate.parse(j["enabled_at"]?.string))
    }

    /// POST /support/debug-logging {enabled} (settings:update)
    func setDebugLogging(_ enabled: Bool, bearer: String?) async throws {
        _ = try await opsRequest("support/debug-logging", method: "POST", body: .object(["enabled": .bool(enabled)]), bearer: bearer)
    }

    /// GET /support/logs?limit=&level=&search= (settings:update), newest first, limit 1...1000.
    func supportLogs(limit: Int, level: String?, search: String?, bearer: String?) async throws -> OpsLogPage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let level { q.append(URLQueryItem(name: "level", value: level)) }
        if let search, !search.isEmpty { q.append(URLQueryItem(name: "search", value: search)) }
        return OpsLogPage(json: try await opsJSON("support/logs", query: q, bearer: bearer, timeout: 60))
    }

    /// DELETE /support/logs (settings:update): truncates the server's log file.
    func clearSupportLogs(bearer: String?) async throws { _ = try await opsRequest("support/logs", method: "DELETE", bearer: bearer) }

    /// GET /support/bundle (settings:update): redacted ZIP. 400 unless debug logging is on.
    func downloadSupportBundle(bearer: String?) async throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return try await opsDownload("support/bundle", filename: "bambuddy-support-\(stamp).zip", bearer: bearer, timeout: 300)
    }

    /// POST /bug-report/start-logging (settings:update) -> {started, was_debug}
    func startBugLogging(bearer: String?) async throws -> Bool {
        try await opsJSON("bug-report/start-logging", method: "POST", bearer: bearer, timeout: 60)["was_debug"]?.bool ?? false
    }

    /// POST /bug-report/stop-logging?was_debug= (settings:update) -> {logs}
    func stopBugLogging(wasDebug: Bool, bearer: String?) async throws -> String {
        let q = [URLQueryItem(name: "was_debug", value: wasDebug ? "true" : "false")]
        return try await opsJSON("bug-report/stop-logging", method: "POST", query: q, bearer: bearer, timeout: 60)["logs"]?.string ?? ""
    }

    /// POST /bug-report/submit (settings:read). The server forwards it to Bambuddy's GitHub
    /// issues through bambuddy.cool; rate limited to 5 per hour.
    /// `screenshotBase64` is a bare base64 JPEG (BugReportRequest.screenshot_base64, no data: prefix).
    func submitBugReport(description: String, email: String?, includeSupportInfo: Bool, debugLogs: String?,
                         screenshotBase64: String? = nil, bearer: String?) async throws -> OpsBugReportResult {
        var body: [String: AdminJSON] = ["description": .string(description), "include_support_info": .bool(includeSupportInfo)]
        if let email, !email.isEmpty { body["email"] = .string(email) }
        if let debugLogs, !debugLogs.isEmpty { body["debug_logs"] = .string(debugLogs) }
        if let screenshotBase64, !screenshotBase64.isEmpty { body["screenshot_base64"] = .string(screenshotBase64) }
        return OpsBugReportResult(json: try await opsJSON("bug-report/submit", method: "POST", body: .object(body), bearer: bearer, timeout: 90))
    }

    // MARK: Purge (archives:purge; library trash library:purge)

    /// GET /archives/purge/preview?older_than_days=&purge_stats=
    func archivePurgePreview(days: Int, purgeStats: Bool, bearer: String?) async throws -> OpsPurgePreview {
        let q = [URLQueryItem(name: "older_than_days", value: String(days)), URLQueryItem(name: "purge_stats", value: purgeStats ? "true" : "false")]
        return OpsPurgePreview(json: try await opsJSON("archives/purge/preview", query: q, bearer: bearer, timeout: 60))
    }

    /// POST /archives/purge {older_than_days, purge_stats} -> {deleted, purge_stats}
    func archivePurge(days: Int, purgeStats: Bool, bearer: String?) async throws -> Int {
        let j = try await opsJSON("archives/purge", method: "POST",
                                  body: .object(["older_than_days": .int(days), "purge_stats": .bool(purgeStats)]), bearer: bearer, timeout: 600)
        return j["deleted"]?.int ?? 0
    }

    /// GET /archives/purge/settings -> {enabled, days, purge_stats}
    func archivePurgeSettings(bearer: String?) async throws -> OpsArchivePurgeSettings {
        OpsArchivePurgeSettings(json: try await opsJSON("archives/purge/settings", bearer: bearer))
    }

    /// PUT /archives/purge/settings (days 7...3650)
    func saveArchivePurgeSettings(_ s: OpsArchivePurgeSettings, bearer: String?) async throws {
        _ = try await opsRequest("archives/purge/settings", method: "PUT",
                                 body: .object(["enabled": .bool(s.enabled), "days": .int(s.days), "purge_stats": .bool(s.purgeStats)]), bearer: bearer)
    }

    /// GET /library/purge/preview?older_than_days=&include_never_printed=
    func libraryPurgePreview(days: Int, includeNeverPrinted: Bool, bearer: String?) async throws -> OpsPurgePreview {
        let q = [URLQueryItem(name: "older_than_days", value: String(days)),
                 URLQueryItem(name: "include_never_printed", value: includeNeverPrinted ? "true" : "false")]
        return OpsPurgePreview(json: try await opsJSON("library/purge/preview", query: q, bearer: bearer, timeout: 60))
    }

    /// POST /library/purge {older_than_days, include_never_printed} -> {moved_to_trash}
    func libraryPurge(days: Int, includeNeverPrinted: Bool, bearer: String?) async throws -> Int {
        let j = try await opsJSON("library/purge", method: "POST",
                                  body: .object(["older_than_days": .int(days), "include_never_printed": .bool(includeNeverPrinted)]),
                                  bearer: bearer, timeout: 600)
        return j["moved_to_trash"]?.int ?? 0
    }

    /// GET /library/trash/settings
    func libraryTrashSettings(bearer: String?) async throws -> OpsTrashSettings {
        OpsTrashSettings(json: try await opsJSON("library/trash/settings", bearer: bearer))
    }

    /// PUT /library/trash/settings (retention 1...365, auto-purge days 7...3650)
    func saveLibraryTrashSettings(_ s: OpsTrashSettings, bearer: String?) async throws {
        _ = try await opsRequest("library/trash/settings", method: "PUT", body: .object([
            "retention_days": .int(s.retentionDays), "auto_purge_enabled": .bool(s.autoPurgeEnabled),
            "auto_purge_days": .int(s.autoPurgeDays), "auto_purge_include_never_printed": .bool(s.autoPurgeIncludeNeverPrinted),
        ]), bearer: bearer)
    }

    // MARK: System (/system, system:read; API keys allowed)

    /// GET /system/health: log scan against Bambuddy's known-issue catalog.
    func systemHealth(bearer: String?) async throws -> OpsHealth {
        OpsHealth(json: try await opsJSON("system/health", bearer: bearer, timeout: 60))
    }

    /// GET /system/storage-usage?refresh= (cached 5 min server-side unless refresh)
    func storageUsage(refresh: Bool, bearer: String?) async throws -> OpsStorage {
        let q = refresh ? [URLQueryItem(name: "refresh", value: "true")] : []
        return OpsStorage(json: try await opsJSON("system/storage-usage", query: q, bearer: bearer, timeout: 120))
    }

    /// GET /system/db-pool
    func dbPool(bearer: String?) async throws -> OpsDBPool {
        OpsDBPool(json: try await opsJSON("system/db-pool", bearer: bearer))
    }
}
