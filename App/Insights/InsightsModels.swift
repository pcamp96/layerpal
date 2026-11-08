import Foundation

// Models for the phase 4A insights screens: archive stats, print log, scheduled drying,
// pending uploads and the two history routes (Bambuddy 1.3.0).

/// GET /archives/stats. Decoded WITHOUT a key strategy: the dictionaries are keyed by printer id,
/// filament type and failure reason, which must not be rewritten.
struct InsStats: Decodable, Sendable {
    var totalPrints = 0
    var successfulPrints = 0
    var failedPrints = 0
    var cancelledPrints = 0
    var totalPrintTimeHours = 0.0
    var totalFilamentGrams = 0.0
    var totalCost = 0.0
    var printsByFilamentType: [String: Int] = [:]
    var printsByPrinter: [String: Int] = [:]
    var printerNames: [String: String] = [:]
    var averageTimeAccuracy: Double?
    var timeAccuracyByPrinter: [String: Double] = [:]
    var totalEnergyKwh = 0.0
    var totalEnergyCost = 0.0
    var totalWearCost = 0.0
    var energyDataWarmingUp = false

    enum CodingKeys: String, CodingKey {
        case totalPrints = "total_prints", successfulPrints = "successful_prints", failedPrints = "failed_prints"
        case cancelledPrints = "cancelled_prints", totalPrintTimeHours = "total_print_time_hours"
        case totalFilamentGrams = "total_filament_grams", totalCost = "total_cost"
        case printsByFilamentType = "prints_by_filament_type", printsByPrinter = "prints_by_printer"
        case printerNames = "printer_names", averageTimeAccuracy = "average_time_accuracy"
        case timeAccuracyByPrinter = "time_accuracy_by_printer", totalEnergyKwh = "total_energy_kwh"
        case totalEnergyCost = "total_energy_cost", totalWearCost = "total_wear_cost"
        case energyDataWarmingUp = "energy_data_warming_up"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalPrints = (try? c.decode(Int.self, forKey: .totalPrints)) ?? 0
        successfulPrints = (try? c.decode(Int.self, forKey: .successfulPrints)) ?? 0
        failedPrints = (try? c.decode(Int.self, forKey: .failedPrints)) ?? 0
        cancelledPrints = (try? c.decode(Int.self, forKey: .cancelledPrints)) ?? 0
        totalPrintTimeHours = (try? c.decode(Double.self, forKey: .totalPrintTimeHours)) ?? 0
        totalFilamentGrams = (try? c.decode(Double.self, forKey: .totalFilamentGrams)) ?? 0
        totalCost = (try? c.decode(Double.self, forKey: .totalCost)) ?? 0
        printsByFilamentType = (try? c.decode([String: Int].self, forKey: .printsByFilamentType)) ?? [:]
        printsByPrinter = (try? c.decode([String: Int].self, forKey: .printsByPrinter)) ?? [:]
        printerNames = (try? c.decode([String: String].self, forKey: .printerNames)) ?? [:]
        averageTimeAccuracy = try? c.decode(Double.self, forKey: .averageTimeAccuracy)
        timeAccuracyByPrinter = (try? c.decode([String: Double].self, forKey: .timeAccuracyByPrinter)) ?? [:]
        totalEnergyKwh = (try? c.decode(Double.self, forKey: .totalEnergyKwh)) ?? 0
        totalEnergyCost = (try? c.decode(Double.self, forKey: .totalEnergyCost)) ?? 0
        totalWearCost = (try? c.decode(Double.self, forKey: .totalWearCost)) ?? 0
        energyDataWarmingUp = (try? c.decode(Bool.self, forKey: .energyDataWarmingUp)) ?? false
    }
}

