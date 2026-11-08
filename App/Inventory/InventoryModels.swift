import Foundation
import SwiftUI
import UIKit

// Models for the inventory screens. Shapes match the Bambuddy 1.3.0 spool, Spoolman
// and inventory responses.

extension Spool {
    var isArchived: Bool { archivedAt != nil }
    var displayName: String { title.isEmpty ? "Spool #\(id)" : title }
    var labelGrams: Double { (labelWeight ?? 1000) > 0 ? (labelWeight ?? 1000) : 1000 }
    var remainingPercent: Double { max(0, min(100, remainingGrams / labelGrams * 100)) }

    /// Bambuddy's rule: remaining % below the spool's own threshold, else the global one.
    func isLow(globalThreshold: Double) -> Bool {
        !isArchived && remainingPercent < (lowStockThresholdPct ?? globalThreshold)
    }

    /// Base color first, then any extra gradient stops (comma-separated hex).
    var swatchColors: [Color] {
        var colors: [Color] = []
        if let base = Color(hexRGBA: rgba) { colors.append(base) }
        for token in (extraColors ?? "").split(separator: ",") {
            if let c = Color(hexRGBA: String(token).trimmingCharacters(in: CharacterSet(charactersIn: "# "))) { colors.append(c) }
        }
        return colors
    }
}

/// One AMS slot with a spool assigned. Built-in inventory answers `spool_id`
/// (and the spool nested); Spoolman mode answers `spoolman_spool_id`.
struct SlotAssignment: Decodable, Identifiable, Hashable {
    let spoolId: Int
    let printerId: Int
    let printerName: String?
    let amsId: Int
    let trayId: Int
    let amsLabel: String?
    let spool: Spool?

    var id: String { "\(printerId)-\(amsId)-\(trayId)" }

    private enum CodingKeys: String, CodingKey { case spoolId, spoolmanSpoolId, printerId, printerName, amsId, trayId, amsLabel, spool }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(Int.self, forKey: .spoolId) {
            spoolId = id
        } else {
            spoolId = try c.decode(Int.self, forKey: .spoolmanSpoolId)
        }
        printerId = try c.decode(Int.self, forKey: .printerId)
        printerName = try c.decodeIfPresent(String.self, forKey: .printerName)
        amsId = try c.decode(Int.self, forKey: .amsId)
        trayId = try c.decode(Int.self, forKey: .trayId)
        amsLabel = try c.decodeIfPresent(String.self, forKey: .amsLabel)
        spool = try? c.decodeIfPresent(Spool.self, forKey: .spool)
    }

    static func == (a: SlotAssignment, b: SlotAssignment) -> Bool { a.id == b.id && a.spoolId == b.spoolId }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(spoolId)
    }

    /// "AMS A slot 2", "AMS HT 1", "External". A saved AMS label wins over the letter.
    var slotName: String { SlotNaming.name(amsId: amsId, trayId: trayId, label: amsLabel) }
    var fullName: String { [printerName, slotName].compactMap { $0 }.joined(separator: " · ") }
}

enum SlotNaming {
    static func unit(_ amsId: Int) -> String {
        if amsId == 255 { return "External" }
        if amsId >= 128 { return "AMS HT \(amsId - 127)" }
        if amsId == 32 { return "AMS-3H" }
        if amsId == 33 { return "AMS-B" }
        if amsId >= 0, amsId < 26, let scalar = UnicodeScalar(65 + amsId) { return "AMS \(Character(scalar))" }
        return "AMS #\(amsId)"
    }

    static func name(amsId: Int, trayId: Int, label: String? = nil) -> String {
        if amsId == 255 { return trayId == 0 ? "External" : "External \(trayId + 1)" }
        let unitName = (label?.isEmpty == false ? label! : unit(amsId))
        return amsId >= 128 ? unitName : "\(unitName) slot \(trayId + 1)"
    }
}

/// Result of an assign call. Built-in inventory reports whether the printer was told;
/// Spoolman mode answers a bare spool, so both stay nil.
struct AssignResult: Decodable {
    let configured: Bool?
    let pendingConfig: Bool?
}

struct InventorySettings: Decodable {
    let spoolmanEnabled: Bool?
    let spoolmanUrl: String?
    let lowStockThreshold: Double?
}

struct SpoolmanStatus: Decodable {
    let enabled: Bool?
    let connected: Bool?
    let url: String?
}

