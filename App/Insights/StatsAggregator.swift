import Foundation

// Client-side aggregation of GET /archives/slim rows: charts, a duration histogram and record tiles.
// Everything here is nonisolated and value-typed so tens of thousands of rows are crunched off the main actor.

enum StatsPreset: String, CaseIterable, Identifiable {
    case today, last7, last30, last90, year, all, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .last7: "7 days"
        case .last30: "30 days"
        case .last90: "90 days"
        case .year: "This year"
        case .all: "All time"
        case .custom: "Custom"
        }
    }
}

struct StatsRange: Hashable {
    var preset: StatsPreset = .last7
    var customFrom = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    var customTo = Date()

    /// Local calendar days as YYYY-MM-DD; the stats route reads them in the `tz` it is given.
    var days: (from: String?, to: String?) {
        let cal = Calendar.current
        let now = Date()
        func f(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        }
        func ago(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now) ?? now }
        switch preset {
        case .today: return (f(now), f(now))
        case .last7: return (f(ago(6)), f(now))
        case .last30: return (f(ago(29)), f(now))
        case .last90: return (f(ago(89)), f(now))
        case .year: return (f(cal.date(from: DateComponents(year: cal.component(.year, from: now), month: 1, day: 1)) ?? now), f(now))
        case .all: return (nil, nil)
        case .custom:
            let lo = min(customFrom, customTo), hi = max(customFrom, customTo)
            return (f(lo), f(hi))
        }
    }

    /// Start of the first day and end of the last, for choosing a bucket size.
    var bounds: (Date?, Date?) {
        let cal = Calendar.current
        switch preset {
        case .all: return (nil, nil)
        case .custom:
            return (cal.startOfDay(for: min(customFrom, customTo)), cal.startOfDay(for: max(customFrom, customTo)).addingTimeInterval(86399))
        default:
            let d = days
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let lo = d.from.flatMap { fmt.date(from: $0) }
            return (lo, Date())
        }
    }
}

enum Outcome: String, CaseIterable, Identifiable, Sendable {
    case completed = "Completed", failed = "Failed", cancelled = "Cancelled"
    var id: String { rawValue }

    /// slim `status` -> bucket: completed; failed/aborted; stopped/cancelled/skipped (cancelled never drags the success rate).
    static func from(_ status: String) -> Outcome? {
        switch status {
        case "completed": .completed
        case "failed", "aborted": .failed
        case "stopped", "cancelled", "skipped": .cancelled
        default: nil
        }
    }
}

struct OutcomePoint: Identifiable, Sendable {
    let date: Date
    let outcome: Outcome
    let count: Int
    var id: String { "\(date.timeIntervalSince1970)-\(outcome.rawValue)" }
}

struct RatePoint: Identifiable, Sendable {
    let date: Date
    let rate: Double
    let total: Int
    var id: Date { date }
}

struct PrinterHoursPoint: Identifiable, Sendable {
    let printerId: Int?
    let hours: Double
    let prints: Int
    var id: Int { printerId ?? -1 }
}

struct MaterialPoint: Identifiable, Sendable {
    let name: String
    let grams: Double
    let prints: Int
    var id: String { name }
}

struct ColorPoint: Identifiable, Sendable {
    let hex: String
    let grams: Double
    let prints: Int
    var id: String { hex }
}

struct CostPoint: Identifiable, Sendable {
    let date: Date
    let kind: String
    let amount: Double
    var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
}

struct HeatCell: Identifiable, Sendable {
    let weekday: Int // 0 = Monday
    let hour: Int
    let count: Int
    var id: Int { weekday * 24 + hour }
}

struct DurationBin: Identifiable, Sendable {
    let label: String
    let order: Int
    let count: Int
    var id: Int { order }
}

struct RecordItem: Identifiable, Sendable {
    enum Kind: Sendable { case longest, heaviest, costliest, busiestDay }
    let kind: Kind
    let value: String
    let detail: String?
    var id: String { "\(kind)" }
}

