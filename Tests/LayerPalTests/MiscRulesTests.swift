import UIKit
import XCTest
@testable import LayerPal

final class MiscRulesTests: XCTestCase {
    // MARK: §5 nozzle text

    func testNozzleText() {
        XCTAssertEqual(AdvNozzleText.material("hardened_steel"), "Hardened steel")
        XCTAssertEqual(AdvNozzleText.material("stainless_steel"), "Stainless steel")
        XCTAssertEqual(AdvNozzleText.material("HS01"), "Hardened steel")
        XCTAssertEqual(AdvNozzleText.flow("HS01"), "Standard flow")
        XCTAssertEqual(AdvNozzleText.material("HH00"), "Stainless steel")
        XCTAssertEqual(AdvNozzleText.flow("HH00"), "High flow")
        XCTAssertEqual(AdvNozzleText.material("HH05"), "Tungsten carbide")
        XCTAssertEqual(AdvNozzleText.material("05"), "Tungsten carbide")
        XCTAssertNil(AdvNozzleText.flow("05"))
        XCTAssertEqual(AdvNozzleText.material("brass"), "brass")
        XCTAssertNil(AdvNozzleText.flow("brass"))
        XCTAssertNil(AdvNozzleText.material(""))
        XCTAssertNil(AdvNozzleText.flow(""))
        XCTAssertNil(AdvNozzleText.material(nil))
        XCTAssertNil(AdvNozzleText.flow(nil))
    }

    // MARK: §6 model tables

