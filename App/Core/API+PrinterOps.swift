import Foundation

/// Printer-screen operations (skip objects, HMS actions, AMS, fans, print
/// options, firmware badge, smart plug). Paths, params and permissions were
/// checked against Bambuddy 1.3.0.
extension APIClient {
    // MARK: Skip objects

    struct OpsPrintableObject: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
        let x: Double?
        let y: Double?
        let skipped: Bool
    }

    struct OpsPrintableObjects: Decodable {
        let objects: [OpsPrintableObject]
        let total: Int?
        let skippedCount: Int?
        let isPrinting: Bool?
    }

    /// `printers:read`. `reload` re-extracts the object list from the archive / printer file.
    func printableObjects(_ id: Int, reload: Bool = false) async throws -> OpsPrintableObjects {
        try await get("printers/\(id)/print/objects", query: reload ? [URLQueryItem(name: "reload", value: "true")] : [])
    }

    /// `printers:control`. The body is a bare JSON array of object ids.
    func skipObjects(_ id: Int, objectIds: [Int]) async throws {
        _ = try await request("printers/\(id)/print/skip-objects", method: "POST", body: objectIds)
    }

    // MARK: HMS

    /// `printers:control`. `printError` is HMSError.fullCode (8 or 16 hex chars).
    func executeHMSAction(_ id: Int, printError: String, action: String, jobId: String?) async throws {
        struct Body: Encodable { let printError: String; let action: String; let jobId: String? }
        _ = try await request("printers/\(id)/hms/execute-action", method: "POST",
                              body: Body(printError: printError, action: action, jobId: jobId))
    }

    // MARK: AMS

    /// `printers:control`. trayId: 0-15 = amsId*4+slot, 128-135 = AMS-HT unit id, 254/255 external.
    /// `extruderId` (0 right, 1 left) only when a Filament Track Switch is fitted.
    func amsLoad(_ id: Int, trayId: Int, extruderId: Int? = nil) async throws {
        var query = [URLQueryItem(name: "tray_id", value: String(trayId))]
        if let extruderId { query.append(URLQueryItem(name: "extruder_id", value: String(extruderId))) }
        _ = try await request("printers/\(id)/ams/load", method: "POST", query: query)
    }

    /// `printers:control`. Same tray encoding as `amsLoad`.
    func amsUnload(_ id: Int, trayId: Int?) async throws {
        _ = try await request("printers/\(id)/ams/unload", method: "POST",
                              query: trayId.map { [URLQueryItem(name: "tray_id", value: String($0))] } ?? [])
    }

    /// `printers:ams_rfid`. Re-reads the RFID tag in one slot.
    func refreshAmsSlot(_ id: Int, amsId: Int, slotId: Int) async throws {
        _ = try await request("printers/\(id)/ams/\(amsId)/slot/\(slotId)/refresh", method: "POST")
    }

    /// `printers:control`. temp 45-85 C, duration 1-24 h (server-validated).
    func startDrying(_ id: Int, amsId: Int, temp: Int, hours: Int, filament: String, rotateTray: Bool = false) async throws {
        _ = try await request("printers/\(id)/drying/start", method: "POST", query: [
            URLQueryItem(name: "ams_id", value: String(amsId)),
            URLQueryItem(name: "temp", value: String(temp)),
            URLQueryItem(name: "duration", value: String(hours)),
            URLQueryItem(name: "filament", value: filament),
            URLQueryItem(name: "rotate_tray", value: rotateTray ? "true" : "false"),
        ])
    }

    /// `printers:control`.
    func stopDrying(_ id: Int, amsId: Int) async throws {
        _ = try await request("printers/\(id)/drying/stop", method: "POST",
                              query: [URLQueryItem(name: "ams_id", value: String(amsId))])
    }

    // MARK: Fans, airduct, print options

    /// `printers:control`. fan: part | aux | aux2 | chamber; speed 0-100.
    func setFanSpeed(_ id: Int, fan: String, speed: Int) async throws {
        _ = try await request("printers/\(id)/fan-speed", method: "POST", query: [
            URLQueryItem(name: "fan", value: fan),
            URLQueryItem(name: "speed", value: String(speed)),
        ])
    }

    /// `printers:control`. mode: cooling | heating.
    func setAirductMode(_ id: Int, mode: String) async throws {
        _ = try await request("printers/\(id)/airduct-mode", method: "POST", query: [URLQueryItem(name: "mode", value: mode)])
    }

    /// `printers:control`. All values go in the query string (no JSON body).
    func setPrintOption(_ id: Int, module: String, enabled: Bool, sensitivity: String = "medium") async throws {
        _ = try await request("printers/\(id)/print-options", method: "POST", query: [
            URLQueryItem(name: "module_name", value: module),
            URLQueryItem(name: "enabled", value: enabled ? "true" : "false"),
            URLQueryItem(name: "sensitivity", value: sensitivity),
        ])
    }

    // MARK: Firmware

    struct OpsFirmwareInfo: Decodable {
        let printerId: Int
        let currentVersion: String?
        let latestVersion: String?
        let updateAvailable: Bool
    }

    /// `firmware:read`.
    func firmwareUpdate(printerId: Int) async throws -> OpsFirmwareInfo? {
        let list: [OpsFirmwareInfo] = try await get("bulk/firmware-updates", query: [URLQueryItem(name: "ids", value: String(printerId))])
        return list.first { $0.printerId == printerId }
    }

    // MARK: Smart plug

    struct OpsPlugInfo: Decodable, Identifiable {
        let id: Int
        let name: String
        let plugType: String?
        let lastState: String?
        let enabled: Bool?
        let controlsPrinterPower: Bool?

        /// MQTT plugs are monitor-only (control returns 400).
        var canSwitch: Bool { plugType != "mqtt" }
    }

    struct OpsPlugStatus: Decodable {
        let state: String?
        let reachable: Bool?
        let deviceName: String?
        let energy: Energy?

        struct Energy: Decodable { let power: Double? }
    }

    private struct OpsCardPlugs: Decodable { let plug: OpsPlugInfo? }

    /// `smart_plugs:read`. The printer's main power plug, if one is assigned.
    func cardPlug(printerId: Int) async throws -> OpsPlugInfo? {
        let map: [String: OpsCardPlugs] = try await get("bulk/card-plugs", query: [URLQueryItem(name: "ids", value: String(printerId))])
        return map[String(printerId)]?.plug
    }

    /// `smart_plugs:read`.
    func plugStatus(_ plugId: Int) async throws -> OpsPlugStatus { try await get("smart-plugs/\(plugId)/status") }

    /// `smart_plugs:control`. action: on | off | toggle.
    func controlPlug(_ plugId: Int, action: String) async throws {
        struct Body: Encodable { let action: String }
        _ = try await request("smart-plugs/\(plugId)/control", method: "POST", body: Body(action: action))
    }
}