struct StatsAggregate: Sendable {
    var unit: Calendar.Component = .day
    var rowCount = 0
    var outcomes: [OutcomePoint] = []
    var rates: [RatePoint] = []
    var printers: [PrinterHoursPoint] = []
    var materials: [MaterialPoint] = []
    var colors: [ColorPoint] = []
    var costs: [CostPoint] = []
    var heat: [HeatCell] = []
    var durations: [DurationBin] = []
    var records: [RecordItem] = []
    // Totals recomputed from the rows, used when /archives/stats is not available to the user.
    var total = 0
    var completed = 0
    var failed = 0
    var cancelled = 0
    var seconds = 0
    var grams = 0.0
    var filamentCost = 0.0
    var energyKwh = 0.0
    var energyCost = 0.0
    var wearCost = 0.0
}

enum StatsAggregator {
    /// Histogram buckets for completed print durations: lower bound in seconds and label. The last one
    /// is open-ended, so every duration from 0 up lands in exactly one bucket.
    private static let durationBins: [(from: Int, label: String)] = [
        (0, "< 30 min"), (1_800, "30 min-1 h"), (3_600, "1-2 h"), (7_200, "2-4 h"),
        (14_400, "4-8 h"), (28_800, "8-16 h"), (57_600, "16 h+"),
    ]

    /// Index of the bucket a duration falls in.
    static func durationBin(seconds: Int) -> Int {
        durationBins.lastIndex { seconds >= $0.from } ?? 0
    }


