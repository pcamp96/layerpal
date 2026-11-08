import Foundation
import SwiftUI

// AMS filament mapping for POST /queue/ (`ams_mapping`). The array is indexed by the 3MF's own
// slot id: position = slot_id - 1, value = global tray id (ams_id * 4 + slot, AMS-HT = its unit id
// 128-135, rack AMS 28+slot AMS-3H / 37+slot AMS-B, external 254/255 or 247-255 per nozzle) or -1.
// Auto-matching picks, per slot, a loaded tray of the same material with the closest colour, and
// respects the user's manual picks. Its order follows the server's scheduler where the two must agree.

/// One filament a plate needs. GET /archives/{id}/filament-requirements and
/// GET /library/files/{id}/filament-requirements (archives:read_* / library:read_*).
struct FilamentNeed: Decodable, Identifiable, Hashable {
    let slotId: Int
    let type: String?
    let color: String?
    let usedGrams: Double?
    let trayInfoIdx: String?
    /// Dual-nozzle printers: 0 = right, 1 = left.
    let nozzleId: Int?
    /// Unsliced project files list every project slot; sliced plates only list used ones.
    let usedInPlate: Bool?
    /// Nozzle-rack machines (H2C): the filament group this slot prints in and what that group needs of a hotend.
    let groupId: Int?
    let group: RackGroupInfo?

    var id: Int { slotId }
    var materialName: String { (type?.isEmpty == false ? type! : "Filament") }
}

struct FilamentNeedsResponse: Decodable {
    let filaments: [FilamentNeed]
}

/// A tray that is loaded on the chosen printer (from its live status).
struct LoadedSpoolTray: Identifiable, Hashable {
    let amsId: Int
    let trayId: Int
    let isHT: Bool
    let isExternal: Bool
    let type: String
    /// "RRGGBB", no alpha.
    let color: String
    let globalId: Int
    let trayInfoIdx: String
    let subBrands: String
    let extruderId: Int?
    let remain: Int
    let label: String

    var id: Int { globalId }
    var displayName: String { subBrands.isEmpty ? type : subBrands }
}

/// GET /printers/{id}/status, reduced to what mapping needs. Kept separate from
/// `PrinterStatus` because that one doesn't carry tray_info_idx.
struct MappingPrinterStatus: Decodable {
    struct Tray: Decodable {
        let id: Int
        let trayColor: String?
        let trayType: String?
        let traySubBrands: String?
        let trayInfoIdx: String?
        let remain: Int?
        let nozzleAddr: Int?
    }

    struct Unit: Decodable {
        let id: Int
        let isAmsHt: Bool?
        let tray: [Tray]?
        let amsType: Int?
        let amsTypeName: String?
        let isRack: Bool?
        var rack: Bool { isRack == true || amsType == 6 || amsType == 7 }
    }

    struct Nozzle: Decodable { let nozzleDiameter: String? }
    struct FilaSwitch: Decodable { let installed: Bool? }

    let connected: Bool?
    let ams: [Unit]?
    let vtTray: [Tray]?
    let amsExtruderMap: [String: Int]?
    let nozzles: [Nozzle]?
    let filaSwitch: FilaSwitch?
    /// AMS Filament Backup: true/false, nil when the printer doesn't report it (A1 family).
    let amsFilamentBackup: Bool?
    /// H2C nozzle rack positions (ids 16-21 are the rack, 0 the carriage).
    let nozzleRack: [AdvRackSlot]?
}

/// GET /printers/{id}/inventory-remain (printers:read): grams left on the spools Bambuddy has bound to
/// the printer's slots. `slot_materials` is the server-computed identity the pre-flight filament check pools on.
struct InventoryRemain: Decodable {
    struct Slot: Decodable {
        let globalTrayId: Int
        let materialKey: String
        let remainingG: Double
        let extruder: Int
    }

    let inventoryRemainG: [String: Double]
    let slotMaterials: [Slot]
}

/// The two settings that shape mapping and the spool-weight warning: GET /settings/ui-flags (any signed-in user).
struct MappingFlags: Decodable {
    let preferLowestFilament: Bool?
    let disableFilamentWarnings: Bool?
}

