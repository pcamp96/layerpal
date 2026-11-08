import Foundation
import SwiftUI

// Filament catalog, suppliers, usage history, forecast and storage locations. Shapes match
// the Bambuddy 1.3.0 inventory responses.

// MARK: Filament catalog (/filament-catalog)

struct CatalogFilament: Decodable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let brand: String?
    let color: String?
    /// "#RRGGBB"
    let colorHex: String?
    let costPerKg: Double
    let spoolWeightG: Double
    let currency: String?
    let density: Double?
    let printTempMin: Int?
    let printTempMax: Int?
    let bedTempMin: Int?
    let bedTempMax: Int?

    var swatch: Color { Color(hexRGBA: colorHex?.replacingOccurrences(of: "#", with: "")) ?? Color.bgRaised }
}

/// Editable copy of a catalog entry. Numbers stay text so a field can be empty while typing.
struct CatalogFilamentDraft {
    var name = ""
    var type = ""
    var brand = ""
    var color = ""
    var colorHex = ""
    var costPerKg = "25"
    var spoolWeight = "1000"
    var currency = "USD"
    var density = ""
    var printMin = ""
    var printMax = ""
    var bedMin = ""
    var bedMax = ""

    init() {}

    init(_ f: CatalogFilament) {
        name = f.name
        type = f.type
        brand = f.brand ?? ""
        color = f.color ?? ""
        colorHex = f.colorHex ?? ""
        costPerKg = SpoolDraft.text(f.costPerKg)
        spoolWeight = SpoolDraft.text(f.spoolWeightG)
        currency = f.currency ?? "USD"
        density = f.density.map(SpoolDraft.text) ?? ""
        printMin = f.printTempMin.map(String.init) ?? ""
        printMax = f.printTempMax.map(String.init) ?? ""
        bedMin = f.bedTempMin.map(String.init) ?? ""
        bedMax = f.bedTempMax.map(String.init) ?? ""
    }

    private static func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
    private func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if t(name).isEmpty { return "Name is required." }
        if t(name).count > 100 { return "Name can be at most 100 characters." }
        if t(type).isEmpty { return "Material type is required." }
        if t(type).count > 50 { return "Material type can be at most 50 characters." }
        if Self.number(costPerKg) == nil { return "Cost per kg must be a number." }
        if Self.number(spoolWeight) == nil { return "Spool weight must be a number." }
        if !t(colorHex).isEmpty, t(colorHex).range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil {
            return "Color must look like #RRGGBB."
        }
        if !t(density).isEmpty, Self.number(density) == nil { return "Density must be a number." }
        for value in [printMin, printMax, bedMin, bedMax] where !t(value).isEmpty && Int(t(value)) == nil { return "Temperatures are whole degrees." }
        return nil
    }

    private struct Create: Encodable {
        let name: String
        let type: String
        let brand: String?
        let color: String?
        let colorHex: String?
        let costPerKg: Double
        let spoolWeightG: Double
        let currency: String
        let density: Double?
        let printTempMin: Int?
        let printTempMax: Int?
        let bedTempMin: Int?
        let bedTempMax: Int?
    }

    /// POST body: the schema's own defaults fill anything left out.
    func createBody() -> some Encodable {
        Create(name: t(name), type: t(type), brand: t(brand).isEmpty ? nil : t(brand), color: t(color).isEmpty ? nil : t(color),
               colorHex: t(colorHex).isEmpty ? nil : t(colorHex), costPerKg: Self.number(costPerKg) ?? 25,
               spoolWeightG: Self.number(spoolWeight) ?? 1000, currency: t(currency).isEmpty ? "USD" : t(currency),
               density: Self.number(density), printTempMin: Int(t(printMin)), printTempMax: Int(t(printMax)),
               bedTempMin: Int(t(bedMin)), bedTempMax: Int(t(bedMax)))
    }

    /// PATCH body with only what changed. Clearing an optional field sends null (the update schema allows it).
    func patch(from old: CatalogFilament) -> InventoryPatch {
        var p = InventoryPatch()
        let was = CatalogFilamentDraft(old)
        func text(_ key: String, _ new: String, _ prior: String, clearable: Bool = true) {
            let value = t(new)
            guard value != prior else { return }
            if value.isEmpty { if clearable { p[key] = .null } } else { p[key] = .string(value) }
        }
        text("name", name, was.name, clearable: false)
        text("type", type, was.type, clearable: false)
        text("brand", brand, was.brand)
        text("color", color, was.color)
        text("color_hex", colorHex, was.colorHex)
        text("currency", currency, was.currency, clearable: false)
        if let v = Self.number(costPerKg), v != old.costPerKg { p["cost_per_kg"] = .double(v) }
        if let v = Self.number(spoolWeight), v != old.spoolWeightG { p["spool_weight_g"] = .double(v) }
        if t(density) != was.density { p["density"] = Self.number(density).map(PatchValue.double) ?? .null }
        if t(printMin) != was.printMin { p["print_temp_min"] = Int(t(printMin)).map(PatchValue.int) ?? .null }
        if t(printMax) != was.printMax { p["print_temp_max"] = Int(t(printMax)).map(PatchValue.int) ?? .null }
        if t(bedMin) != was.bedMin { p["bed_temp_min"] = Int(t(bedMin)).map(PatchValue.int) ?? .null }
        if t(bedMax) != was.bedMax { p["bed_temp_max"] = Int(t(bedMax)).map(PatchValue.int) ?? .null }
        return p
    }
}