    static func aggregate(_ runs: [InsRun], start: Date?, end: Date?) -> StatsAggregate {
        var out = StatsAggregate()
        out.rowCount = runs.count
        guard !runs.isEmpty else { return out }
        let cal = Calendar.current

        // Parse once.
        let dates: [Date?] = runs.map { FastDate.parse($0.createdAt) ?? FastDate.parse($0.completedAt) ?? FastDate.parse($0.startedAt) }
        let known = dates.compactMap { $0 }
        let lo = start ?? known.min() ?? Date()
        let hi = end ?? known.max() ?? Date()
        let spanDays = hi.timeIntervalSince(lo) / 86400
        let unit: Calendar.Component = spanDays <= 2 ? .hour : (spanDays <= 45 ? .day : (spanDays <= 200 ? .weekOfYear : .month))
        out.unit = unit

        var bucketCache: [Int: Date] = [:]
        func bucket(_ d: Date) -> Date {
            let key = Int(d.timeIntervalSince1970) / 900
            if let hit = bucketCache[key] { return hit }
            let v = cal.dateInterval(of: unit, for: d)?.start ?? d
            bucketCache[key] = v
            return v
        }

        struct Counts { var completed = 0, failed = 0, cancelled = 0 }
        var perBucket: [Date: Counts] = [:]
        var costBucket: [Date: (f: Double, e: Double, w: Double)] = [:]
        var printerAgg: [Int: (seconds: Int, prints: Int)] = [:]
        var unknownPrinter = (seconds: 0, prints: 0)
        var materialAgg: [String: (grams: Double, prints: Int)] = [:]
        var colorAgg: [String: (grams: Double, prints: Int)] = [:]
        var heat = [Int](repeating: 0, count: 7 * 24)
        var binCounts = [Int](repeating: 0, count: durationBins.count)
        var longest: (seconds: Int, name: String?)?
        var heaviest: (grams: Double, name: String?)?
        var costliest: (amount: Double, name: String?)?
        var perDay: [Date: Int] = [:]

        for (index, run) in runs.enumerated() {
            let outcome = Outcome.from(run.status)
            let seconds = max(0, run.actualTimeSeconds ?? 0)
            let grams = run.filamentUsedGrams ?? 0
            let filamentCost = run.cost ?? 0, energyCost = run.energyCost ?? 0, wearCost = run.wearCost ?? 0

            out.total += 1
            switch outcome {
            case .completed: out.completed += 1
            case .failed: out.failed += 1
            case .cancelled: out.cancelled += 1
            case nil: break
            }
            out.seconds += seconds
            out.grams += grams
            out.filamentCost += filamentCost
            out.energyKwh += run.energyKwh ?? 0
            out.energyCost += energyCost
            out.wearCost += wearCost

            if let id = run.printerId {
                var cur = printerAgg[id] ?? (0, 0)
                cur.seconds += seconds
                cur.prints += 1
                printerAgg[id] = cur
            } else {
                unknownPrinter.seconds += seconds
                unknownPrinter.prints += 1
            }

            let types = (run.filamentType ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for t in types {
                var cur = materialAgg[t] ?? (0, 0)
                cur.grams += grams / Double(types.count)
                cur.prints += 1
                materialAgg[t] = cur
            }
            let colors = (run.filamentColor ?? "").split(separator: ",").compactMap { raw -> String? in
                var s = raw.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("#") { s.removeFirst() }
                return s.count >= 6 ? String(s.prefix(6)).uppercased() : nil
            }
            for c in colors {
                var cur = colorAgg[c] ?? (0, 0)
                cur.grams += grams / Double(colors.count)
                cur.prints += 1
                colorAgg[c] = cur
            }

            let total = filamentCost + energyCost + wearCost
            if outcome == .completed {
                binCounts[durationBin(seconds: seconds)] += 1
                if seconds > 0, seconds > (longest?.seconds ?? 0) { longest = (seconds, run.printName) }
                if grams > 0, grams > (heaviest?.grams ?? 0) { heaviest = (grams, run.printName) }
            }
            if total > 0, total > (costliest?.amount ?? 0) { costliest = (total, run.printName) }
            if let date = dates[index] { perDay[cal.startOfDay(for: date), default: 0] += 1 }

            guard let date = dates[index] else { continue }
            let b = bucket(date)
            if let outcome {
                var c = perBucket[b] ?? Counts()
                switch outcome {
                case .completed: c.completed += 1
                case .failed: c.failed += 1
                case .cancelled: c.cancelled += 1
                }
                perBucket[b] = c
            }
            if total > 0 {
                var c = costBucket[b] ?? (0, 0, 0)
                c.f += filamentCost; c.e += energyCost; c.w += wearCost
                costBucket[b] = c
            }
            let parts = cal.dateComponents([.weekday, .hour], from: date)
            heat[((((parts.weekday ?? 2) + 5) % 7) * 24) + (parts.hour ?? 0)] += 1
        }

        out.outcomes = perBucket.sorted { $0.key < $1.key }.flatMap { key, c -> [OutcomePoint] in
            var pts: [OutcomePoint] = []
            if c.completed > 0 { pts.append(OutcomePoint(date: key, outcome: .completed, count: c.completed)) }
            if c.failed > 0 { pts.append(OutcomePoint(date: key, outcome: .failed, count: c.failed)) }
            if c.cancelled > 0 { pts.append(OutcomePoint(date: key, outcome: .cancelled, count: c.cancelled)) }
            return pts
        }
        out.rates = perBucket.sorted { $0.key < $1.key }.compactMap { key, c in
            let denom = c.completed + c.failed
            return denom > 0 ? RatePoint(date: key, rate: Double(c.completed) / Double(denom) * 100, total: denom) : nil
        }
        var printers = printerAgg.map { PrinterHoursPoint(printerId: $0.key, hours: Double($0.value.seconds) / 3600, prints: $0.value.prints) }
        if unknownPrinter.prints > 0 {
            printers.append(PrinterHoursPoint(printerId: nil, hours: Double(unknownPrinter.seconds) / 3600, prints: unknownPrinter.prints))
        }
        out.printers = printers.sorted { $0.hours > $1.hours }
        out.materials = materialAgg.map { MaterialPoint(name: $0.key, grams: $0.value.grams, prints: $0.value.prints) }.sorted { $0.grams > $1.grams }
        out.colors = colorAgg.map { ColorPoint(hex: $0.key, grams: $0.value.grams, prints: $0.value.prints) }.sorted { $0.grams > $1.grams }
        out.costs = costBucket.sorted { $0.key < $1.key }.flatMap { key, c -> [CostPoint] in
            [CostPoint(date: key, kind: "Filament", amount: c.f), CostPoint(date: key, kind: "Energy", amount: c.e),
             CostPoint(date: key, kind: "Wear", amount: c.w)].filter { $0.amount > 0 }
        }
        out.heat = heat.enumerated().filter { $0.element > 0 }.map { HeatCell(weekday: $0.offset / 24, hour: $0.offset % 24, count: $0.element) }
        out.durations = durationBins.enumerated().map { DurationBin(label: $0.element.label, order: $0.offset, count: binCounts[$0.offset]) }
        var records: [RecordItem] = []
        if let longest { records.append(RecordItem(kind: .longest, value: formatMinutes(longest.seconds / 60), detail: longest.name)) }
        if let heaviest { records.append(RecordItem(kind: .heaviest, value: formatGrams(heaviest.grams), detail: heaviest.name)) }
        if let costliest { records.append(RecordItem(kind: .costliest, value: String(costliest.amount), detail: costliest.name)) }
        // Busiest day: most runs on one local calendar day; the earlier day wins a tie.
        if let busiest = perDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            let day = busiest.key.formatted(date: .abbreviated, time: .omitted)
            records.append(RecordItem(kind: .busiestDay, value: busiest.value == 1 ? "1 print" : "\(busiest.value) prints", detail: day))
        }
        out.records = records
        return out
    }
}

