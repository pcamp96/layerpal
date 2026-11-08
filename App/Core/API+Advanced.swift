import Foundation

/// Advanced printer operations: motion, calibration, extruder select, printer file browser.
/// Paths, params, limits and permissions checked against the Bambuddy 1.3.0
/// /printers routes. All control routes are `printers:control`;
/// the file routes are `printers:files` (both map to an API key's can_control_printer).
extension APIClient {
    // MARK: Motion (printers:control)

    /// Always runs the printer's full auto-home (bare G28); `axes` is legacy but must be z | xy | all.
    func homeAxes(_ id: Int) async throws {
        _ = try await request("printers/\(id)/home-axes", method: "POST", query: [URLQueryItem(name: "axes", value: "all")])
    }

    /// Relative XY move in mm. Server: non-zero, |x| and |y| <= 200.
    func xyJog(_ id: Int, x: Double, y: Double) async throws {
        _ = try await request("printers/\(id)/xy-jog", method: "POST", query: [
            URLQueryItem(name: "x", value: advNumber(x)),
            URLQueryItem(name: "y", value: advNumber(y)),
        ])
    }

    /// Signed nozzle-to-bed gap change in mm: positive opens the gap, negative closes it, on every model.
    /// Server: non-zero, |distance| <= 200.
    func bedJog(_ id: Int, distance: Double) async throws {
        _ = try await request("printers/\(id)/bed-jog", method: "POST", query: [URLQueryItem(name: "distance", value: advNumber(distance))])
    }

    /// Positive extrudes, negative retracts. Server: non-zero, |distance| <= 100.
    func extruderJog(_ id: Int, distance: Double) async throws {
        _ = try await request("printers/\(id)/extruder-jog", method: "POST", query: [URLQueryItem(name: "distance", value: advNumber(distance))])
    }

    // MARK: Calibration / extruder

    /// At least one routine required (server returns 400 otherwise).
    func startCalibration(_ id: Int, options: Set<AdvCalibration>) async throws {
        _ = try await request("printers/\(id)/calibration", method: "POST",
                              query: AdvCalibration.allCases.map {
                                  URLQueryItem(name: $0.rawValue, value: options.contains($0) ? "true" : "false")
                              })
    }

    /// extruder: 0 = right, 1 = left.
    func selectExtruder(_ id: Int, extruder: Int) async throws {
        _ = try await request("printers/\(id)/select-extruder", method: "POST", query: [URLQueryItem(name: "extruder", value: String(extruder))])
    }

    // MARK: Printer storage (printers:files; storage size is printers:read)

    func printerFiles(_ id: Int, path: String) async throws -> AdvFileListing {
        // The printer's FTP listing can take well over the shared client's 15 s timeout.
        let data = try await advFileRequest("printers/\(id)/files", query: [("path", path)], timeout: 60)
        return try decoder().decode(AdvFileListing.self, from: data)
    }

    func printerStorage(_ id: Int) async throws -> AdvStorage {
        try await get("printers/\(id)/storage")
    }

    func deletePrinterFile(_ id: Int, path: String) async throws {
        _ = try await advFileRequest("printers/\(id)/files", method: "DELETE", query: [("path", path)], timeout: 60)
    }

    /// Downloads one file from the printer to a temp file (the server pulls it over FTP first, so this can be slow).
    func downloadPrinterFile(_ id: Int, path: String) async throws -> URL {
        let request = try advFileURLRequest("printers/\(id)/files/download", method: "GET", query: [("path", path)], timeout: 900)
        let (temp, response) = try await URLSession.shared.download(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            let body = (try? Data(contentsOf: temp)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            try? FileManager.default.removeItem(at: temp)
            throw APIError.http(code, body)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("printer-files", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(id)-\(UUID().uuidString.prefix(8))-" + (path as NSString).lastPathComponent)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    // MARK: Web links

    /// `{server}/gcode-viewer?archive={id}` (the server's G-code viewer page).
    func gcodeViewerURL(archiveId: Int, plate: Int? = nil) -> URL? {
        guard let base = ServerConfig.serverURL else { return nil }
        var url = base.appending(path: "gcode-viewer")
        var items = [URLQueryItem(name: "archive", value: String(archiveId))]
        if let plate { items.append(URLQueryItem(name: "plate", value: String(plate))) }
        url.append(queryItems: items)
        return url
    }

    /// `{server}/overlay/{printerId}` (standalone route; its camera may need a camera token if the server demands one).
    func overlayURL(printerId: Int) -> URL? { ServerConfig.serverURL?.appending(path: "overlay/\(printerId)") }

    /// The web app's printers page (index route). No per-printer deep link exists in 1.3.0.
    func webAppURL() -> URL? { ServerConfig.serverURL }

    // MARK: Helpers

    private func advNumber(_ value: Double) -> String { String(format: "%.2f", value) }

    private func advFileURLRequest(_ path: String, method: String, query: [(String, String)], timeout: TimeInterval) throws -> URLRequest {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        guard var components = URLComponents(url: base.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false) else {
            throw APIError.notConfigured
        }
        // Printer paths can hold "+", "&" and spaces; encode everything outside unreserved characters.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        components.percentEncodedQuery = query.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
        guard let url = components.url else { throw APIError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        ServerConfig.authorize(&request)
        return request
    }

    private func advFileRequest(_ path: String, method: String = "GET", query: [(String, String)], timeout: TimeInterval) async throws -> Data {
        let request = try advFileURLRequest(path, method: method, query: query, timeout: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        if data.isEmpty, method == "GET" { throw APIError.emptyResponse }
        return data
    }
}
