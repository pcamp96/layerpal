import Foundation

/// Endpoints for the farm-wide views (camera wall, smart plugs, firmware,
/// locations): /camera, /smart-plugs, /bulk and printer locations (Bambuddy 1.3.0).
extension APIClient {
    // MARK: Camera snapshots (camera:view, stream token in the query)

    private static let snapshotSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// GET /printers/{id}/camera/snapshot?token=... Returns JPEG bytes, or nil
    /// when the camera can't deliver (503: offline, busy, still starting).
    func cameraSnapshot(_ printerId: Int) async -> Data? {
        guard let url = await mediaURL("printers/\(printerId)/camera/snapshot") else { return nil }
        guard let (data, response) = try? await Self.snapshotSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Smart plugs (smart_plugs:read / smart_plugs:control)

    /// GET /smart-plugs/
    func smartPlugs() async throws -> [FarmPlug] { try await get("smart-plugs/") }

    /// GET /smart-plugs/{id}/status (asks the device, so call it lazily).
    func smartPlugStatus(_ id: Int) async throws -> FarmPlugStatus { try await get("smart-plugs/\(id)/status") }

    /// POST /smart-plugs/{id}/control {action: on|off|toggle}
    func controlSmartPlug(_ id: Int, action: String) async throws {
        struct Body: Encodable { let action: String }
        _ = try await request("smart-plugs/\(id)/control", method: "POST", body: Body(action: action))
    }

    // MARK: Firmware (firmware:read)

    /// GET /bulk/firmware-updates?ids=1,2,3
    func firmwareUpdates(ids: [Int]) async throws -> [FarmFirmware] {
        try await get("bulk/firmware-updates", query: [URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ","))])
    }

    // MARK: Locations (printers:read to list; printers:update + admin session to change)
    //
    // Bambuddy's API-key allowlist has no printers:update, so every write below takes the admin
    // session's JWT as `bearer`. Moving printers into or out of a location granted to a group is
    // admin-only server-side (403 with the group names).

    /// GET /printer-locations/
    func printerLocations() async throws -> [FarmLocation] { try await get("printer-locations/") }

    /// POST /printer-locations/ {name} (printers:update). 409 if the name exists (case-insensitive).
    func createPrinterLocation(name: String, bearer: String? = nil) async throws {
        struct Body: Encodable { let name: String }
        _ = try await request("printer-locations/", method: "POST", body: Body(name: name), bearer: bearer)
    }

    /// PATCH /printer-locations/ {name, new_name} (printers:update). Moves its printers and queue
    /// targets to the new name in one transaction.
    func renamePrinterLocation(_ name: String, to newName: String, bearer: String?) async throws {
        struct Body: Encodable { let name: String; let newName: String }
        _ = try await request("printer-locations/", method: "PATCH", body: Body(name: name, newName: newName), bearer: bearer)
    }

    /// POST /printer-locations/delete {names} (printers:update). Their printers end up with no location.
    /// Returns (deleted, printers_ungrouped).
    func deletePrinterLocations(_ names: [String], bearer: String?) async throws -> (deleted: Int, printersUngrouped: Int) {
        struct Body: Encodable { let names: [String] }
        let json = try AdminJSON.parse(try await request("printer-locations/delete", method: "POST", body: Body(names: names), bearer: bearer))
        return (json["deleted"]?.int ?? 0, json["printers_ungrouped"]?.int ?? 0)
    }

    /// POST /printer-locations/assign {printer_ids, location} (printers:update); nil location = remove from any.
    func assignPrinters(_ ids: [Int], to location: String?, bearer: String? = nil) async throws {
        struct Body: Encodable {
            let printerIds: [Int]
            let location: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(printerIds, forKey: .printerIds)
                try c.encode(location, forKey: .location) // explicit null clears the location
            }
            enum CodingKeys: String, CodingKey { case printerIds, location }
        }
        _ = try await request("printer-locations/assign", method: "POST", body: Body(printerIds: ids, location: location), bearer: bearer)
    }
}

// MARK: - Models

struct FarmPlug: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let plugType: String?
    let printerId: Int?
    let lastState: String?
    let haEntityId: String?
    let controlsPrinterPower: Bool?
    let enabled: Bool?

    /// Home Assistant scripts run, they don't hold a state.
    var isScript: Bool { haEntityId?.hasPrefix("script.") == true }
    /// MQTT plugs are monitor-only (the control route answers 400).
    var isMonitorOnly: Bool { plugType == "mqtt" }
}

struct FarmPlugEnergy: Decodable, Hashable {
    let power: Double?
    let today: Double?
    let total: Double?
}

struct FarmPlugStatus: Decodable, Hashable {
    let state: String?
    let reachable: Bool?
    let energy: FarmPlugEnergy?
}

struct FarmFirmwareVersion: Decodable, Hashable {
    let version: String
    let releaseNotes: String?
    let releaseTime: String?
}

struct FarmFirmware: Decodable, Identifiable, Hashable {
    let printerId: Int
    let printerName: String
    let model: String?
    let currentVersion: String?
    let latestVersion: String?
    let updateAvailable: Bool
    let releaseNotes: String?
    let availableVersions: [FarmFirmwareVersion]?

    var id: Int { printerId }
}

struct FarmLocation: Decodable, Identifiable, Hashable {
    let name: String
    let printerCount: Int

    var id: String { name }
}