/// Everything the dashboard shows for one range, produced off the main actor.
struct InsightsPayload: Sendable {
    var stats: InsStats?
    var statsError: String?
    var aggregate: StatsAggregate?
    var runsError: String?
    var failures: InsFailureAnalysis?
}

enum InsightsLoader {
    static func load(range: StatsRange, createdBy: Int?, wantStats: Bool, wantRuns: Bool) async -> InsightsPayload {
        async let statsResult = fetchStats(range, createdBy, wantStats)
        async let failureResult = fetchFailures(range, createdBy, wantRuns)
        async let runsResult = fetchRuns(range, createdBy, wantRuns)

        var payload = InsightsPayload()
        switch await statsResult {
        case let .success(s): payload.stats = s
        case let .failure(e): payload.statsError = insMessage(e)
        case nil: break
        }
        switch await runsResult {
        case let .success(a): payload.aggregate = a
        case let .failure(e): payload.runsError = insMessage(e)
        case nil: break
        }
        payload.failures = await failureResult
        return payload
    }

    private static func fetchStats(_ range: StatsRange, _ createdBy: Int?, _ want: Bool) async -> Result<InsStats, Error>? {
        guard want else { return nil }
        let days = range.days
        do { return .success(try await APIClient.shared.insStats(from: days.from, to: days.to, createdBy: createdBy)) } catch { return .failure(error) }
    }

    private static func fetchFailures(_ range: StatsRange, _ createdBy: Int?, _ want: Bool) async -> InsFailureAnalysis? {
        guard want else { return nil }
        let days = range.days
        return try? await APIClient.shared.insFailureAnalysis(from: days.from, to: days.to, createdBy: createdBy)
    }

    private static func fetchRuns(_ range: StatsRange, _ createdBy: Int?, _ want: Bool) async -> Result<StatsAggregate, Error>? {
        guard want else { return nil }
        let days = range.days
        let bounds = range.bounds
        do {
            let rows = try await APIClient.shared.insSlimRuns(from: days.from, to: days.to, createdBy: createdBy)
            return .success(StatsAggregator.aggregate(rows, start: bounds.0, end: bounds.1))
        } catch { return .failure(error) }
    }
}