/// A tray that may run out before the job finishes.
struct FilamentDeficit: Identifiable {
    let slotLabel: String
    let requiredGrams: Double
    let remainingGrams: Double
    /// Backup pools several spools of the same material.
    let pooled: Bool
    var id: String { slotLabel }

    var text: String {
        pooled
            ? "\(slotLabel): this job uses \(formatGrams(requiredGrams)), but the backup spools of this material on that nozzle only have \(formatGrams(remainingGrams)) between them."
            : "\(slotLabel): this job uses \(formatGrams(requiredGrams)), but the spool only has \(formatGrams(remainingGrams)) left."
    }
}

enum SlotMatch: Equatable {
    /// Right material, right colour.
    case match
    /// Right material, other colour.
    case colorDiffers
    /// No tray of this material (or a manual pick of another material).
    case mismatch
    /// Explicitly mapped to nothing.
    case unassigned
}

struct SlotComparison: Identifiable {
    let need: FilamentNeed
    let tray: LoadedSpoolTray?
    let match: SlotMatch
    let manual: Bool
    var id: Int { need.slotId }
}

// MARK: - Colour and material helpers

/// Colour comparison for filament matching. Colours are compared as 6 hex digits ("RRGGBB");
/// a printer's alpha byte and a plate's leading "#" are dropped first.
enum MappingColor {
    /// Largest CIEDE2000 difference still treated as "the same filament colour".
    static let defaultThreshold: Double = 12

    static func normalize(_ color: String?) -> String {
        guard var text = color, !text.isEmpty else { return "" }
        if text.hasPrefix("#") { text.removeFirst() }
        return String(text.lowercased().prefix(6))
    }

    /// Close enough that a person would call it the same colour. Small per-channel differences
    /// (16 or less) always count; a channel that is off by 100 or more never does. In between,
    /// the perceptual difference decides.
    static func similar(_ a: String?, _ b: String?, threshold: Double = defaultThreshold) -> Bool {
        guard let x = rgb(a), let y = rgb(b) else { return false }
        let spread = max(abs(x.r - y.r), abs(x.g - y.g), abs(x.b - y.b))
        if spread >= 100 { return false }
        if spread <= 16 { return true }
        return CIEDE2000.difference(lab(x), lab(y)) <= threshold
    }

    static func matches(loaded: String?, required: String?) -> Bool {
        let wanted = normalize(required)
        if wanted.isEmpty { return true }
        if normalize(loaded) == wanted { return true }
        return similar(loaded, required)
    }

    /// CIEDE2000 difference, nil when either colour doesn't parse.
    static func distance(_ a: String?, _ b: String?) -> Double? {
        guard let x = rgb(a), let y = rgb(b) else { return nil }
        return CIEDE2000.difference(lab(x), lab(y))
    }

    /// The similar candidate closest to `required`; the earlier one on a tie.
    static func nearest(_ candidates: [LoadedSpoolTray], to required: String?) -> LoadedSpoolTray? {
        var best: (tray: LoadedSpoolTray, distance: Double)?
        for tray in candidates where similar(tray.color, required) {
            guard let d = distance(tray.color, required) else { continue }
            if best == nil || d < best!.distance { best = (tray, d) }
        }
        return best?.tray
    }

    // MARK: Conversions

    struct RGB { let r: Int; let g: Int; let b: Int }

    static func rgb(_ color: String?) -> RGB? {
        let hex = normalize(color)
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = Int(hex, radix: 16) else { return nil }
        return RGB(r: (value >> 16) & 0xFF, g: (value >> 8) & 0xFF, b: value & 0xFF)
    }

