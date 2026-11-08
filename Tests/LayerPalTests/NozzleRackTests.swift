import XCTest
@testable import LayerPal

final class NozzleRackTests: XCTestCase {
    private func slot(_ id: Int, _ diameter: String?, _ type: String?, color: String? = nil) -> AdvRackSlot {
        AdvRackSlot(id: id, nozzleType: type, nozzleDiameter: diameter, wear: nil, stat: nil, maxTemp: nil,
                    serialNumber: nil, filamentColor: color, filamentId: nil, filamentType: nil)
    }

    private func group(_ diameter: String, _ volume: String, _ color: String = "", onRack: Bool = true) -> RackGroupInfo {
        RackGroupInfo(onRack: onRack, nozzleDiameter: diameter, volumeType: volume, filamentColor: color)
    }

    // MARK: isRackModel

    func testIsRackModel() {
        for name in ["H2C", "h2c", "O1C", "O1C2", "O1-C2"] { XCTAssertTrue(NozzleRack.isRackModel(name), name) }
        for name in ["H3C", "H2D", ""] { XCTAssertFalse(NozzleRack.isRackModel(name), name) }
        XCTAssertFalse(NozzleRack.isRackModel(nil))
    }

    // MARK: byPosition (P1-P5)

    private func plain(_ ids: [Int]) -> [AdvRackSlot] { ids.map { slot($0, "0.4", "HS01") } }

    func testP1FullRack() {
        let map = NozzleRack.byPosition(plain([16, 17, 18, 19, 20, 21]) + [slot(0, "0.4", "HS01"), slot(1, "0.4", "HS01")])
        XCTAssertEqual(map.mapValues(\.id), [1: 16, 2: 17, 3: 18, 4: 19, 5: 20, 6: 21])
    }

    func testP2OneGapFilledFromCarriage() {
        let map = NozzleRack.byPosition(plain([16, 18, 19, 20, 21]) + [slot(0, "0.4", "HH01")])
        XCTAssertEqual(map[2]?.id, 0)
        XCTAssertEqual(map[1]?.id, 16)
        XCTAssertEqual(map[6]?.id, 21)
        XCTAssertEqual(map.count, 6)
    }

    func testP3TwoGapsStayMissing() {
        let map = NozzleRack.byPosition(plain([16, 19, 20, 21]) + [slot(0, "0.4", "HS01")])
        XCTAssertNil(map[2]); XCTAssertNil(map[3]); XCTAssertEqual(map.count, 4)
    }

    func testP4EmptyCarriageNotPlaced() {
        let map = NozzleRack.byPosition(plain([16, 18, 19, 20, 21]) + [slot(0, "", "")])
        XCTAssertNil(map[2]); XCTAssertEqual(map.count, 5)
    }

    func testP5ForeignIds() {
        XCTAssertTrue(NozzleRack.byPosition(plain([15, 22, 1])).isEmpty)
    }

    // MARK: isEligible (E1-E13)

    func testEligibility() {
        let cases: [(AdvRackSlot?, RackGroupInfo, Bool, String)] = [
            (slot(16, "0.40", "HS01"), group("0.4", "Standard"), true, "E1"),
            (slot(16, "0.4", "HH01"), group("0.4", "Standard"), false, "E2"),
            (slot(16, "0.4", "HH01"), group("0.4", "High Flow"), true, "E3"),
            (slot(16, "0.4", "HS01"), group("0.4", "high flow"), false, "E4"),
            (slot(16, "0.4", ""), group("0.4", "High Flow"), true, "E5"),
            (slot(16, "0.4", "HH01"), group("0.4", ""), true, "E6"),
            (slot(16, "0.6", "HS01"), group("0.4", "Standard"), false, "E7"),
            (nil, group("0.4", "Standard"), false, "E8"),
            (slot(16, "", ""), group("0.4", "Standard"), false, "E9"),
            (slot(16, "", "HS01"), group("0.4", "Standard"), false, "E10"),
            (slot(16, "0.4", "HS01"), group("", "Standard"), false, "E11"),
            (slot(16, "0.404", "HS01"), group("0.4", "Standard"), true, "E12"),
            (slot(16, "0.41", "HS01"), group("0.4", "Standard"), false, "E13"),
        ]
        for (s, g, expected, name) in cases {
            XCTAssertEqual(NozzleRack.isEligible(s, for: g), expected, name)
        }
    }

    // MARK: autoAssign (A1-A10)

    private var fixture: [AdvRackSlot] {
        [
            slot(16, "0.4", "HS01", color: "FF0000FF"),
            slot(17, "0.4", "HH01", color: "00FF00FF"),
            slot(18, "0.6", "HS01", color: ""),
            slot(19, "0.4", "HS01", color: "0000FFFF"),
            slot(20, "", "", color: ""),
            slot(21, "0.4", "HS01", color: "00FF00FF"),
            slot(0, "", ""),
        ]
    }

    private var groups: [Int: RackGroupInfo] {
        [
            0: group("0.4", "Standard", onRack: false),
            1: group("0.4", "Standard", "#0000FF"),
            2: group("0.4", "Standard", "#FFFF00"),
            3: group("0.4", "High Flow", "#123456"),
            4: group("0.6", "Standard"),
            5: group("0.8", "Standard"),
            7: group("0.4", "Standard", "#00ff00"),
        ]
    }

    private func assign(_ ids: [Int], pinned: [Int: Int] = [:]) -> [Int: Int]? {
        NozzleRack.autoAssign(fixture, groups: groups.filter { ids.contains($0.key) }, pinned: pinned)
    }

    func testA1() { XCTAssertEqual(assign([1, 2, 3]), [1: 4, 2: 1, 3: 2]) }
    func testA2() { XCTAssertEqual(assign([1, 2, 3], pinned: [2: 6]), [1: 4, 2: 6, 3: 2]) }
    func testA3() { XCTAssertNil(assign([1], pinned: [1: 2])) }
    func testA4() { XCTAssertNil(assign([1, 2], pinned: [1: 4, 2: 4])) }
    func testA5() { XCTAssertEqual(assign([1, 2, 4]), [1: 4, 2: 1, 4: 3]) }
    func testA6() { XCTAssertNil(assign([5])) }
    func testA7() { XCTAssertEqual(assign([7]), [7: 6]) }
    func testA8() { XCTAssertEqual(assign([0, 1], pinned: [0: 5]), [1: 4]) }
    func testA9() { XCTAssertEqual(assign([0]), [:]) }
    func testA10() { XCTAssertEqual(assign([1, 2, 3, 7]), [1: 4, 2: 1, 3: 2, 7: 6]) }

    // MARK: options

    func testOptions() {
        let options = NozzleRack.options(fixture, for: groups[1]!)
        XCTAssertEqual(options.map(\.position), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(options.filter(\.eligible).map(\.position), [1, 4, 6])
        XCTAssertTrue(options.filter(\.eligible).allSatisfy { $0.reason == nil })
        let two = options[1].reason ?? ""
        XCTAssertTrue(two.contains("0.4") && two.contains("HH01") && two.contains("Standard"), two)
        XCTAssertNotNil(options[2].reason)
        XCTAssertNotEqual(options[2].reason, options[4].reason)
        XCTAssertNotNil(options[4].reason)
        XCTAssertEqual(options[0].diameter, "0.4")
        XCTAssertEqual(options[4].diameter, "")
    }
}