/// GET /archives/analysis/failures (only the fields the Stats page shows).
struct InsFailureAnalysis: Decodable, Sendable {
    var totalPrints = 0
    var failedPrints = 0
    var failureRate = 0.0
    var failuresByReason: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case totalPrints = "total_prints", failedPrints = "failed_prints", failureRate = "failure_rate"
        case failuresByReason = "failures_by_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalPrints = (try? c.decode(Int.self, forKey: .totalPrints)) ?? 0
        failedPrints = (try? c.decode(Int.self, forKey: .failedPrints)) ?? 0
        failureRate = (try? c.decode(Double.self, forKey: .failureRate)) ?? 0
        failuresByReason = (try? c.decode([String: Int].self, forKey: .failuresByReason)) ?? [:]
    }
}

/// One row of GET /archives/slim. Dates stay strings (see `FastDate`).
struct InsRun: Decodable, Sendable {
    let printerId: Int?
    let printName: String?
    let printTimeSeconds: Int?
    let actualTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let filamentType: String?
    let filamentColor: String?
    let status: String
    let startedAt: String?
    let completedAt: String?
    let cost: Double?
    let energyKwh: Double?
    let energyCost: Double?
    let wearCost: Double?
    let createdAt: String?
}

struct InsUser: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
}

// MARK: Print log

struct InsPrintLogPage: Decodable {
    let items: [InsPrintLogEntry]
    let total: Int
    let deletedArchiveIds: [Int]?
}