/// GET /inventory/colors/search entry. `hexColor` is "#RRGGBB" (or with alpha).
struct ColorEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let manufacturer: String
    let colorName: String
    let hexColor: String
    let material: String?
    let isDefault: Bool?
    let extraColors: String?
    let effectType: String?

    /// RRGGBBAA, uppercase.
    var rgba: String {
        let hex = hexColor.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        return hex.count == 6 ? hex + "FF" : hex
    }
}

// MARK: - Sparse JSON bodies

enum PatchValue: Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

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

/// Body with exactly the keys that were set (Bambuddy's PATCH uses exclude_unset; an explicit null clears).
struct InventoryPatch: Encodable {
    var fields: [String: PatchValue] = [:]

    subscript(key: String) -> PatchValue? {
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

// MARK: - Form draft

/// Editable copy of a spool. Numbers stay text so a field can be empty while typing.
struct SpoolDraft {
    var material = ""
    var subtype = ""
    var brand = ""
    var colorName = ""
    var rgba = "808080FF"
    var hasColor = false
    var extraColors = ""
    var effectType = ""
    var labelWeight = "1000"
    var coreWeight = "250"
    var weightUsed = "0"
    var nozzleMin = ""
    var nozzleMax = ""
    var costPerKg = ""
    var category = ""
    var storageLocation = ""
    var lowStockPct = ""
    var note = ""

    init() {}

    init(_ s: Spool) {
        material = s.material ?? ""
        subtype = s.subtype ?? ""
        brand = s.brand ?? ""
        colorName = s.colorName ?? ""
        if let r = s.rgba, r.count >= 6 {
            rgba = (r.count == 6 ? r + "FF" : r).uppercased()
            hasColor = true
        }
        extraColors = s.extraColors ?? ""
        effectType = s.effectType ?? ""
        labelWeight = Self.text(s.labelWeight ?? 1000)
        coreWeight = Self.text(s.coreWeight ?? 250)
        weightUsed = Self.text(s.weightUsed ?? 0)
        nozzleMin = s.nozzleTempMin.map(String.init) ?? ""
        nozzleMax = s.nozzleTempMax.map(String.init) ?? ""
        costPerKg = s.costPerKg.map(Self.text) ?? ""
        category = s.category ?? ""
        storageLocation = s.storageLocation ?? ""
        lowStockPct = s.lowStockThresholdPct.map(Self.text) ?? ""
        note = s.note ?? ""
    }

    static func text(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// First problem with the draft, or nil when it can be sent.
    func problem(spoolman: Bool) -> String? {
        if trimmed(material).isEmpty { return "Material is required." }
        guard let label = Self.number(labelWeight), label >= 1, label <= 100_000 else { return "Spool weight must be between 1 and 100000 g." }
        guard let used = Self.number(weightUsed), used >= 0 else { return "Used weight can't be negative." }
        if spoolman, used > label { return "Spoolman doesn't accept more used than the spool holds." }
        guard let core = Self.number(coreWeight), core >= 0, core <= 10_000 else { return "Empty spool weight must be between 0 and 10000 g." }
        if !trimmed(costPerKg).isEmpty, (Self.number(costPerKg) ?? -1) < 0 { return "Cost per kg must be a positive number." }
        if !spoolman {
            if !trimmed(lowStockPct).isEmpty {
                guard let p = Self.number(lowStockPct), p >= 1, p <= 99, p == p.rounded() else { return "Low-stock alert must be a whole number from 1 to 99." }
            }
            for t in [nozzleMin, nozzleMax] where !trimmed(t).isEmpty && Int(trimmed(t)) == nil { return "Nozzle temperatures are whole degrees." }
            if trimmed(category).count > 50 { return "Category can be at most 50 characters." }
        }
        return nil
    }

    private func setText(_ patch: inout InventoryPatch, _ key: String, _ new: String, old: String?, clear: PatchValue? = .null) {
        let value = trimmed(new)
        guard value != (old ?? "") else { return }
        if value.isEmpty {
            if let clear { patch[key] = clear }
        } else {
            patch[key] = .string(value)
        }
    }

    /// POST body: only filled-in fields. Spoolman's create schema is narrower than the built-in one.
    func createBody(spoolman: Bool) -> InventoryPatch {
        var p = InventoryPatch()
        p["material"] = .string(trimmed(material))
        let texts: [(String, String)] = [("subtype", subtype), ("brand", brand), ("color_name", colorName), ("note", note), ("storage_location", storageLocation)]
        for (key, value) in texts where !trimmed(value).isEmpty { p[key] = .string(trimmed(value)) }
        if hasColor { p["rgba"] = .string(rgba) }
        p["label_weight"] = .int(Int(Self.number(labelWeight) ?? 1000))
        p["core_weight"] = .int(Int(Self.number(coreWeight) ?? 250))
        p["weight_used"] = .double(Self.number(weightUsed) ?? 0)
        if let cost = Self.number(costPerKg) { p["cost_per_kg"] = .double(cost) }
        if !spoolman {
            if !trimmed(extraColors).isEmpty { p["extra_colors"] = .string(trimmed(extraColors)) }
            if !trimmed(effectType).isEmpty { p["effect_type"] = .string(trimmed(effectType)) }
            if let v = Int(trimmed(nozzleMin)) { p["nozzle_temp_min"] = .int(v) }
            if let v = Int(trimmed(nozzleMax)) { p["nozzle_temp_max"] = .int(v) }
            if !trimmed(category).isEmpty { p["category"] = .string(trimmed(category)) }
            if let v = Int(trimmed(lowStockPct)) { p["low_stock_threshold_pct"] = .int(v) }
        }
        return p
    }

    /// PATCH body: only what differs from `old`. Clearing a field sends null in built-in mode.
    /// Spoolman's update treats null as "leave alone" for most fields, so only the ones its
    /// route documents as clearable (color name and storage location via null, note via "") are cleared there.
    func patch(from old: Spool, spoolman: Bool) -> InventoryPatch {
        var p = InventoryPatch()
        let was = SpoolDraft(old)
        if !trimmed(material).isEmpty { setText(&p, "material", material, old: was.material, clear: nil) }
        setText(&p, "subtype", subtype, old: was.subtype, clear: spoolman ? nil : .null)
        setText(&p, "brand", brand, old: was.brand, clear: spoolman ? nil : .null)
        setText(&p, "color_name", colorName, old: was.colorName)
        setText(&p, "storage_location", storageLocation, old: was.storageLocation)
        setText(&p, "note", note, old: was.note, clear: spoolman ? .string("") : .null)
        if hasColor, rgba != was.rgba || !was.hasColor { p["rgba"] = .string(rgba) }
        if let v = Self.number(labelWeight), v != Self.number(was.labelWeight) { p["label_weight"] = .int(Int(v)) }
        if let v = Self.number(coreWeight), v != Self.number(was.coreWeight) { p["core_weight"] = .int(Int(v)) }
        if let v = Self.number(weightUsed), abs(v - (old.weightUsed ?? 0)) > 0.04 { p["weight_used"] = .double(v) }
        if let v = Self.number(costPerKg) {
            if v != old.costPerKg { p["cost_per_kg"] = .double(v) }
        } else if trimmed(costPerKg).isEmpty, old.costPerKg != nil, !spoolman {
            p["cost_per_kg"] = .null
        }
        if !spoolman {
            setText(&p, "extra_colors", extraColors, old: was.extraColors)
            setText(&p, "effect_type", effectType, old: was.effectType)
            setText(&p, "category", category, old: was.category)
            if trimmed(nozzleMin) != was.nozzleMin { p["nozzle_temp_min"] = Int(trimmed(nozzleMin)).map(PatchValue.int) ?? .null }
            if trimmed(nozzleMax) != was.nozzleMax { p["nozzle_temp_max"] = Int(trimmed(nozzleMax)).map(PatchValue.int) ?? .null }
            if trimmed(lowStockPct) != was.lowStockPct { p["low_stock_threshold_pct"] = Int(trimmed(lowStockPct)).map(PatchValue.int) ?? .null }
        }
        return p
    }
}

enum ColorHex {
    /// "RRGGBB" from a SwiftUI color (sRGB), or nil if it can't be resolved.
    static func rgb(_ color: Color) -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Accepts "#RRGGBB", "RRGGBB", or 8 digits; returns RRGGBBAA uppercase.
    static func normalized(_ text: String) -> String? {
        let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "# \n")).uppercased()
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.count == 6 ? hex + "FF" : hex
    }
}
