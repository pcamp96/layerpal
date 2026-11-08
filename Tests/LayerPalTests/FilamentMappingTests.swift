import XCTest
@testable import LayerPal

final class FilamentMappingTests: XCTestCase {
    // MARK: Fixtures

    private func tray(_ id: Int, _ type: String, _ color: String, idx: String = "", remain: Int, extruder: Int? = nil,
                      ht: Bool = false, external: Bool = false) -> LoadedSpoolTray {
        LoadedSpoolTray(amsId: ht ? id : (external ? 255 : id / 4), trayId: id % 4, isHT: ht, isExternal: external,
                        type: type, color: color, globalId: id, trayInfoIdx: idx, subBrands: "",
                        extruderId: extruder, remain: remain, label: "Tray \(id) label")
    }

    private func need(_ slot: Int, _ type: String, _ color: String? = nil, idx: String? = nil, nozzle: Int? = nil,
                      grams: Double? = nil) -> FilamentNeed {
        FilamentNeed(slotId: slot, type: type, color: color, usedGrams: grams, trayInfoIdx: idx, nozzleId: nozzle,
                     usedInPlate: nil, groupId: nil, group: nil)
    }

    private var t0: LoadedSpoolTray { tray(0, "PLA", "ff0000", idx: "GFA00", remain: 80) }
    private var t1: LoadedSpoolTray { tray(1, "PLA", "f01010", idx: "GFA00", remain: 20) }
    private var t2: LoadedSpoolTray { tray(2, "PETG", "ff0000", idx: "GFG00", remain: 50) }
    private var t3: LoadedSpoolTray { tray(3, "PLA", "0000ff", idx: "GFA01", remain: 90) }
    private var h: LoadedSpoolTray { tray(128, "PA12-CF", "333333", remain: 60, ht: true) }
    private var e: LoadedSpoolTray { tray(254, "PLA", "ffffff", remain: -1, external: true) }
    private var all: [LoadedSpoolTray] { [t0, t1, t2, t3, h, e] }

    private func run(_ needs: [FilamentNeed], trays: [LoadedSpoolTray]? = nil, manual: [Int: Int] = [:],
                     setting: Bool = false, backup: Bool? = nil, inventory: [Int: Double] = [:],
                     trackSwitch: Bool = false) -> (rows: [SlotComparison], mapping: [Int]?) {
        let trays = trays ?? all
        let rows = FilamentAutoMapper.compare(
            needs: needs, trays: trays, manual: manual,
            preferLowest: FilamentAutoMapper.preferLowest(setting: setting, backupOn: backup),
            inventory: inventory, trackSwitch: trackSwitch)
        return (rows, FilamentAutoMapper.mapping(needs: needs, trays: trays, rows: rows))
    }

    // MARK: Helpers

    func testColorHelpers() {
        XCTAssertEqual(MappingColor.normalize("#FF0000"), "ff0000")
        XCTAssertEqual(MappingColor.normalize("ff0000ff"), "ff0000")
        XCTAssertEqual(MappingColor.normalize(nil), "")
        XCTAssertTrue(MappingColor.similar("FF0000", "F01010"))
        XCTAssertFalse(MappingColor.similar("FF0000", "0000FF"))
        XCTAssertFalse(MappingColor.similar("FF0000", "zz"))
        XCTAssertTrue(MappingColor.matches(loaded: "123456", required: ""))
        XCTAssertEqual(MappingColor.distance("FF0000", "FF0000"), 0)
        XCTAssertNil(MappingColor.distance("FF0000", "nothex"))
    }

    func testSimilarGateBounds() {
        // Any pair within 16 per channel is similar; any pair 100+ apart on a channel is not.
        let bases = [(0, 0, 0), (255, 255, 255), (128, 64, 200), (20, 200, 30), (250, 5, 120)]
        func hex(_ r: Int, _ g: Int, _ b: Int) -> String { String(format: "%02x%02x%02x", r, g, b) }
        for (r, g, b) in bases {
            for dr in [-16, 0, 16] { for dg in [-16, 0, 16] { for db in [-16, 0, 16] {
                let r2 = min(255, max(0, r + dr)), g2 = min(255, max(0, g + dg)), b2 = min(255, max(0, b + db))
                XCTAssertTrue(MappingColor.similar(hex(r, g, b), hex(r2, g2, b2)))
            } } }
            for shift in [100, -100, 150] {
                let r2 = r + shift
                guard (0...255).contains(r2) else { continue }
                XCTAssertFalse(MappingColor.similar(hex(r, g, b), hex(r2, g, b)))
            }
        }
    }

