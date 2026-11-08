import Foundation

// Models for the printer "Advanced" screens. Shapes match the nozzle-info, nozzle-rack-slot,
// file-browser and storage responses of the Bambuddy 1.3.0 /printers/{id} routes.

/// Installed nozzle hardware. Material names ("stainless_steel") on X1/P1, flow codes ("HH01", "HS01") on H2.
/// The order of `nozzles[]` carries no meaning, so it is never read by index.
struct AdvNozzleInfo: Codable, Hashable {
    let nozzleType: String?
    let nozzleDiameter: String?
}

/// Nozzle slot. id 0 = right hotend, 1 = left hotend, 16+ = rack positions (H2C).
struct AdvRackSlot: Codable, Hashable, Identifiable {
    let id: Int
    let nozzleType: String?
    let nozzleDiameter: String?
    let wear: Int?
    /// 1 = mounted, otherwise docked.
    let stat: Int?
    let maxTemp: Int?
    let serialNumber: String?
    let filamentColor: String?
    let filamentId: String?
    let filamentType: String?

    var isEmpty: Bool { (nozzleDiameter ?? "").isEmpty && (nozzleType ?? "").isEmpty }
    var isMounted: Bool { stat == 1 }
}

/// Readable text for a printer's `nozzle_type`. X1/P1 printers send a material word ("hardened_steel");
/// H2-family printers send a 4-character code: two letters of flow type, then two digits of material.
enum AdvNozzleText {
    private static let materialCodes = ["00": "Stainless steel", "01": "Hardened steel", "05": "Tungsten carbide"]

    static func material(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        let lower = type.lowercased()
        if lower.contains("hardened") { return "Hardened steel" }
        if lower.contains("stainless") { return "Stainless steel" }
        if lower.contains("tungsten") { return "Tungsten carbide" }
        if type.count == 4, let name = materialCodes[String(type.suffix(2))] { return name }
        if type.count == 2, let name = materialCodes[type] { return name }
        return type
    }

    static func flow(_ type: String?) -> String? {
        let upper = (type ?? "").uppercased()
        if upper.hasPrefix("HH") { return "High flow" }
        if upper.hasPrefix("HS") { return "Standard flow" }
        return nil
    }
}

struct AdvFileEntry: Decodable, Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int?
    let path: String
    let mtime: String?
    var id: String { path }

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isVideo: Bool { ["mp4", "avi", "mov", "m4v"].contains(ext) }
    /// AVKit plays these; Bambu's older timelapses (.avi) it can't.
    var isPlayable: Bool { ["mp4", "mov", "m4v"].contains(ext) }
}

struct AdvFileListing: Decodable {
    let path: String
    let files: [AdvFileEntry]
    /// "printer_unavailable" or "listing_timed_out" when the printer didn't answer in time.
    let warnings: [String]?
}

struct AdvStorage: Decodable {
    let usedBytes: Int?
    let freeBytes: Int?
}

/// Calibration routines `POST /printers/{id}/calibration` accepts (bitmask built server-side from OrcaSlicer's).
enum AdvCalibration: String, CaseIterable, Identifiable {
    case bedLeveling = "bed_leveling"
    case vibration
    case motorNoise = "motor_noise"
    case nozzleOffset = "nozzle_offset"
    case highTempHeatbed = "high_temp_heatbed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bedLeveling: "Auto bed leveling"
        case .vibration: "Vibration compensation"
        case .motorNoise: "Motor noise cancellation"
        case .nozzleOffset: "Nozzle offset"
        case .highTempHeatbed: "High-temperature heatbed"
        }
    }

    var detail: String {
        switch self {
        case .bedLeveling: "Probes the bed to map its surface. Takes a few minutes."
        case .vibration: "Shakes the toolhead to tune input shaping. Loud, and the printer moves fast."
        case .motorNoise: "Tunes the motors to run quieter. The printer moves while it listens."
        case .nozzleOffset: "Aligns the two nozzles so they print at the same height and position (dual-nozzle printers)."
        case .highTempHeatbed: "Calibrates the bed while it is hot. Needs a heated, enclosed printer, and the bed gets very hot."
        }
    }

    var symbol: String {
        switch self {
        case .bedLeveling: "squareshape.split.3x3"
        case .vibration: "waveform"
        case .motorNoise: "speaker.wave.2"
        case .nozzleOffset: "arrow.left.and.right.square"
        case .highTempHeatbed: "flame"
        }
    }
}

/// Printer model facts for the Advanced screens. Accepts display names or internal codes.
enum AdvModels {
    /// Bed slingers (A1 family, A2L): names, short names and internal codes.
    private static let toolheadZ: Set<String> = ["A1", "A1MINI", "A1M", "A2L", "N1", "N2S", "N9", "A04", "A11", "A12"]
    private static let rack: Set<String> = ["H2C", "O1C", "O1C2"]
    private static let toolChanger: Set<String> = ["H3C", "N10"]

    /// Uppercased, letters and digits only, so "A1 mini" and "A1MINI" agree.
    static func key(_ model: String?) -> String {
        String((model ?? "").uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Models whose Z axis lifts the toolhead rather than the plate.
    static func zMovesToolhead(_ model: String?) -> Bool { toolheadZ.contains(key(model)) }
    /// Nozzle-rack models (H2C).
    static func isRack(_ model: String?) -> Bool { rack.contains(key(model)) }
    /// Tool changer whose nozzle layout LayerPal treats as unverified.
    static func isToolChangerUnverified(_ model: String?) -> Bool { toolChanger.contains(key(model)) }
}

func advFormatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
