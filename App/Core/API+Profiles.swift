import Foundation

/// K-profiles, presets and AMS slot configuration (Bambuddy 1.3.0).
///
/// Admin-only routes (the server refuses them for API keys) take a
/// `bearer` from `AdminSession.perform`; a nil bearer falls back to the app's API key.
extension APIClient {
    // MARK: K-profiles

    /// GET /printers/{id}/kprofiles/?nozzle_diameter= (kprofiles:read, API key allowed).
    /// Asks the printer over MQTT, so it answers 400 when offline and 504 when it doesn't reply.
    func kProfiles(printerId: Int, nozzleDiameter: String) async throws -> [KProfile] {
        let response: KProfilesResponse = try await get("printers/\(printerId)/kprofiles/",
                                                        query: [URLQueryItem(name: "nozzle_diameter", value: nozzleDiameter)])
        return response.profiles
    }

    /// POST /printers/{id}/kprofiles/ (kprofiles:update, admin only). slot_id 0 adds, > 0 edits that slot.
    func saveKProfile(printerId: Int, _ body: KProfileBody, bearer: String?) async throws -> KProfileAck {
        let data = try await request("printers/\(printerId)/kprofiles/", method: "POST", body: body, bearer: bearer)
        return (try? decoder().decode(KProfileAck.self, from: data)) ?? KProfileAck(success: true, confirmed: nil, message: nil)
    }

    /// POST /printers/{id}/kprofiles/batch (kprofiles:update, admin only): one command for both nozzles of a dual-nozzle printer.
    func saveKProfilesBatch(printerId: Int, _ bodies: [KProfileBody], bearer: String?) async throws -> KProfileAck {
        let data = try await request("printers/\(printerId)/kprofiles/batch", method: "POST", body: bodies, bearer: bearer)
        return (try? decoder().decode(KProfileAck.self, from: data)) ?? KProfileAck(success: true, confirmed: nil, message: nil)
    }

    /// DELETE /printers/{id}/kprofiles/ (kprofiles:delete, admin only).
    func deleteKProfile(printerId: Int, _ profile: KProfile, bearer: String?) async throws {
        _ = try await request("printers/\(printerId)/kprofiles/", method: "DELETE", body: KProfileDeleteBody(profile), bearer: bearer)
    }

    // MARK: Presets

    /// GET /cloud/builtin-filaments (filaments:read).
    func builtinFilaments() async throws -> [BuiltinFilament] { try await get("cloud/builtin-filaments") }

    /// GET /local-presets/ (settings:read).
    func localPresets() async throws -> LocalPresetsResponse { try await get("local-presets/") }

    /// GET /local-presets/{id} (settings:read): the preset's full setting JSON as ordered "key = value" pairs.
    /// Parsed without the snake-case key conversion so the slicer's own keys survive.
    func localPresetSettings(_ id: Int) async throws -> [(key: String, value: String)] {
        let data = try await request("local-presets/\(id)")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setting = root["setting"] as? [String: Any] else { return [] }
        return setting.keys.sorted().map { key in (key, Self.describe(setting[key])) }
    }

    /// DELETE /local-presets/{id} (settings:update, admin only).
    func deleteLocalPreset(_ id: Int, bearer: String?) async throws {
        _ = try await request("local-presets/\(id)", method: "DELETE", bearer: bearer)
    }

    /// GET /slicer/presets (library:upload scope). Cloud tiers are empty unless the key has cloud access.
    func slicerPresets() async throws -> SlicerPresetsResponse { try await get("slicer/presets") }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let a as [Any]: return a.map { describe($0) }.joined(separator: ", ")
        case let d as [String: Any]:
            return d.keys.sorted().map { "\($0): \(describe(d[$0]))" }.joined(separator: ", ")
        default: return String(describing: value)
        }
    }

    // MARK: AMS slots

    /// POST /printers/{id}/slots/{ams}/{tray}/configure (printers:control, API key allowed).
    /// Every value travels in the query string. `+` is percent-encoded by hand because
    /// URLComponents leaves it bare and the server would read it as a space ("PLA+").
    /// External spool: ams 255, tray 0 or 1.
    func configureSlot(printerId: Int, amsId: Int, trayId: Int, _ config: SlotConfiguration) async throws -> ConfigureSlotResult {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var components = URLComponents(url: base.appending(path: "api/v1/printers/\(printerId)/slots/\(amsId)/\(trayId)/configure"),
                                       resolvingAgainstBaseURL: false)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components?.percentEncodedQuery = config.queryItems.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        guard let url = components?.url else { throw APIError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        ServerConfig.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return (try? decoder().decode(ConfigureSlotResult.self, from: data)) ?? ConfigureSlotResult(success: true, message: nil, trayInfoIdx: nil, kValueUnsent: nil, orcaFallbackReason: nil)
    }

    /// POST /printers/{id}/ams/{ams}/tray/{tray}/reset (printers:control). 409 while the printer is printing.
    func resetSlot(printerId: Int, amsId: Int, trayId: Int) async throws {
        _ = try await request("printers/\(printerId)/ams/\(amsId)/tray/\(trayId)/reset", method: "POST")
    }
}

/// Query parameters of the configure route (all required except the K-profile and setting ids).
struct SlotConfiguration {
    var trayInfoIdx: String
    var trayType: String
    var traySubBrands: String
    /// "RRGGBBAA"
    var trayColor: String
    var nozzleTempMin: Int
    var nozzleTempMax: Int
    /// K-profile calibration index (`KProfile.slotId`), -1 = default.
    var caliIdx = -1
    var nozzleDiameter = "0.4"
    var settingId = ""
    var kprofileFilamentId = ""
    var kprofileSettingId = ""
    var kValue = 0.0
    /// Orca Cloud profile the slot is being set to; the backend looks up its own filament id when `trayInfoIdx` is blank.
    var orcaProfileId = ""

    var queryItems: [(String, String)] {
        [
            ("tray_info_idx", trayInfoIdx), ("tray_type", trayType), ("tray_sub_brands", traySubBrands),
            ("tray_color", trayColor), ("nozzle_temp_min", String(nozzleTempMin)), ("nozzle_temp_max", String(nozzleTempMax)),
            ("cali_idx", String(caliIdx)), ("nozzle_diameter", nozzleDiameter), ("setting_id", settingId),
            ("kprofile_filament_id", kprofileFilamentId), ("kprofile_setting_id", kprofileSettingId),
            ("k_value", String(format: "%.6f", kValue)),
        ] + (orcaProfileId.isEmpty ? [] : [("orca_profile_id", orcaProfileId)])
    }
}
