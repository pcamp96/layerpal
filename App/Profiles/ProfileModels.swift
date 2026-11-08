import Foundation
import SwiftUI

// K-profile, preset and slot-configure types. Shapes match the Bambuddy 1.3.0 K-profile,
// local-preset and slicer-preset responses.

/// A pressure-advance profile stored on the printer. GET /printers/{id}/kprofiles/
struct KProfile: Decodable, Identifiable, Hashable {
    let slotId: Int
    let extruderId: Int
    let nozzleId: String
    let nozzleDiameter: String
    let filamentId: String
    let name: String
    let kValue: String
    let nCoef: String
    let amsId: Int
    let trayId: Int
    let settingId: String?

    var id: String { "\(slotId)_\(extruderId)_\(filamentId)_\(settingId ?? "")" }

    private enum CodingKeys: String, CodingKey {
        case slotId, extruderId, nozzleId, nozzleDiameter, filamentId, name, kValue, nCoef, amsId, trayId, settingId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slotId = try c.decode(Int.self, forKey: .slotId)
        extruderId = try c.decodeIfPresent(Int.self, forKey: .extruderId) ?? 0
        nozzleId = try c.decodeIfPresent(String.self, forKey: .nozzleId) ?? ""
        nozzleDiameter = try c.decodeIfPresent(String.self, forKey: .nozzleDiameter) ?? ""
        filamentId = try c.decodeIfPresent(String.self, forKey: .filamentId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kValue = try c.decodeIfPresent(String.self, forKey: .kValue) ?? "0"
        nCoef = try c.decodeIfPresent(String.self, forKey: .nCoef) ?? "0"
        amsId = try c.decodeIfPresent(Int.self, forKey: .amsId) ?? 0
        trayId = try c.decodeIfPresent(Int.self, forKey: .trayId) ?? -1
        settingId = try c.decodeIfPresent(String.self, forKey: .settingId)
    }

    /// "HH00" = High Flow, anything else (or nothing) = Standard, as in the slicer.
    var isHighFlow: Bool { nozzleId.hasPrefix("HH") }
    var kNumber: Double? { Double(kValue) }
}

struct KProfilesResponse: Decodable {
    let profiles: [KProfile]
    let nozzleDiameter: String?
}

/// POST /printers/{id}/kprofiles/ (KProfileCreate). `slotId` 0 = new, > 0 = edit that slot.
struct KProfileBody: Encodable {
    var slotId = 0
    var extruderId = 0
    var nozzleId: String
    var nozzleDiameter: String
    var filamentId: String
    var name: String
    var kValue: String
    var nCoef = "0.000000"
    var amsId = 0
    var trayId = -1
    var settingId: String?
}

/// DELETE /printers/{id}/kprofiles/ (KProfileDelete). `slotId` is the profile's calibration index.
struct KProfileDeleteBody: Encodable {
    let slotId: Int
    let extruderId: Int
    let nozzleId: String
    let nozzleDiameter: String
    let filamentId: String
    let settingId: String?

    init(_ p: KProfile) {
        slotId = p.slotId
        extruderId = p.extruderId
        nozzleId = p.nozzleId
        nozzleDiameter = p.nozzleDiameter
        filamentId = p.filamentId
        settingId = p.settingId
    }
}

/// `{success, confirmed, message}` from the K-profile write routes.
struct KProfileAck: Decodable {
    let success: Bool?
    let confirmed: Bool?
    let message: String?
}

/// GET /cloud/builtin-filaments (filaments:read): Bambuddy's static filament-id table.
struct BuiltinFilament: Decodable, Identifiable, Hashable {
    let filamentId: String
    let name: String
    var id: String { filamentId }
}

/// GET /local-presets/ (settings:read), grouped by type.
struct LocalPresetsResponse: Decodable {
    let filament: [LocalPreset]
    let printer: [LocalPreset]
    let process: [LocalPreset]

    static let empty = LocalPresetsResponse(filament: [], printer: [], process: [])

    init(filament: [LocalPreset], printer: [LocalPreset], process: [LocalPreset]) {
        self.filament = filament
        self.printer = printer
        self.process = process
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filament = try c.decodeIfPresent([LocalPreset].self, forKey: .filament) ?? []
        printer = try c.decodeIfPresent([LocalPreset].self, forKey: .printer) ?? []
        process = try c.decodeIfPresent([LocalPreset].self, forKey: .process) ?? []
    }

    private enum CodingKeys: String, CodingKey { case filament, printer, process }
}

struct LocalPreset: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let presetType: String
    let source: String?
    let filamentType: String?
    let filamentVendor: String?
    let nozzleTempMin: Int?
    let nozzleTempMax: Int?
    let pressureAdvance: String?
    let defaultFilamentColour: String?
    let filamentCost: String?
    let filamentDensity: String?
    let compatiblePrinters: String?
    let inherits: String?
    let version: String?
    let createdAt: Date?
    let updatedAt: Date?