    func testMaterialHelpers() {
        XCTAssertTrue(MappingMaterial.compatible("pla", "PLA"))
        XCTAssertTrue(MappingMaterial.compatible("PA12-CF", "PAHT-CF"))
        XCTAssertFalse(MappingMaterial.compatible("PETG", "PETG-HF"))
        XCTAssertEqual(MappingMaterial.canonical(nil), "")
    }

    /// Sample pairs published with Sharma, Wu and Dalal (2005).
    func testCIEDE2000AgainstPublishedPairs() {
        let data: [[Double]] = [
            [50.0000, 2.6772, -79.7751, 50.0000, 0.0000, -82.7485, 2.0425],
            [50.0000, 3.1571, -77.2803, 50.0000, 0.0000, -82.7485, 2.8615],
            [50.0000, 2.8361, -74.0200, 50.0000, 0.0000, -82.7485, 3.4412],
            [50.0000, -1.3802, -84.2814, 50.0000, 0.0000, -82.7485, 1.0000],
            [50.0000, -1.1848, -84.8006, 50.0000, 0.0000, -82.7485, 1.0000],
            [50.0000, -0.9009, -85.5211, 50.0000, 0.0000, -82.7485, 1.0000],
            [50.0000, 0.0000, 0.0000, 50.0000, -1.0000, 2.0000, 2.3669],
            [50.0000, -1.0000, 2.0000, 50.0000, 0.0000, 0.0000, 2.3669],
            [50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0009, 7.1792],
            [50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0010, 7.1792],
            [50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0011, 7.2195],
            [50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0012, 7.2195],
            [50.0000, -0.0010, 2.4900, 50.0000, 0.0009, -2.4900, 4.8045],
            [50.0000, -0.0010, 2.4900, 50.0000, 0.0010, -2.4900, 4.8045],
            [50.0000, -0.0010, 2.4900, 50.0000, 0.0011, -2.4900, 4.7461],
            [50.0000, 2.5000, 0.0000, 50.0000, 0.0000, -2.5000, 4.3065],
            [50.0000, 2.5000, 0.0000, 73.0000, 25.0000, -18.0000, 27.1492],
            [50.0000, 2.5000, 0.0000, 61.0000, -5.0000, 29.0000, 22.8977],
            [50.0000, 2.5000, 0.0000, 56.0000, -27.0000, -3.0000, 31.9030],
            [50.0000, 2.5000, 0.0000, 58.0000, 24.0000, 15.0000, 19.4535],
            [50.0000, 2.5000, 0.0000, 50.0000, 3.1736, 0.5854, 1.0000],
            [50.0000, 2.5000, 0.0000, 50.0000, 3.2972, 0.0000, 1.0000],
            [50.0000, 2.5000, 0.0000, 50.0000, 1.8634, 0.5757, 1.0000],
            [50.0000, 2.5000, 0.0000, 50.0000, 3.2592, 0.3350, 1.0000],
            [60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644],
            [63.0109, -31.0961, -5.8663, 62.8187, -29.7946, -4.0864, 1.2630],
            [61.2901, 3.7196, -5.3901, 61.4292, 2.2480, -4.9620, 1.8731],
            [35.0831, -44.1164, 3.7933, 35.0232, -40.0716, 1.5901, 1.8645],
            [22.7233, 20.0904, -46.6940, 23.0331, 14.9730, -42.5619, 2.0373],
            [36.4612, 47.8580, 18.3852, 36.2715, 50.5065, 21.2231, 1.4146],
            [90.8027, -2.0831, 1.4410, 91.1528, -1.6435, 0.0447, 1.4441],
            [90.9257, -0.5406, -0.9208, 88.6381, -0.8985, -0.7239, 1.5381],
            [6.7747, -0.2908, -2.4247, 5.8714, -0.0985, -2.2286, 0.6377],
            [2.0776, 0.0795, -1.1350, 0.9033, -0.0636, -0.5514, 0.9082],
        ]
        for (i, row) in data.enumerated() {
            let d = CIEDE2000.difference(CIEDE2000.Lab(l: row[0], a: row[1], b: row[2]), CIEDE2000.Lab(l: row[3], a: row[4], b: row[5]))
            XCTAssertEqual(d, row[6], accuracy: 0.0001, "pair \(i + 1)")
        }
    }

    // MARK: Auto-matching (M1-M23)

    private func assertRow(_ row: SlotComparison, _ tray: Int?, _ match: SlotMatch, manual: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(row.tray?.globalId, tray, file: file, line: line)
        XCTAssertEqual(row.match, match, file: file, line: line)
        XCTAssertEqual(row.manual, manual, file: file, line: line)
    }

    func testM1ExactColor() {
        let r = run([need(1, "PLA", "#FF0000")])
        assertRow(r.rows[0], 0, .match); XCTAssertEqual(r.mapping, [0])
    }