// MARK: Suppliers

struct Supplier: Decodable, Identifiable {
    let id: Int
    let name: String
    let website: String?
    let customerNumber: String?
    let note: String?
    let spoolCount: Int?
}

struct SupplierDraft {
    var name = ""
    var website = ""
    var customerNumber = ""
    var note = ""

    init() {}

    init(_ s: Supplier) {
        name = s.name
        website = s.website ?? ""
        customerNumber = s.customerNumber ?? ""
        note = s.note ?? ""
    }

    private func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    var problem: String? {
        if t(name).isEmpty { return "Name is required." }
        if t(name).count > 200 { return "Name can be at most 200 characters." }
        if t(website).count > 500 { return "Website can be at most 500 characters." }
        if t(customerNumber).count > 100 { return "Customer number can be at most 100 characters." }
        if t(note).count > 500 { return "Note can be at most 500 characters." }
        return nil
    }

    private struct Create: Encodable {
        let name: String
        let website: String?
        let customerNumber: String?
        let note: String?
    }

    func createBody() -> some Encodable {
        Create(name: t(name), website: t(website).isEmpty ? nil : t(website),
               customerNumber: t(customerNumber).isEmpty ? nil : t(customerNumber), note: t(note).isEmpty ? nil : t(note))
    }

    /// PATCH body with only what changed (the schema has a null for every optional field).
    func patch(from old: Supplier) -> InventoryPatch {
        var p = InventoryPatch()
        func text(_ key: String, _ new: String, _ prior: String?) {
            let value = t(new)
            guard value != (prior ?? "") else { return }
            p[key] = value.isEmpty ? .null : .string(value)
        }
        if t(name) != old.name, !t(name).isEmpty { p["name"] = .string(t(name)) }
        text("website", website, old.website)
        text("customer_number", customerNumber, old.customerNumber)
        text("note", note, old.note)
        return p
    }
}

struct SupplierStat: Decodable, Identifiable {
    let supplierId: Int
    let supplierName: String
    let spoolCount: Int
    let remainingG: Double
    let consumedG: Double
    let cost: Double
    var id: Int { supplierId }
}

// MARK: Usage history

struct SpoolUsageRecord: Decodable, Identifiable {
    let id: Int
    let spoolId: Int?
    let spoolmanSpoolId: Int?
    let printerId: Int?
    let printName: String?
    let weightUsed: Double
    let percentUsed: Int?
    let status: String?
    let cost: Double?
    let createdAt: Date