struct InsPrintLogEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let archiveId: Int?
    let printName: String?
    let plateId: Int?
    let printerName: String?
    let printerId: Int?
    let status: String
    let startedAt: Date?
    let completedAt: Date?
    let durationSeconds: Int?
    let filamentType: String?
    let filamentColor: String?
    let filamentUsedGrams: Double?
    let cost: Double?
    let energyKwh: Double?
    let energyCost: Double?
    let wearCost: Double?
    let failureReason: String?
    let userVerdict: String?
    let quantity: Int?
    let notes: String?
    let thumbnailPath: String?
    let createdById: Int?
    let createdByUsername: String?
    let createdAt: Date?

    var title: String { printName?.isEmpty == false ? printName! : "Untitled print" }
    var whenText: Date? { startedAt ?? createdAt }
    var totalCost: Double? {
        let parts = [cost, energyCost, wearCost].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// Status values the print-log endpoints use.
enum InsStatus {
    static let all = ["completed", "failed", "stopped", "cancelled", "skipped"]

    static func label(_ status: String) -> String {
        switch status {
        case "completed": "Completed"
        case "failed": "Failed"
        case "aborted": "Aborted"
        case "stopped": "Stopped"
        case "cancelled": "Cancelled"
        case "skipped": "Skipped"
        default: status.capitalized
        }
    }
}

// MARK: Pending uploads

struct InsPendingUpload: Decodable, Identifiable, Hashable {
    let id: Int
    let filename: String
    let displayName: String
    let fileSize: Int
    let sourceIp: String?
    let status: String
    let tags: String?
    let notes: String?
    let projectId: Int?
    let uploadedAt: Date?
}

// MARK: Scheduled drying

struct InsScheduledDrying: Decodable, Identifiable, Hashable {
    let id: Int
    let printerId: Int
    let amsId: Int
    let temp: Int
    let durationHours: Int
    let filament: String
    let rotateTray: Bool
    let startAfter: Date?
    let status: String
    let waitingReason: String?
    let errorMessage: String?
    let errorCode: String?
    let startedAt: Date?

    /// `waiting_reason` values the scheduled-drying endpoint sends.
    var waitingText: String? {
        switch waitingReason {
        case "ams_power_required": "Needs external power"
        case "ams_retract_filament": "Retract filament first"
        case "ams_blocked": "Can't dry now"
        case "ams_not_found": "AMS not found"
        case "printer_offline": "Printer offline"
        case "printer_busy": "Printer busy"
        case "already_drying": "Already drying"
        case "interrupted": "Interrupted"
        default: nil
        }
    }

    /// `error_code` values the scheduled-drying endpoint sends; unknown codes fall back to the server's message.
    var failedText: String {
        switch errorCode {
        case "screen_only": "This printer only dries from its screen"
        case "unsupported": "Drying isn't supported on this printer or firmware"
        case "did_not_start": "The AMS didn't start drying"
        default: errorMessage?.isEmpty == false ? errorMessage! : "Unknown error"
        }
    }
}

// MARK: Sensor history

struct InsSensorHistory: Decodable {
    let printerId: Int
    let series: [InsHeaterSeries]
}

struct InsHeaterSeries: Decodable, Identifiable {
    let sensorKind: String
    let data: [InsHeaterPoint]
    let minValue: Double?
    let maxValue: Double?
    let avgValue: Double?
    var id: String { sensorKind }

    var title: String {
        switch sensorKind {
        case "nozzle": "Nozzle"
        case "nozzle_2": "Nozzle 2"
        case "bed": "Bed"
        case "chamber": "Chamber"
        default: sensorKind.capitalized
        }
    }
}

struct InsHeaterPoint: Decodable, Identifiable {
    let recordedAt: Date
    let value: Double?
    let target: Double?
    var id: Date { recordedAt }
}

struct InsAMSHistory: Decodable {
    let printerId: Int
    let amsId: Int
    let data: [InsAMSPoint]
    let minHumidity: Double?
    let maxHumidity: Double?
    let avgHumidity: Double?
    let minTemperature: Double?
    let maxTemperature: Double?
    let avgTemperature: Double?
}

struct InsAMSPoint: Decodable, Identifiable {
    let recordedAt: Date
    let humidity: Double?
    let humidityRaw: Double?
    let temperature: Double?
    var id: Date { recordedAt }
}

// MARK: Date parsing

/// Allocation-free ISO 8601 parser for the stats rows: the shared decoder builds three formatters per
/// date, which is far too slow for tens of thousands of rows. Accepts "YYYY-MM-DDTHH:MM:SS", optional
/// fraction, optional "Z" / "+hh:mm" offset; no offset means UTC (Bambuddy stores naive UTC).
enum FastDate {
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        var s = string
        return s.withUTF8 { b -> Date? in
            guard b.count >= 19 else { return nil }
            func num(_ from: Int, _ len: Int) -> Int? {
                var v = 0
                for i in from ..< from + len {
                    let d = Int(b[i]) - 48
                    if d < 0 || d > 9 { return nil }
                    v = v * 10 + d
                }
                return v
            }
            guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
                  let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
            // Days from civil date (Howard Hinnant).
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            var seconds = Double(days * 86400 + h * 3600 + mi * 60 + sec)
            var i = 19
            if i < b.count, b[i] == 46 { // fraction
                i += 1
                var scale = 0.1
                while i < b.count, b[i] >= 48, b[i] <= 57 {
                    seconds += Double(b[i] - 48) * scale
                    scale /= 10
                    i += 1
                }
            }
            if i + 3 <= b.count, b[i] == 43 || b[i] == 45 {
                let sign: Double = b[i] == 43 ? 1 : -1
                if let oh = num(i + 1, 2) {
                    let om = (i + 6 <= b.count ? num(i + 4, 2) : nil) ?? 0
                    seconds -= sign * Double(oh * 3600 + om * 60)
                }
            }
            return Date(timeIntervalSince1970: seconds)
        }
    }
}

/// The server's currency code (GET /settings/), cached so every insights screen formats money alike.
enum InsCurrency {
    static let key = "insCurrency"

    static var code: String {
        UserDefaults.standard.string(forKey: key) ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// Returns the fresh code, or the cached/device one when the user can't read settings.
    @discardableResult
    static func refresh() async -> String {
        if let fresh = await APIClient.shared.insCurrency(), fresh.count == 3 {
            UserDefaults.standard.set(fresh.uppercased(), forKey: key)
        }
        return code
    }
}
