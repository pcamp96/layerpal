import XCTest
@testable import LayerPal

final class PresetNamingTests: XCTestCase {
    func testCleanName() {
        XCTAssertEqual(PresetNaming.cleanName("Bambu PLA Basic @BBL X1C 0.4 nozzle"), "Bambu PLA Basic")
        XCTAssertEqual(PresetNaming.cleanName("Generic PETG"), "Generic PETG")
    }

    func testMaterial() {
        let cases: [(String, String)] = [
            ("Bambu PLA Basic @BBL X1C", "PLA"),
            ("Generic PETG HF", "PETG"),
            ("Bambu Support for PLA/PETG @BBL H2D", "PLA"),
            ("Bambu Support For ABS", "ABS"),
            ("Polymaker PolyLite ASA", "ASA"),
            ("Bambu PLA-CF", "PLA"),
            ("Generic PCTG", "PCTG"),
            ("Overture TPU 95A", "TPU"),
            ("eSUN ePA-CF", "ePA-CF"),
            ("Mystery", "Mystery"),
        ]
        for (name, expected) in cases { XCTAssertEqual(PresetNaming.material(of: name), expected, name) }
    }

    func testKnownMaterialsListed() {
        for m in ["PLA", "PETG", "PCTG", "ABS", "ASA", "TPU", "PC", "PA", "NYLON", "PVA", "HIPS", "PP", "PET"] {
            XCTAssertTrue(PresetNaming.materials.contains(m), m)
        }
    }

    func testNozzleRange() {
        for m in ["PLA", "PETG", "PCTG", "ABS", "ASA", "PC", "PA", "PA12", "PAHT-CF", "NYLON", "TPU", "PVA", "HIPS", "PP", "PE", "WOOD", ""] {
            let r = PresetNaming.nozzleRange(m)
            XCTAssertTrue(r.min >= 150 && r.max <= 350 && r.min < r.max, m)
        }
        XCTAssertEqual(PresetNaming.nozzleRange("WOOD").min, PresetNaming.nozzleRange("PLA").min)
        XCTAssertEqual(PresetNaming.nozzleRange("PLA-CF").max, PresetNaming.nozzleRange("PLA").max)
        XCTAssertEqual(PresetNaming.nozzleRange("PA12").min, PresetNaming.nozzleRange("PA").min)
        XCTAssertNotEqual(PresetNaming.nozzleRange("PCTG").min, PresetNaming.nozzleRange("PC").min)
    }

    func testGenericId() {
        XCTAssertEqual(PresetNaming.genericId(for: "pla"), "GFL99")
        XCTAssertEqual(PresetNaming.genericId(for: "PETG-CF"), "GFG98")
        XCTAssertEqual(PresetNaming.genericId(for: "ABS-CF"), "GFB99")
        XCTAssertEqual(PresetNaming.genericId(for: "PLA+"), "GFL99")
        XCTAssertEqual(PresetNaming.genericId(for: "PETG-HF"), "GFG99")
        XCTAssertEqual(PresetNaming.genericId(for: "WOOD"), "")
        XCTAssertEqual(PresetNaming.genericId(for: "NYLON"), "GFN99")
    }

    // MARK: Bambu Cloud ids (§4)

    func testFilamentIdFromSetting() {
        let cases: [(String, String)] = [
            ("GFSA00_02", "GFA00"), ("GFSA00", "GFA00"), ("GFSL99_01", "GFL99"),
            ("GFSNLS03_04", "GFSNL03"), ("GFSNL03", "GFSNL03"), ("GFS00", "GFS00"),
            ("GFS01_00", "GFS01"), ("PFUS9f8e7d", "PFUS9f8e7d"), ("", ""),
        ]
        for (input, expected) in cases { XCTAssertEqual(CloudPresetIds.filamentId(fromSetting: input), expected, input) }
    }

    func testCloudFilamentId() async {
        var asked = false
        let a = await CloudPresetIds.filamentId(listId: "GFA05", settingId: "GFSA00_01", sessionReady: true) { asked = true; return "X" }
        XCTAssertEqual(a, "GFA05")
        XCTAssertFalse(asked, "Bambu presets don't need a detail lookup")
        let b = await CloudPresetIds.filamentId(listId: "", settingId: "GFSB50_02", sessionReady: true) { nil }
        XCTAssertEqual(b, "GFB50")
        let c = await CloudPresetIds.filamentId(listId: "", settingId: "PFUSabc123", sessionReady: false) { "GFL99" }
        XCTAssertEqual(c, "")
        let d = await CloudPresetIds.filamentId(listId: "", settingId: "PFUSabc123", sessionReady: true) { "GFL99" }
        XCTAssertEqual(d, "GFL99")
    }
}