    var statusLabel: String {
        switch status {
        case "completed": "Completed"
        case "failed": "Failed"
        case "cancelled", "aborted", "stopped": "Cancelled"
        default: (status ?? "").capitalized
        }
    }

    var tint: Color {
        switch status {
        case "completed": .accentTeal
        case "failed": .statusError
        default: .statusWarning
        }
    }
}

// MARK: Forecast

/// A SKU's reorder settings (POST /inventory/sku-settings upserts by material, subtype, brand, color name).
struct SkuSettings: Decodable, Identifiable, Hashable {
    var id: Int?
    var material: String
    var subtype: String?
    var brand: String?
    var colorName: String?
    var leadTimeDays: Int
    var safetyMarginValue: Int
    /// "days" or "grams"
    var safetyMarginUnit: String
    var alertsSnoozed: Bool

    private struct Body: Encodable {
        let material: String
        let subtype: String?
        let brand: String?
        let colorName: String?
        let leadTimeDays: Int
        let safetyMarginValue: Int
        let safetyMarginUnit: String
        let alertsSnoozed: Bool
    }

    func body() -> some Encodable {
        Body(material: material, subtype: subtype, brand: brand, colorName: colorName, leadTimeDays: leadTimeDays,
             safetyMarginValue: safetyMarginValue, safetyMarginUnit: safetyMarginUnit, alertsSnoozed: alertsSnoozed)
    }
}

struct ShoppingItem: Decodable, Identifiable {
    let id: Int
    let material: String
    let subtype: String?
    let brand: String?
    let colorName: String?
    let quantitySpools: Int
    let note: String?
    let status: String
    let purchasedAt: String?
    let addedAt: String?