    /// sRGB (D65 white) to CIELAB.
    static func lab(_ c: RGB) -> CIEDE2000.Lab {
        func linear(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double {
            let e = 216.0 / 24389.0, k = 24389.0 / 27.0
            return t > e ? cbrt(t) : (k * t + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return CIEDE2000.Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }
}

/// CIEDE2000 colour difference (Sharma, Wu and Dalal, 2005) with kL = kC = kH = 1.
enum CIEDE2000 {
    struct Lab { let l: Double; let a: Double; let b: Double }

    static func difference(_ p: Lab, _ q: Lab) -> Double {
        let rad = Double.pi / 180
        let k7: Double = 6_103_515_625 // 25^7
        let cMean = (hypot(p.a, p.b) + hypot(q.a, q.b)) / 2
        let g = 0.5 * (1 - sqrt(pow(cMean, 7) / (pow(cMean, 7) + k7)))
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let c1 = hypot(a1, p.b), c2 = hypot(a2, q.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let chromatic = c1 * c2 != 0

        let dL = q.l - p.l
        let dC = c2 - c1
        var dh = 0.0
        if chromatic {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(c1 * c2) * sin(dh / 2 * rad)

        let lMean = (p.l + q.l) / 2
        let cpMean = (c1 + c2) / 2
        var hMean = h1 + h2
        if chromatic {
            if abs(h1 - h2) <= 180 { hMean = (h1 + h2) / 2 }
            else if h1 + h2 < 360 { hMean = (h1 + h2 + 360) / 2 }
            else { hMean = (h1 + h2 - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hMean - 30) * rad) + 0.24 * cos(2 * hMean * rad)
            + 0.32 * cos((3 * hMean + 6) * rad) - 0.20 * cos((4 * hMean - 63) * rad)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cpMean, 7) / (pow(cpMean, 7) + k7))
        let lOff = pow(lMean - 50, 2)
        let sl = 1 + 0.015 * lOff / sqrt(20 + lOff)
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * rad) * rc
        let tl = dL / sl, tc = dC / sc, th = dH / sh
        return sqrt(tl * tl + tc * tc + th * th + rt * tc * th)
    }
}

/// Material comparison for filament matching.
enum MappingMaterial {
    /// Carbon-fibre nylons treated as one material when matching.
    private static let nylonCF: Set<String> = ["PA-CF", "PA12-CF", "PAHT-CF"]

    static func canonical(_ type: String?) -> String {
        (type ?? "").trimmingCharacters(in: .whitespaces).uppercased()
    }

    static func compatible(_ a: String?, _ b: String?) -> Bool {
        let x = canonical(a), y = canonical(b)
        if x == y { return true }
        return nylonCF.contains(x) && nylonCF.contains(y)
    }
}

// MARK: - Matching engine

/// The matching rules behind `FilamentMappingModel`, kept free of loading state so they can be tested.
enum FilamentAutoMapper {
    /// "Prefer the emptiest spool" only applies while AMS Filament Backup isn't known to be off.
    static func preferLowest(setting: Bool, backupOn: Bool?) -> Bool { setting && backupOn != false }

    /// Lowest remaining first: tracked spools by grams, then untracked trays by remain % (unknown last),
    /// then by physical position (AMS, rack AMS, AMS HT, external), then printer order.
    static func lowestFirst(_ trays: [LoadedSpoolTray], inventory: [Int: Double]) -> [LoadedSpoolTray] {
        func group(_ t: LoadedSpoolTray) -> Int {
            if t.isExternal { return 3 }
            if t.isHT { return 2 }
            return t.globalId >= 28 ? 1 : 0
        }
        func amount(_ t: LoadedSpoolTray) -> (Int, Double) {
            if let grams = inventory[t.globalId] { return (0, grams) }
            return (1, t.remain < 0 ? .infinity : Double(t.remain))
        }
        return trays.enumerated().sorted { lhs, rhs in
            let a = amount(lhs.element), b = amount(rhs.element)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            let ga = group(lhs.element), gb = group(rhs.element)
            if ga != gb { return ga < gb }
            if lhs.element.globalId != rhs.element.globalId, ga <= 1 { return lhs.element.globalId < rhs.element.globalId }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func compare(needs: [FilamentNeed], trays: [LoadedSpoolTray], manual: [Int: Int],
                        preferLowest: Bool, inventory: [Int: Double], trackSwitch: Bool) -> [SlotComparison] {
        let loaded = Dictionary(trays.map { ($0.globalId, $0) }, uniquingKeysWith: { first, _ in first })
        // Manual picks reserve their trays before anything is auto-matched.
        var used = Set<Int>()
        for need in needs { if let pick = manual[need.slotId], pick >= 0, loaded[pick] != nil { used.insert(pick) } }
        let ordered = preferLowest ? lowestFirst(trays, inventory: inventory) : trays

        var rows: [SlotComparison] = []
        for need in needs.sorted(by: { $0.slotId < $1.slotId }) {
            if let pick = manual[need.slotId] {
                if pick < 0 {
                    rows.append(SlotComparison(need: need, tray: nil, match: .unassigned, manual: true))
                    continue
                }
                if let tray = loaded[pick] {
                    let match: SlotMatch = !MappingMaterial.compatible(tray.type, need.type) ? .mismatch
                        : MappingColor.matches(loaded: tray.color, required: need.color) ? .match : .colorDiffers
                    rows.append(SlotComparison(need: need, tray: tray, match: match, manual: true))
                    continue
                }
                // The picked tray is no longer loaded: match this slot afresh.
            }
            var pool = ordered.filter { !used.contains($0.globalId) }
            // Without a track switch, a slot bound to one nozzle can only take that nozzle's trays.
            if let nozzle = need.nozzleId, !trackSwitch { pool = pool.filter { $0.extruderId == nozzle } }
            var chosen: LoadedSpoolTray?
            let idx = need.trayInfoIdx ?? ""
            if !idx.isEmpty {
                let sameProduct = pool.filter { $0.trayInfoIdx == idx }
                if sameProduct.count == 1 { chosen = sameProduct[0] }
                else if sameProduct.count > 1 { chosen = bestByMaterial(sameProduct, for: need) }
            }
            if chosen == nil { chosen = bestByMaterial(pool, for: need) }
            guard let tray = chosen else {
                rows.append(SlotComparison(need: need, tray: nil, match: .mismatch, manual: false))
                continue
            }
            used.insert(tray.globalId)
            let match: SlotMatch = MappingColor.matches(loaded: tray.color, required: need.color) ? .match : .colorDiffers
            rows.append(SlotComparison(need: need, tray: tray, match: match, manual: false))
        }
        return rows
    }

    /// Same material: an exact colour, else the nearest similar colour, else the first in pool order.
    private static func bestByMaterial(_ pool: [LoadedSpoolTray], for need: FilamentNeed) -> LoadedSpoolTray? {
        let candidates = pool.filter { MappingMaterial.compatible($0.type, need.type) }
        let wanted = MappingColor.normalize(need.color)
        if !wanted.isEmpty, let exact = candidates.first(where: { MappingColor.normalize($0.color) == wanted }) { return exact }
        return MappingColor.nearest(candidates, to: need.color) ?? candidates.first
    }

    static func mapping(needs: [FilamentNeed], trays: [LoadedSpoolTray], rows: [SlotComparison]) -> [Int]? {
        guard !trays.isEmpty, let last = needs.map(\.slotId).max(), last > 0 else { return nil }
        var out = Array(repeating: -1, count: last)
        for row in rows where row.need.slotId > 0 { out[row.need.slotId - 1] = row.tray?.globalId ?? -1 }
        return out
    }

    /// A fresh manual pick of another material. A pick the job already carried when it was opened doesn't count.
    static func substitutesMaterial(rows: [SlotComparison], opened: [Int]?) -> Bool {
        rows.contains { row in
            guard row.manual, row.match == .mismatch, let tray = row.tray else { return false }
            let index = row.need.slotId - 1
            if let opened, index >= 0, index < opened.count, opened[index] == tray.globalId { return false }
            return true
        }
    }

    static func deficits(rows: [SlotComparison], trays: [LoadedSpoolTray], slotMaterials: [Int: InventoryRemain.Slot],
                         backupOn: Bool?, warningsDisabled: Bool, hasMapping: Bool) -> [FilamentDeficit] {
        guard !warningsDisabled, !slotMaterials.isEmpty, hasMapping else { return [] }
        var required: [Int: Double] = [:]
        for row in rows { if let tray = row.tray { required[tray.globalId, default: 0] += row.need.usedGrams ?? 0 } }
        func label(_ id: Int) -> String { trays.first { $0.globalId == id }?.label ?? "Tray \(id)" }

        var out: [(id: Int, deficit: FilamentDeficit)] = []
        if backupOn == true {
            // With backup on, spools of the same material on the same nozzle hand over to each other.
            struct Key: Hashable { let material: String; let extruder: Int }
            var poolRequired: [Key: Double] = [:]
            var poolFirst: [Key: Int] = [:]
            for (id, grams) in required {
                guard let slot = slotMaterials[id] else { continue }
                let key = Key(material: slot.materialKey, extruder: slot.extruder)
                poolRequired[key, default: 0] += grams
                poolFirst[key] = min(poolFirst[key] ?? id, id)
            }
            for (key, need) in poolRequired {
                let members = slotMaterials.values.filter { $0.materialKey == key.material && $0.extruder == key.extruder }
                let have = members.reduce(0) { $0 + $1.remainingG }
                guard have < need, let first = poolFirst[key] else { continue }
                out.append((first, FilamentDeficit(slotLabel: label(first), requiredGrams: need, remainingGrams: have, pooled: members.count > 1)))
            }
        } else {
            for (id, need) in required {
                guard let slot = slotMaterials[id], slot.remainingG < need else { continue }
                out.append((id, FilamentDeficit(slotLabel: label(id), requiredGrams: need, remainingGrams: slot.remainingG, pooled: false)))
            }
        }
        return out.sorted { $0.id < $1.id }.map(\.deficit)
    }
}

// MARK: - Mapping model

/// Loads the plate's filament needs and the printer's loaded trays, auto-matches them, and
/// keeps the user's manual picks. `mapping` is what goes in `ams_mapping`.
@MainActor
final class FilamentMappingModel: ObservableObject {
    @Published private(set) var needs: [FilamentNeed] = []
    @Published private(set) var loadingNeeds = false
    @Published private(set) var needsError: String?
    @Published private(set) var trays: [LoadedSpoolTray] = []
    @Published private(set) var loadingPrinter = false
    @Published private(set) var printerNote: String?
    /// slot_id -> global tray id (-1 = leave this slot unmapped).
    @Published var manual: [Int: Int] = [:]
    /// Rack position the user settled on per filament group (H2C). Empty = "assign them for me".
    @Published private(set) var rackChoice: [Int: Int] = [:]
    @Published private(set) var rackSlots: [AdvRackSlot] = []
    /// Raw model of the chosen printer, set by the host; the rack picker only exists for rack models.
    @Published var printerModel: String?
    /// globalTrayId -> grams left on the bound inventory spool.
    @Published private(set) var inventory: [Int: Double] = [:]
    @Published private(set) var slotMaterials: [Int: InventoryRemain.Slot] = [:]
    @Published private(set) var backupOn: Bool?
    @Published private(set) var preferLowestSetting = false
    @Published private(set) var warningsDisabled = false
    /// The ams_mapping a queue item already carries, when editing one.
    private(set) var openedMapping: [Int]?
    private var seedData: (mapping: [Int]?, rack: [String: Int]?)?
    private var printerLoaded = false
    private var flagsLoaded = false
    private var fts = false
    private var needsToken = 0
    private var printerToken = 0
    private var printerId: Int?

    // MARK: Loading

    /// Editing a queued job: start from the mapping and rack picks it already stores. Applied once both
    /// the plate's needs and the printer's trays have loaded (stored picks for trays that are gone are dropped).
    func seed(mapping: [Int]?, rack: [String: Int]?) {
        openedMapping = mapping
        seedData = (mapping, rack)
        trySeed()
    }

    private func trySeed() {
        guard let data = seedData, printerLoaded, !needs.isEmpty else { return }
        seedData = nil
        if let stored = data.mapping {
            for need in needs where need.slotId - 1 < stored.count {
                let tray = stored[need.slotId - 1]
                // -1 is not a pick: that slot is matched afresh.
                if tray >= 0, trays.contains(where: { $0.globalId == tray }) { manual[need.slotId] = tray }
            }
        }
        if let rack = data.rack {
            var picks: [Int: Int] = [:]
            for (key, position) in rack { if let group = Int(key), rackGroups[group]?.onRack == true { picks[group] = position } }
            rackChoice = picks
        }
    }

    func loadNeeds(archiveId: Int?, libraryFileId: Int?, plateId: Int?) async {
        needsToken += 1
        let token = needsToken
        loadingNeeds = true
        defer { if token == needsToken { loadingNeeds = false } }
        do {
            let list: [FilamentNeed]
            if let archiveId { list = try await APIClient.shared.archiveFilamentNeeds(archiveId, plateId: plateId) }
            else if let libraryFileId { list = try await APIClient.shared.libraryFilamentNeeds(libraryFileId, plateId: plateId) }
            else { list = [] }
            guard token == needsToken, !Task.isCancelled else { return }
            needs = list.filter { $0.usedInPlate != false && $0.slotId > 0 }.sorted { $0.slotId < $1.slotId }
            needsError = nil
            manual = manual.filter { entry in needs.contains { $0.slotId == entry.key } }
            let groups = rackGroups
            rackChoice = rackChoice.filter { groups[$0.key]?.onRack == true }
            trySeed()
        } catch {
            guard token == needsToken, !Task.isCancelled else { return }
            needs = []
            needsError = FriendlyError.message(error)
        }
    }

    /// Reads the printer's live AMS state. `nil` clears it (no specific printer chosen).
    func loadPrinter(_ id: Int?) async {
        printerToken += 1
        let token = printerToken
        if id != printerId {
            manual = [:] // tray ids only mean something on the printer they came from
            rackChoice = [:] // so do rack positions
            printerLoaded = false
        }
        printerId = id
        guard let id else {
            trays = []
            rackSlots = []
            inventory = [:]
            slotMaterials = [:]
            backupOn = nil
            printerNote = nil
            printerLoaded = true
            trySeed()
            return
        }
        loadingPrinter = true
        defer { if token == printerToken { loadingPrinter = false } }
        await loadFlags()
        do {
            let status = try await APIClient.shared.mappingStatus(printerId: id)
            // Spool weights are a bonus: without printers:read on the route or a bound spool the mapping still works.
            let remain = try? await APIClient.shared.inventoryRemain(printerId: id)
            guard token == printerToken, !Task.isCancelled else { return }
            apply(status, remain: remain)
        } catch {
            guard token == printerToken, !Task.isCancelled else { return }
            trays = []
            rackSlots = []
            inventory = [:]
            slotMaterials = [:]
            backupOn = nil
            printerNote = "Couldn't read this printer's filament (\(FriendlyError.message(error))). The scheduler will pick trays when the job starts."
            printerLoaded = true
            trySeed()
        }
    }

    private func loadFlags() async {
        guard !flagsLoaded else { return }
        if let flags: MappingFlags = try? await APIClient.shared.get("settings/ui-flags") {
            preferLowestSetting = flags.preferLowestFilament ?? false
            warningsDisabled = flags.disableFilamentWarnings ?? false
            flagsLoaded = true
        }
    }

    private func apply(_ status: MappingPrinterStatus, remain: InventoryRemain?) {
        fts = status.filaSwitch?.installed == true
        backupOn = status.amsFilamentBackup
        rackSlots = status.nozzleRack ?? []
        var grams: [Int: Double] = [:]
        for (key, value) in remain?.inventoryRemainG ?? [:] { if let tray = Int(key) { grams[tray] = value } }
        inventory = grams
        slotMaterials = Dictionary(remain?.slotMaterials.map { ($0.globalTrayId, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let extruderMap = status.amsExtruderMap ?? [:]
        let externals = status.vtTray ?? []
        let dualNozzle = (status.nozzles ?? []).dropFirst().first.map { ($0.nozzleDiameter ?? "").isEmpty == false } == true
            || !extruderMap.isEmpty || externals.count > 1
        var out: [LoadedSpoolTray] = []
        var skipped: [String] = []
        // A rack AMS feeds the printer's one extruder; its per-nozzle external inputs feed the same one.
        var rackExtruderId: Int?
        let perNozzleExternals = externals.contains { $0.nozzleAddr != nil } || externals.count > 2
        for unit in status.ams ?? [] {
            let isHT = unit.isAmsHt == true || unit.id >= 128
            let unitTrays = unit.tray ?? []
            if unit.rack {
                if rackExtruderId == nil { rackExtruderId = extruderMap[String(unit.id)] }
                let name = unit.amsTypeName?.isEmpty == false ? unit.amsTypeName! : (unit.amsType == 7 ? "AMS-B" : "AMS-3H")
                let base = unit.amsType == 7 ? 37 : 28
                for tray in unitTrays where !(tray.trayType ?? "").isEmpty && (0...8).contains(tray.id) {
                    out.append(LoadedSpoolTray(
                        amsId: unit.id, trayId: tray.id, isHT: false, isExternal: false,
                        type: tray.trayType ?? "", color: Self.color(tray.trayColor), globalId: base + tray.id,
                        trayInfoIdx: tray.trayInfoIdx ?? "", subBrands: tray.traySubBrands ?? "",
                        extruderId: extruderMap[String(unit.id)], remain: tray.remain ?? -1,
                        label: "\(name) \(tray.id + 1)"))
                }
                continue
            }
            // Only classic 4-slot AMS and single-slot AMS-HT have a verified tray id mapping.
            if !isHT, unitTrays.count > 4 || unitTrays.contains(where: { $0.id > 3 }) {
                skipped.append(Self.unitName(unit.id, isHT: isHT))
                continue
            }
            for tray in unitTrays where !(tray.trayType ?? "").isEmpty {
                let global = isHT ? unit.id : unit.id * 4 + tray.id
                out.append(LoadedSpoolTray(
                    amsId: unit.id, trayId: tray.id, isHT: isHT, isExternal: false,
                    type: tray.trayType ?? "", color: Self.color(tray.trayColor), globalId: global,
                    trayInfoIdx: tray.trayInfoIdx ?? "", subBrands: tray.traySubBrands ?? "",
                    extruderId: extruderMap[String(unit.id)], remain: tray.remain ?? -1,
                    label: isHT ? Self.unitName(unit.id, isHT: true) : "\(Self.unitName(unit.id, isHT: false)) slot \(tray.id + 1)"))
            }
        }
        if perNozzleExternals {
            // H3C: inputs 247-255, one per nozzle (nozzle = 255 - id); the id is the global tray id.
            for tray in externals.sorted(by: { $0.id > $1.id }) where !(tray.trayType ?? "").isEmpty {
                let nozzle = tray.nozzleAddr ?? (255 - tray.id)
                out.append(LoadedSpoolTray(
                    amsId: 255, trayId: tray.id - 254, isHT: false, isExternal: true,
                    type: tray.trayType ?? "", color: Self.color(tray.trayColor), globalId: tray.id,
                    trayInfoIdx: tray.trayInfoIdx ?? "", subBrands: tray.traySubBrands ?? "",
                    extruderId: rackExtruderId, remain: tray.remain ?? -1,
                    label: "Ext \(nozzle + 1)"))
            }
        } else if externals.count <= 2 {
            for tray in externals where !(tray.trayType ?? "").isEmpty {
                let id = tray.id
                out.append(LoadedSpoolTray(
                    amsId: 255, trayId: id - 254, isHT: false, isExternal: true,
                    type: tray.trayType ?? "", color: Self.color(tray.trayColor), globalId: id,
                    trayInfoIdx: tray.trayInfoIdx ?? "", subBrands: tray.traySubBrands ?? "",
                    extruderId: dualNozzle ? 255 - id : nil, remain: tray.remain ?? -1,
                    label: externals.count > 1 ? (id == 254 ? "External left" : "External right") : "External spool"))
            }
        } else {
            skipped.append("the spool holders")
        }
        trays = out
        printerNote = skipped.isEmpty ? nil
            : "Not offered: \(skipped.joined(separator: ", ")). Its tray numbering isn't a standard AMS layout, so LayerPal can't safely map to it."
        manual = manual.filter { entry in entry.value < 0 || out.contains { $0.globalId == entry.value } }
        printerLoaded = true
        trySeed()
    }

    private static func unitName(_ id: Int, isHT: Bool) -> String {
        if isHT { return "AMS HT \(id - 127)" }
        guard id >= 0, id < 26, let scalar = UnicodeScalar(65 + id) else { return "AMS #\(id)" }
        return "AMS \(Character(scalar))"
    }

    private static func color(_ rgba: String?) -> String { MappingColor.normalize(rgba) }

    // MARK: Prefer lowest remaining

    /// The "prefer the emptiest matching spool" setting, honoured only while AMS Filament Backup isn't
    /// known to be off.
    /// Without backup, a nearly empty spool can't hand over mid-print, so the setting is ignored then.
    var preferLowest: Bool { FilamentAutoMapper.preferLowest(setting: preferLowestSetting, backupOn: backupOn) }

    // MARK: Matching

    /// One row per filament need: the tray that feeds it and how well it matches.
    var comparison: [SlotComparison] {
        FilamentAutoMapper.compare(needs: needs, trays: trays, manual: manual, preferLowest: preferLowest,
                                   inventory: inventory, trackSwitch: fts)
    }

    /// `ams_mapping` for POST /queue/. nil when the printer's trays aren't known (the scheduler
    /// then maps at dispatch) or nothing is required.
    var mapping: [Int]? {
        FilamentAutoMapper.mapping(needs: needs, trays: trays, rows: comparison)
    }

    /// A manual pick that puts a slot on a tray of another material needs `skip_filament_check`.
    var substitutesMaterial: Bool {
        FilamentAutoMapper.substitutesMaterial(rows: comparison, opened: openedMapping)
    }

    /// Slots that can't be satisfied from what's loaded.
    var shortfalls: [SlotComparison] {
        comparison.filter { $0.match == .mismatch || $0.match == .unassigned }
    }

    // MARK: Spool weight check

    /// Trays whose bound spool holds less than the job needs.
    var deficits: [FilamentDeficit] {
        let rows = comparison
        return FilamentAutoMapper.deficits(
            rows: rows, trays: trays, slotMaterials: slotMaterials, backupOn: backupOn,
            warningsDisabled: warningsDisabled,
            hasMapping: FilamentAutoMapper.mapping(needs: needs, trays: trays, rows: rows) != nil)
    }

    // MARK: Nozzle rack (H2C)

    var rackGroups: [Int: RackGroupInfo] {
        var out: [Int: RackGroupInfo] = [:]
        for need in needs { if let id = need.groupId, let group = need.group { out[id] = group } }
        return out
    }

    /// The picker only exists for a rack model whose live rack is readable and whose plate has a group
    /// that needs a hotend off the rack.
    var hasRack: Bool {
        NozzleRack.isRackModel(printerModel) && rackSlots.contains { $0.id >= 16 } && rackGroups.values.contains { $0.onRack }
    }

    /// What the dispatcher would assign with no picks, shown as the pre-selection; explicit picks are pinned.
    var effectiveRackChoice: [Int: Int] {
        guard hasRack else { return [:] }
        return NozzleRack.autoAssign(rackSlots, groups: rackGroups, pinned: rackChoice) ?? rackChoice
    }

    /// Every group is written back, not just the edited one: leaving the others implicit would let the
    /// dispatcher move a hotend the user had already seen and accepted.
    func pickRack(group: Int, position: Int) {
        var next = effectiveRackChoice
        next[group] = position
        rackChoice = next
    }

    func resetRack() { rackChoice = [:] }

    /// `nozzle_rack_choice` for the API: nil until the user picks (the dispatcher then assigns).
    var rackChoiceForRequest: [String: Int]? {
        guard hasRack, !rackChoice.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: rackChoice.map { (String($0.key), $0.value) })
    }
}
