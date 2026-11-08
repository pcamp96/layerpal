import XCTest
@testable import LayerPal

final class ForecastTests: XCTestCase {
    private func date(_ day: Int, hour: Int = 9) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour))!
    }

    private var now: Date { date(3, hour: 12) }

    private func spool(_ id: Int, remaining: Double, color: String = "Black", archived: Bool = false) throws -> Spool {
        var json: [String: Any] = [
            "id": id, "material": "PLA", "subtype": "Basic", "brand": "Bambu Lab", "color_name": color,
            "label_weight": 1000, "weight_used": 1000 - remaining,
        ]
        if archived { json["archived_at"] = "2026-01-01T00:00:00Z" }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Spool.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func usage(_ spool: Int, _ grams: Double, day: Int, id: Int = 0) -> SpoolUsageRecord {
        SpoolUsageRecord(id: id, spoolId: spool, spoolmanSpoolId: nil, printerId: nil, printName: nil, weightUsed: grams,
                         percentUsed: nil, status: "completed", cost: nil, createdAt: date(day))
    }

    private var f1Usage: [SpoolUsageRecord] { [usage(1, 100, day: 1), usage(1, 50, day: 3)] }

    private func forecast(remaining: Double, usage: [SpoolUsageRecord]? = nil, settings: [SkuSettings] = []) throws -> SkuForecast {
        let result = ForecastEngine.build(spools: [try spool(1, remaining: remaining)], usage: usage ?? f1Usage,
                                          settings: settings, globalLeadDays: 7, spoolman: false, now: now)
        XCTAssertEqual(result.count, 1)
        return result[0]
    }

    func testF1() throws {
        let rate = ForecastEngine.historyRate(f1Usage, now: now)
        XCTAssertEqual(rate?.rate ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(rate?.sd ?? -1, 0, accuracy: 1e-9)
        let f = try forecast(remaining: 1000)
        XCTAssertEqual(f.safetyStockG, 1.65 * 5 * sqrt(7) + 350, accuracy: 0.01)
        XCTAssertEqual(f.safetyStockG, 371.83, accuracy: 0.01)
        XCTAssertEqual(f.reorderPointG, 546.83, accuracy: 0.01)
        XCTAssertEqual(f.daysRemaining ?? 0, 40, accuracy: 1e-9)
        XCTAssertFalse(f.stockBreak)
        XCTAssertFalse(f.reorder)
    }

    func testF2Reorder() throws {
        let f = try forecast(remaining: 500)
        XCTAssertEqual(f.daysRemaining ?? 0, 20, accuracy: 1e-9)
        XCTAssertTrue(f.reorder)
        XCTAssertFalse(f.stockBreak)
    }

    func testF3StockBreak() throws {
        let f = try forecast(remaining: 150)
        XCTAssertEqual(f.daysRemaining ?? 0, 6, accuracy: 1e-9)
        XCTAssertTrue(f.stockBreak)
        XCTAssertFalse(f.reorder)
    }

    func testF4OneDayOnly() throws {
        let f = try forecast(remaining: 300, usage: [usage(1, 100, day: 2)])
        XCTAssertNil(f.dailyRateG)
        XCTAssertEqual(f.safetyStockG, 70, accuracy: 1e-9)
        XCTAssertEqual(f.reorderPointG, 70, accuracy: 1e-9)
        XCTAssertNil(f.daysRemaining)
        XCTAssertFalse(f.stockBreak)
        XCTAssertFalse(f.reorder)
        XCTAssertNil(f.projectedEmpty)
    }

    private func settings(margin: Int = 14, unit: String = "days", snoozed: Bool = false, color: String? = "Black") -> SkuSettings {
        SkuSettings(id: 1, material: "PLA", subtype: "Basic", brand: "Bambu Lab", colorName: color, leadTimeDays: 0,
                    safetyMarginValue: margin, safetyMarginUnit: unit, alertsSnoozed: snoozed)
    }

    func testF5GramMargin() throws {
        let f = try forecast(remaining: 1000, settings: [settings(margin: 100, unit: "grams")])
        XCTAssertEqual(f.safetyStockG, 121.83, accuracy: 0.01)
        XCTAssertEqual(f.reorderPointG, 296.83, accuracy: 0.01)
    }

    func testF6Snoozed() throws {
        let f = try forecast(remaining: 500, settings: [settings(snoozed: true)])
        XCTAssertFalse(f.reorder)
        XCTAssertFalse(f.stockBreak)
    }

    func testF7SameDayRecordsAddUp() {
        let records = [usage(1, 100, day: 1), usage(1, 30, day: 3, id: 1), usage(1, 20, day: 3, id: 2)]
        XCTAssertEqual(ForecastEngine.historyRate(records, now: now)?.rate ?? 0, 25, accuracy: 1e-9)
    }

    func testSettingsFallBackToColorlessSku() throws {
        let f = try forecast(remaining: 500, settings: [settings(snoozed: true, color: nil)])
        XCTAssertNotNil(f.settings)
        XCTAssertFalse(f.reorder)
    }

    func testArchivedSpoolsAreNotStock() throws {
        let result = ForecastEngine.build(spools: [try spool(1, remaining: 500), try spool(2, remaining: 900, archived: true)],
                                          usage: f1Usage, settings: [], globalLeadDays: 7, spoolman: false, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].remainingG, 500, accuracy: 1e-9)
        XCTAssertEqual(result[0].spoolCount, 1)
    }

    func testTitle() throws {
        let basic = try forecast(remaining: 500)
        XCTAssertEqual(basic.title, "Bambu Lab PLA Basic Black")
        let dup = ForecastEngine.build(spools: [try spool(1, remaining: 500, color: "basic")], usage: [], settings: [],
                                       globalLeadDays: 7, spoolman: false, now: now)
        XCTAssertEqual(dup.first?.title, "Bambu Lab PLA Basic")
    }
}