    private func printer(_ model: String?) throws -> Printer {
        var json: [String: Any] = ["id": 1, "name": "P"]
        if let model { json["model"] = model }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Printer.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testModelTables() throws {
        XCTAssertEqual(try printer("O1D").displayModel, "H2D")
        XCTAssertEqual(try printer("Z9").displayModel, "Z9")
        func discovered(_ model: String) -> OpsDiscoveredPrinter? {
            OpsDiscoveredPrinter(json: .object(["serial": .string("S"), "ip_address": .string("10.0.0.2"), "model": .string(model)]))
        }
        XCTAssertEqual(discovered("O1D")?.pickerModel, "H2D")
        XCTAssertEqual(discovered("X1C")?.pickerModel, "X1C")
        XCTAssertEqual(discovered("Z9")?.pickerModel, "")
        XCTAssertTrue(AdvModels.zMovesToolhead("A1 mini"))
        XCTAssertTrue(AdvModels.zMovesToolhead("N2S"))
        XCTAssertFalse(AdvModels.zMovesToolhead("X1C"))
        XCTAssertTrue(AdvModels.isRack("H2C"))
        XCTAssertTrue(AdvModels.isToolChangerUnverified("H3C"))
        XCTAssertFalse(AdvModels.isRack("H3C"))
        // Every display name the table produces is a model the add-printer form offers.
        for name in Set(Printer.modelNames.values) { XCTAssertTrue(AdminPrinterModels.all.contains(name), name) }
    }

    // MARK: §7 HMS labels

    func testHMSLabels() {
        XCTAssertEqual(HMSActionLabel.label("SOME_NEW_KEY"), "Some New Key")
        XCTAssertTrue(HMSActionLabel.isStop("ABORT"))
        XCTAssertFalse(HMSActionLabel.isStop("CANCLE"))
        XCTAssertEqual(HMSActionLabel.labels.count, 32)
        XCTAssertNotNil(HMSActionLabel.labels["RESUME_PRINTING_PROBELM_SOLVED"])
    }

    // MARK: §9 drying

    func testDryingResolve() {
        let cases: [(String, String)] = [
            ("pla", "PLA"), ("PETG", "PETG"), ("PLA-S", "PLA"), ("PETG-CF", "PETG"), ("PA6-CF", "PA"),
            ("PAHT-CF", "PA"), ("Nylon", "PA"), ("ABS-GF", "ABS"), ("PEEK", "PLA"), ("", "PLA"),
        ]
        for (input, expected) in cases { XCTAssertEqual(DryingSheet.resolve(input), expected, input) }
        XCTAssertEqual(DryingSheet.presets.count, 8)
        let tpu = DryingSheet.presets.first { $0.0 == "TPU" }?.1
        XCTAssertEqual(tpu?.n3s, 75)
        XCTAssertEqual(tpu?.n3sHours, 18)
    }

    // MARK: §11 duration bins

    private func run(seconds: Int, status: String = "completed") -> InsRun {
        InsRun(printerId: 1, printName: "Part", printTimeSeconds: nil, actualTimeSeconds: seconds, filamentUsedGrams: 10,
               filamentType: "PLA", filamentColor: nil, status: status, startedAt: nil, completedAt: nil, cost: 1,
               energyKwh: nil, energyCost: nil, wearCost: nil, createdAt: "2026-01-02T10:00:00Z")
    }

    func testDurationBins() {
        let first = StatsAggregator.durationBin(seconds: 0)
        XCTAssertEqual(first, 0)
        let agg = StatsAggregator.aggregate([run(seconds: 0), run(seconds: 360_000), run(seconds: 5_000), run(seconds: 99, status: "failed")],
                                            start: nil, end: nil)
        XCTAssertEqual(agg.durations.first?.count, 1)
        XCTAssertEqual(agg.durations.last?.count, 1)
        XCTAssertEqual(agg.durations.reduce(0) { $0 + $1.count }, 3, "each completed run lands in exactly one bin")
        XCTAssertEqual(agg.durations.map(\.order), Array(0..<agg.durations.count))
        XCTAssertEqual(agg.records.first { $0.kind == .longest }?.detail, "Part")
        XCTAssertNotNil(agg.records.first { $0.kind == .busiestDay })
        XCTAssertNotNil(Double(agg.records.first { $0.kind == .costliest }?.value ?? "x"))
    }

    // MARK: §12 farm state

    private func status(_ json: [String: Any]) throws -> PrinterStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrinterStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testFarmState() throws {
        XCTAssertEqual(FarmState(nil), .offline)
        XCTAssertEqual(FarmState(try status(["connected": false, "state": "RUNNING"])), .offline)
        XCTAssertEqual(FarmState(try status(["connected": true, "state": "RUNNING",
                                             "hms_errors": [["code": "1", "full_code": "0300010000010001", "severity": 2]]])), .printing)
        XCTAssertEqual(FarmState(try status(["connected": true, "state": "IDLE",
                                             "hms_errors": [["code": "1", "full_code": "0300010000010001", "severity": 1]]])), .error)
        XCTAssertEqual(FarmState(try status(["connected": true, "state": "FAILED"])), .finished)
        XCTAssertEqual(FarmState(try status(["connected": true, "state": "PREPARE"])), .printing)
        XCTAssertEqual(FarmState(try status(["connected": true, "state": "PAUSE"])), .paused)
    }

    // MARK: §13 screenshot

    private func png(_ width: CGFloat, _ height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
            // Noise-like stripes so the JPEG isn't trivially small.
            for x in stride(from: 0, to: Int(width), by: 7) {
                UIColor(hue: CGFloat(x % 360) / 360, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 7, height: height))
            }
        }
    }

    func testScreenshotDownscale() throws {
        let big = try XCTUnwrap(BugScreenshot(data: png(4000, 3000)))
        let jpeg = try XCTUnwrap(Data(base64Encoded: big.base64))
        XCTAssertLessThanOrEqual(jpeg.count, BugScreenshot.maxBytes)
        XCTAssertLessThanOrEqual(max(big.preview.size.width, big.preview.size.height) * big.preview.scale, BugScreenshot.maxDimension)
        XCTAssertEqual(big.preview.size.width / big.preview.size.height, 4.0 / 3.0, accuracy: 0.01)

        let small = try XCTUnwrap(BugScreenshot(data: png(100, 50)))
        XCTAssertEqual(small.preview.size.width * small.preview.scale, 100)
        XCTAssertEqual(small.preview.size.height * small.preview.scale, 50)

        XCTAssertNil(BugScreenshot(data: Data("not an image".utf8)))
    }
}