    var subtitle: String {
        [filamentVendor, filamentType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// GET /slicer/presets (library:upload scope): every tier, each split into printer / process / filament.
struct SlicerPresetsResponse: Decodable {
    struct Preset: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let source: String
        let filamentType: String?
        let filamentColour: String?
        let compatiblePrinters: [String]?
        let inherits: String?
    }

    struct Slots: Decodable {
        let printer: [Preset]
        let process: [Preset]
        let filament: [Preset]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            printer = try c.decodeIfPresent([Preset].self, forKey: .printer) ?? []
            process = try c.decodeIfPresent([Preset].self, forKey: .process) ?? []
            filament = try c.decodeIfPresent([Preset].self, forKey: .filament) ?? []
        }

        private enum CodingKeys: String, CodingKey { case printer, process, filament }

        var isEmpty: Bool { printer.isEmpty && process.isEmpty && filament.isEmpty }
    }

    let orcaCloud: Slots
    let cloud: Slots
    let local: Slots
    let standard: Slots
    let cloudStatus: String?
    let orcaCloudStatus: String?
}

/// Result of POST /printers/{id}/slots/{ams}/{tray}/configure.
struct ConfigureSlotResult: Decodable {
    let success: Bool?
    let message: String?
    let trayInfoIdx: String?
    let kValueUnsent: Bool?
    /// Set when an Orca profile had no usable filament id: no_filament_id | lookup_failed | no_permission.
    let orcaFallbackReason: String?
}

// MARK: Preset name parsing

/// Reads what LayerPal needs from a filament preset's name when the preset carries no fields of its own:
/// the material (sent as `tray_type`), a default nozzle range, and Bambu's generic filament id.
enum PresetNaming {
    /// Base materials the printer knows as `tray_type`.
    static let materials: [String] = [
        "PLA", "PETG", "PCTG", "PET", "ABS", "ASA", "TPU", "PC", "PA", "NYLON", "PVA", "HIPS", "PP", "PE",
    ]

    /// Display name without the "@Printer nozzle" suffix.
    static func cleanName(_ name: String) -> String {
        let head = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The material a preset is for.
    static func material(of name: String) -> String {
        let clean = cleanName(name)
        // Support filaments print as the material they support ("Support for PLA/PETG" -> PLA).
        if let range = clean.range(of: "support for", options: .caseInsensitive),
           let found = firstMaterial(in: String(clean[range.upperBound...])) {
            return found
        }
        if let found = firstMaterial(in: clean) { return found }
        let words = clean.split(whereSeparator: \.isWhitespace)
        return words.count > 1 ? String(words[1]) : clean
    }

    /// The first word of `text` that is a known material. Hyphens and slashes split words, so
    /// "PLA-CF" holds PLA, while "ePA" holds nothing.
    private static func firstMaterial(in text: String) -> String? {
        let known = Set(materials)
        let words = text.uppercased().split { $0.isWhitespace || $0 == "-" || $0 == "/" }
        return words.lazy.map(String.init).first { known.contains($0) }
    }

    /// Default nozzle temperature range for a material when the preset gives none. Values follow
    /// BambuStudio's generic filament profiles for each family.
    static func nozzleRange(_ material: String) -> (min: Int, max: Int) {
        let key = material.uppercased().trimmingCharacters(in: .whitespaces)
        let family = key.split { $0 == "-" || $0 == " " || $0 == "+" }.first.map(String.init) ?? key
        switch family {
        case "PCTG": return (240, 270)
        case "PETG", "PET": return (220, 270)
        case "ABS", "ASA": return (240, 280)
        case "PC": return (260, 290)
        case "PA", "PA6", "PA11", "PA12", "PAHT", "NYLON": return (240, 280)
        case "TPU": return (200, 250)
        case "HIPS": return (220, 270)
        case "PP": return (220, 250)
        case "PE": return (175, 220)
        case "PVA": return (190, 240)
        default: return (190, 240) // PLA and anything unknown
        }
    }

    /// Bambu generic filament ids used as tray_info_idx for presets that carry no id of their own
    /// (`filament_id` of BambuStudio's "Generic ..." profiles).
    static let genericIds: [String: String] = [
        "PLA": "GFL99", "PLA-CF": "GFL98", "PLA SILK": "GFL96", "PLA HIGH SPEED": "GFL95",
        "PETG": "GFG99", "PETG HF": "GFG96", "PETG-CF": "GFG98", "PCTG": "GFG97",
        "ABS": "GFB99", "ASA": "GFB98", "PC": "GFC99",
        "PA": "GFN99", "NYLON": "GFN99", "PA-CF": "GFN98",
        "TPU": "GFU99", "PVA": "GFS99", "HIPS": "GFS98", "PE": "GFP99", "PP": "GFP97",
    ]

    static func genericId(for material: String) -> String {
        let key = material.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "" }
        if let id = genericIds[key] { return id }
        if key.hasSuffix("-CF") || key.hasSuffix(" CF") {
            let base = String(key.dropLast(3))
            if let id = genericIds[base] { return id }
        }
        if key.hasSuffix("+") {
            let base = String(key.dropLast())
            if let id = genericIds[base] { return id }
        }
        if let cut = key.firstIndex(where: { $0 == "-" || $0 == " " }) {
            let base = String(key[..<cut])
            if let id = genericIds[base] { return id }
        }
        return ""
    }
}

// MARK: Color helpers

extension Color {
    /// "RRGGBB" for a SwiftUI Color (sRGB).
    var hexRGB: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