    func testM2NearestColor() {
        let r = run([need(1, "PLA", "#EE1111")])
        assertRow(r.rows[0], 1, .match); XCTAssertEqual(r.mapping, [1])
    }

    func testM3NoSimilarColorTakesFirstOfMaterial() {
        let r = run([need(1, "PLA", "#00FF00")])
        assertRow(r.rows[0], 0, .colorDiffers); XCTAssertEqual(r.mapping, [0])
    }

    func testM4NoMaterial() {
        let r = run([need(1, "ABS", "#000000")])
        assertRow(r.rows[0], nil, .mismatch); XCTAssertEqual(r.mapping, [-1])
    }

    func testM5EquivalentNylon() {
        let r = run([need(1, "PA-CF", "#2A2A2A")])
        assertRow(r.rows[0], 128, .match); XCTAssertEqual(r.mapping, [128])
    }

    func testM6TwoSlotsSameColor() {
        let r = run([need(1, "PLA", "#FF0000"), need(2, "PLA", "#FF0000")])
        assertRow(r.rows[0], 0, .match); assertRow(r.rows[1], 1, .match); XCTAssertEqual(r.mapping, [0, 1])
    }

    func testM7TrayInfoIdxNarrows() {
        let r = run([need(1, "PLA", "#0000FF", idx: "GFA00")])
        assertRow(r.rows[0], 0, .colorDiffers); XCTAssertEqual(r.mapping, [0])
    }

    func testM8UniqueTrayInfoIdxWins() {
        let r = run([need(1, "PLA", "#FF0000", idx: "GFA01")])
        assertRow(r.rows[0], 3, .colorDiffers); XCTAssertEqual(r.mapping, [3])
    }

    func testM9SparseSlots() {
        let r = run([need(2, "PLA", "#FF0000"), need(4, "PETG", "#FF0000")])
        XCTAssertEqual(r.rows.map { $0.tray?.globalId }, [0, 2]); XCTAssertEqual(r.mapping, [-1, 0, -1, 2])
    }

    func testM10ManualUnassigned() {
        let r = run([need(1, "PLA", "#FF0000")], manual: [1: -1])
        assertRow(r.rows[0], nil, .unassigned, manual: true); XCTAssertEqual(r.mapping, [-1])
    }

    func testM11ManualOtherMaterial() {
        let r = run([need(1, "PLA", "#FF0000")], manual: [1: 2])
        assertRow(r.rows[0], 2, .mismatch, manual: true); XCTAssertEqual(r.mapping, [2])
        XCTAssertTrue(FilamentAutoMapper.substitutesMaterial(rows: r.rows, opened: nil))
    }

    func testM12SubstitutionAlreadyOnJob() {
        let r = run([need(1, "PLA", "#FF0000")], manual: [1: 2])
        XCTAssertEqual(r.mapping, [2])
        XCTAssertFalse(FilamentAutoMapper.substitutesMaterial(rows: r.rows, opened: [2]))
    }

    func testM13ManualSameMaterial() {
        let r = run([need(1, "PLA", "#FF0000")], manual: [1: 1])
        assertRow(r.rows[0], 1, .match, manual: true); XCTAssertEqual(r.mapping, [1])
    }

    func testM14ManualReservesTray() {
        let r = run([need(1, "PLA", "#FF0000"), need(2, "PLA", "#FF0000")], manual: [2: 0])
        assertRow(r.rows[0], 1, .match); assertRow(r.rows[1], 0, .match, manual: true); XCTAssertEqual(r.mapping, [1, 0])
    }

    func testM15PickOfUnloadedTrayIgnored() {
        let r = run([need(1, "PLA", "#FF0000")], manual: [1: 77])
        assertRow(r.rows[0], 0, .match); XCTAssertEqual(r.mapping, [0])
    }

    private var nozzleTrays: [LoadedSpoolTray] {
        [tray(0, "PLA", "ff0000", idx: "GFA00", remain: 80, extruder: 0), tray(1, "PLA", "f01010", idx: "GFA00", remain: 20, extruder: 1), t2, t3, h, e]
    }

    func testM16NozzleFilter() {
        let r = run([need(1, "PLA", "#FF0000", nozzle: 1)], trays: nozzleTrays)
        assertRow(r.rows[0], 1, .match); XCTAssertEqual(r.mapping, [1])
    }

    func testM17TrackSwitchSkipsNozzleFilter() {
        let r = run([need(1, "PLA", "#FF0000", nozzle: 1)], trays: nozzleTrays, trackSwitch: true)
        assertRow(r.rows[0], 0, .match); XCTAssertEqual(r.mapping, [0])
    }