    var title: String { [brand, material, subtype, colorName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
}

/// One SKU's stock, daily use, reorder point and days remaining. Uses the same reorder-point and
/// safety-stock math as the server's stock alerts, so the screen and the notifications agree.
struct SkuForecast: Identifiable {
    let key: String
    let material: String
    let subtype: String?
    let brand: String?
    let colorName: String?
    let spoolCount: Int
    let remainingG: Double
    let labelG: Double
    let dailyRateG: Double?
    let leadTimeDays: Int
    let safetyStockG: Double
    let reorderPointG: Double
    let daysRemaining: Double?
    let settings: SkuSettings?

    var id: String { key }

    /// Brand, material, subtype and colour. Spoolman copies the subtype into an empty colour name,
    /// so a colour equal to the subtype is left out.
    var title: String {
        let color = (colorName ?? "").caseInsensitiveCompare(subtype ?? "") == .orderedSame ? nil : colorName
        return [brand, material, subtype, color].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var snoozed: Bool { settings?.alertsSnoozed == true }

    /// Stock runs out before a replacement could arrive.
    var stockBreak: Bool {
        guard let days = daysRemaining, !snoozed else { return false }
        return days < Double(leadTimeDays)
    }

    /// The reorder point has been reached (and the stock is not already breaking).
    var reorder: Bool {
        dailyRateG != nil && !snoozed && !stockBreak && remainingG <= reorderPointG
    }

    var projectedEmpty: Date? {
        guard let days = daysRemaining, days.isFinite else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: Int(days.rounded()), to: today)
    }
}

/// Per-SKU usage forecast: a recency-weighted daily rate, safety stock for a one-sided 95 % service
/// level (z = 1.65) over the lead time plus a margin, and the reorder point that follows.
enum ForecastEngine {
    private static let halfLifeDays = 30.0
    private static let zScore = 1.65
    private static let fallbackDailyGrams = 5.0

    /// Usage-history rate and spread (g/day). nil with fewer than two days of use.
    static func historyRate(_ records: [SpoolUsageRecord], now: Date = Date()) -> (rate: Double, sd: Double)? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var perDay: [Date: Double] = [:]
        for record in records { perDay[utc.startOfDay(for: record.createdAt), default: 0] += record.weightUsed }
        let days = perDay.keys.sorted()
        guard days.count >= 2 else { return nil }

        var values: [Double] = []
        var weights: [Double] = []
        for i in 1..<days.count {
            let gap = max(1, (days[i].timeIntervalSince(days[i - 1]) / 86_400).rounded())
            values.append(perDay[days[i]]! / gap)
            let age = max(0, now.timeIntervalSince(days[i]) / 86_400)
            weights.append(pow(2, -age / halfLifeDays))
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        let mean = zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 } / total
        let variance = zip(values, weights).reduce(0) { $0 + $1.1 * pow($1.0 - mean, 2) } / total
        return (mean, sqrt(max(0, variance)))
    }

    static func skuKey(_ material: String, _ subtype: String?, _ brand: String?, _ colorName: String?) -> String {
        [material, subtype ?? "", brand ?? "", colorName ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    static func build(spools: [Spool], usage: [SpoolUsageRecord], settings: [SkuSettings], globalLeadDays: Int,
                      spoolman: Bool, now: Date = Date()) -> [SkuForecast] {
        func key(_ spool: Spool) -> String? {
            guard let material = spool.material, !material.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return skuKey(material, spool.subtype, spool.brand, spool.colorName)
        }
        // Stock: non-archived spools. Usage history may also come from spools of the SKU already archived.
        var stock: [String: [Spool]] = [:]
        var spoolIds: [String: Set<Int>] = [:]
        for spool in spools {
            guard let k = key(spool) else { continue }
            spoolIds[k, default: []].insert(spool.id)
            if spool.archivedAt == nil { stock[k, default: []].append(spool) }
        }
        var settingsByKey: [String: SkuSettings] = [:]
        for entry in settings {
            settingsByKey[skuKey(entry.material, entry.subtype, entry.brand, entry.colorName)] = entry
        }

        return stock.map { k, group -> SkuForecast in
            let first = group[0]
            let material = first.material ?? ""
            let config = settingsByKey[k] ?? settingsByKey[skuKey(material, first.subtype, first.brand, nil)]
            let ids = spoolIds[k] ?? []
            let records = usage.filter { record in
                guard let id = spoolman ? record.spoolmanSpoolId : record.spoolId else { return false }
                return ids.contains(id)
            }
            let history = historyRate(records, now: now)
            let rate = history?.rate
            let sigma = history.map { $0.sd > 0 ? $0.sd : 0.2 * $0.rate } ?? 0
            let lead = (config?.leadTimeDays ?? 0) > 0 ? config!.leadTimeDays : globalLeadDays
            let marginValue = Double(config?.safetyMarginValue ?? 14)
            let margin = config?.safetyMarginUnit == "grams" ? marginValue : marginValue * (rate ?? fallbackDailyGrams)
            let safety = zScore * sigma * sqrt(Double(max(0, lead))) + margin
            let reorderPoint = (rate ?? 0) * Double(lead) + safety
            let remaining = group.reduce(0) { $0 + $1.remainingGrams }
            let label = group.reduce(0) { $0 + ($1.labelWeight ?? 1000) }
            let days = (rate ?? 0) > 0 ? remaining / rate! : nil
            return SkuForecast(key: k, material: material, subtype: first.subtype, brand: first.brand, colorName: first.colorName,
                               spoolCount: group.count, remainingG: remaining, labelG: label, dailyRateG: rate,
                               leadTimeDays: lead, safetyStockG: safety, reorderPointG: reorderPoint,
                               daysRemaining: days, settings: config)
        }
        .sorted { $0.key < $1.key }
    }
}

// MARK: Locations

struct StorageLocation: Decodable, Identifiable {
    let id: Int
    let name: String
    let identifier: String?
    let spoolCount: Int?
}