    func testM18AnyColor() {
        let r = run([need(1, "PLA")])
        assertRow(r.rows[0], 0, .match); XCTAssertEqual(r.mapping, [0])
    }

    func testM19PreferLowest() {
        XCTAssertEqual(run([need(1, "PLA")], setting: true, backup: nil).mapping, [1])
    }

    func testM20TrackedSpoolsFirst() {
        XCTAssertEqual(run([need(1, "PLA")], setting: true, backup: nil, inventory: [3: 100]).mapping, [3])
    }

    func testM21BackupOffDisablesPreferLowest() {
        XCTAssertEqual(run([need(1, "PLA")], setting: true, backup: false).mapping, [0])
    }

    func testM22ExactColorBeatsLowerRemain() {
        XCTAssertEqual(run([need(1, "PLA", "#FF0000")], setting: true, backup: true).mapping, [0])
    }

    func testM23NoTrays() {
        let r = run([need(1, "PLA", "#FF0000"), need(2, "PETG")], trays: [])
        XCTAssertTrue(r.rows.allSatisfy { $0.tray == nil && $0.match == .mismatch })
        XCTAssertNil(r.mapping)
    }

    func testLowestFirstTieOrder() {
        let x = tray(5, "PLA", "", remain: 40)
        let y = tray(128, "PLA", "", remain: 40, ht: true)
        let z = tray(254, "PLA", "", remain: 40, external: true)
        let rack = LoadedSpoolTray(amsId: 0, trayId: 0, isHT: false, isExternal: false, type: "PLA", color: "", globalId: 28,
                                   trayInfoIdx: "", subBrands: "", extruderId: nil, remain: 40, label: "R")
        let w = tray(6, "PLA", "", remain: -1)
        let ordered = FilamentAutoMapper.lowestFirst([w, z, y, rack, x], inventory: [:])
        XCTAssertEqual(ordered.map(\.globalId), [5, 28, 128, 254, 6])
    }

    // MARK: Spool-weight check (D1-D6)

    private let materials: [Int: InventoryRemain.Slot] = [
        0: .init(globalTrayId: 0, materialKey: "PLA", remainingG: 30, extruder: 0),
        1: .init(globalTrayId: 1, materialKey: "PLA", remainingG: 50, extruder: 0),
        2: .init(globalTrayId: 2, materialKey: "PETG", remainingG: 500, extruder: 0),
    ]

    private func rows(_ entries: [(slot: Int, tray: LoadedSpoolTray, grams: Double)]) -> [SlotComparison] {
        entries.map { SlotComparison(need: need($0.slot, $0.tray.type, grams: $0.grams), tray: $0.tray, match: .match, manual: false) }
    }

    private func deficits(_ rows: [SlotComparison], backup: Bool?, disabled: Bool = false) -> [FilamentDeficit] {
        FilamentAutoMapper.deficits(rows: rows, trays: all, slotMaterials: materials, backupOn: backup,
                                    warningsDisabled: disabled, hasMapping: true)
    }

    func testD1SingleTrayShort() {
        let d = deficits(rows([(1, t0, 50)]), backup: false)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.slotLabel, t0.label)
        XCTAssertEqual(d.first?.requiredGrams, 50)
        XCTAssertEqual(d.first?.remainingGrams, 30)
        XCTAssertEqual(d.first?.pooled, false)
        XCTAssertFalse(d.first?.text.isEmpty ?? true)
    }

    func testD2SlotsOnOneTrayAddUp() {
        let d = deficits(rows([(1, t0, 20), (2, t0, 20)]), backup: false)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.requiredGrams, 40)
        XCTAssertEqual(d.first?.remainingGrams, 30)
    }

    func testD3BackupPoolCovers() {
        XCTAssertTrue(deficits(rows([(1, t0, 60)]), backup: true).isEmpty)
    }

    func testD4BackupPoolShort() {
        let d = deficits(rows([(1, t0, 100)]), backup: true)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.slotLabel, t0.label)
        XCTAssertEqual(d.first?.requiredGrams, 100)
        XCTAssertEqual(d.first?.remainingGrams, 80)
        XCTAssertEqual(d.first?.pooled, true)
    }

    func testD5UntrackedTrayNotJudged() {
        XCTAssertTrue(deficits(rows([(1, t3, 900)]), backup: false).isEmpty)
    }

    func testD6WarningsDisabled() {
        XCTAssertTrue(deficits(rows([(1, t0, 50)]), backup: false, disabled: true).isEmpty)
    }

    func testDeficitNeedsMapping() {
        XCTAssertTrue(FilamentAutoMapper.deficits(rows: rows([(1, t0, 50)]), trays: all, slotMaterials: materials,
                                                  backupOn: false, warningsDisabled: false, hasMapping: false).isEmpty)
    }
}
