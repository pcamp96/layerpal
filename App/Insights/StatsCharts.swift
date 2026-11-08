import Accessibility
import Charts
import SwiftUI

// Swift Charts for the Stats dashboard. Each chart carries an accessibility summary and an audio-graph descriptor.

/// Titled card wrapping one chart.
struct InsightCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title, trailing: subtitle)
            Card { content }
        }
    }
}

/// Audio-graph support: a single series of labelled values.
struct SeriesDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let xTitle: String
    let yTitle: String
    let points: [(label: String, value: Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: xTitle, categoryOrder: points.map(\.label))
        let top = max(points.map(\.value).max() ?? 1, 1)
        let y = AXNumericDataAxisDescriptor(title: yTitle, range: 0 ... top, gridlinePositions: [],
                                            valueDescriptionProvider: { String(format: "%.1f", $0) })
        let series = AXDataSeriesDescriptor(name: title, isContinuous: false,
                                            dataPoints: points.map { AXDataPoint(x: $0.label, y: $0.value) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }

    func updateChartDescriptor(_: AXChartDescriptor) {}
}

extension Outcome {
    var color: Color {
        switch self {
        case .completed: .accentTeal
        case .failed: .statusError
        case .cancelled: .statusWarning
        }
    }
}

private func axisDate(_ unit: Calendar.Component) -> Date.FormatStyle {
    switch unit {
    case .hour: .dateTime.hour()
    case .month: .dateTime.month(.abbreviated)
    default: .dateTime.month(.abbreviated).day()
    }
}

/// X-axis span: the selected range when known, else the data's own span padded by one bucket.
func timeDomain(_ selected: ClosedRange<Date>?, _ dates: [Date], _ unit: Calendar.Component) -> ClosedRange<Date> {
    if let selected { return selected }
    let cal = Calendar.current
    let lo = dates.min() ?? Date()
    let hi = cal.date(byAdding: unit, value: 1, to: dates.max() ?? lo) ?? lo.addingTimeInterval(86400)
    return lo ... max(hi, lo.addingTimeInterval(3600))
}

private func bucketLabel(_ date: Date, _ unit: Calendar.Component) -> String {
    switch unit {
    case .hour: date.formatted(.dateTime.month().day().hour())
    case .month: date.formatted(.dateTime.year().month(.wide))
    case .weekOfYear: "Week of " + date.formatted(.dateTime.month().day())
    default: date.formatted(.dateTime.month().day())
    }
}

// MARK: Prints over time

struct PrintsOverTimeChart: View {
    let points: [OutcomePoint]
    let unit: Calendar.Component
    /// The selected range, so days without prints still take up space on the axis.
    var domain: ClosedRange<Date>?
    @ScaledMetric private var height = 190.0

    var body: some View {
        let byDate = Dictionary(grouping: points, by: \.date)
        let summary = byDate.keys.sorted().map { d -> (label: String, value: Double) in
            (bucketLabel(d, unit), Double(byDate[d]?.reduce(0) { $0 + $1.count } ?? 0))
        }
        VStack(alignment: .leading, spacing: 8) {
            Chart(points) { p in
                BarMark(x: .value("Date", p.date, unit: unit), y: .value("Prints", p.count))
                    .foregroundStyle(by: .value("Outcome", p.outcome.rawValue))
            }
            .chartForegroundStyleScale(domain: Outcome.allCases.map(\.rawValue), range: Outcome.allCases.map(\.color))
            .chartXScale(domain: timeDomain(domain, points.map(\.date), unit))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: axisDate(unit)) } }
            .frame(height: height)
            .accessibilityLabel("Prints over time, stacked by outcome")
            .accessibilityValue("\(points.reduce(0) { $0 + $1.count }) prints in \(byDate.count) periods")
            .accessibilityChartDescriptor(SeriesDescriptor(title: "Prints over time", xTitle: "Period", yTitle: "Prints", points: summary))
        }
    }
}

// MARK: Hours per printer

struct HoursPerPrinterChart: View {
    struct Row: Identifiable { let name: String; let hours: Double; let prints: Int; var id: String { name } }
    let rows: [Row]
    @ScaledMetric private var rowHeight = 30.0

    var body: some View {
        Chart(rows) { r in
            BarMark(x: .value("Hours", r.hours), y: .value("Printer", r.name))
                .foregroundStyle(Color.accentTeal)
                .annotation(position: .trailing) {
                    Text(formatHours(r.hours)).font(.caption2).foregroundStyle(Color.textSecondary)
                }
        }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
        .chartXAxis(.hidden)
        .frame(height: max(80, CGFloat(rows.count) * rowHeight))
        .accessibilityLabel("Print hours per printer")
        .accessibilityValue(rows.map { "\($0.name) \(formatHours($0.hours))" }.joined(separator: ", "))
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Print hours per printer", xTitle: "Printer", yTitle: "Hours",
                                                       points: rows.map { ($0.name, $0.hours) }))
    }
}

// MARK: Filament

struct FilamentMaterialChart: View {
    let rows: [MaterialPoint]
    @ScaledMetric private var rowHeight = 28.0

    var body: some View {
        Chart(rows) { r in
            BarMark(x: .value("Grams", r.grams), y: .value("Material", r.name))
                .foregroundStyle(Color.statusFinished)
                .annotation(position: .trailing) {
                    Text(formatGrams(r.grams)).font(.caption2).foregroundStyle(Color.textSecondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: max(70, CGFloat(rows.count) * rowHeight))
        .accessibilityLabel("Filament used by material")
        .accessibilityValue(rows.map { "\($0.name) \(formatGrams($0.grams))" }.joined(separator: ", "))
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Filament by material", xTitle: "Material", yTitle: "Grams",
                                                       points: rows.map { ($0.name, $0.grams) }))
    }
}

struct FilamentColorChart: View {
    let rows: [ColorPoint]

    var body: some View {
        let colors = rows.map { Color(hexRGBA: $0.hex) ?? .gray }
        Chart(rows) { r in
            BarMark(x: .value("Grams", r.grams), y: .value("Color", "#" + r.hex))
                .foregroundStyle(by: .value("Color", "#" + r.hex))
                .annotation(position: .trailing) {
                    Text(formatGrams(r.grams)).font(.caption2).foregroundStyle(Color.textSecondary)
                }
        }
        .chartForegroundStyleScale(domain: rows.map { "#" + $0.hex }, range: colors)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
        .frame(height: max(70, CGFloat(rows.count) * 28))
        .accessibilityLabel("Filament used by color")
        .accessibilityValue(rows.map { "#\($0.hex) \(formatGrams($0.grams))" }.joined(separator: ", "))
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Filament by color", xTitle: "Color", yTitle: "Grams",
                                                       points: rows.map { ("#" + $0.hex, $0.grams) }))
    }
}

// MARK: Success rate trend

struct SuccessTrendChart: View {
    let points: [RatePoint]
    let unit: Calendar.Component
    var domain: ClosedRange<Date>?
    @ScaledMetric private var height = 160.0

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Date", p.date, unit: unit), y: .value("Success rate", p.rate))
                .foregroundStyle(Color.accentTeal)
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", p.date, unit: unit), y: .value("Success rate", p.rate))
                .foregroundStyle(p.rate < 80 ? Color.statusError : Color.accentTeal)
                .symbolSize(points.count > 40 ? 12 : 30)
        }
        .chartYScale(domain: 0 ... 100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
        .chartXScale(domain: timeDomain(domain, points.map(\.date), unit))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: axisDate(unit)) } }
        .frame(height: height)
        .accessibilityLabel("Success rate trend, completed over completed plus failed")
        .accessibilityValue(points.last.map { "Latest \(Int($0.rate)) percent" } ?? "")
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Success rate", xTitle: "Period", yTitle: "Percent",
                                                       points: points.map { (bucketLabel($0.date, unit), $0.rate) }))
    }
}

// MARK: Time accuracy

struct TimeAccuracyChart: View {
    struct Row: Identifiable { let name: String; let accuracy: Double; var id: String { name } }
    let rows: [Row]
    @ScaledMetric private var rowHeight = 30.0

    var body: some View {
        Chart {
            ForEach(rows) { r in
                BarMark(x: .value("Accuracy", r.accuracy), y: .value("Printer", r.name))
                    .foregroundStyle(abs(r.accuracy - 100) <= 10 ? Color.accentTeal : Color.statusWarning)
                    .annotation(position: .trailing) { Text("\(Int(r.accuracy.rounded()))%").font(.caption2).foregroundStyle(Color.textSecondary) }
            }
            RuleMark(x: .value("Perfect", 100)).foregroundStyle(Color.textMuted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXScale(domain: 0 ... 130)
        .chartXAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
        .frame(height: max(80, CGFloat(rows.count) * rowHeight + 24))
        .accessibilityLabel("Time accuracy per printer, 100 percent means the slicer estimate matched")
        .accessibilityValue(rows.map { "\($0.name) \(Int($0.accuracy.rounded())) percent" }.joined(separator: ", "))
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Time accuracy", xTitle: "Printer", yTitle: "Percent",
                                                       points: rows.map { ($0.name, $0.accuracy) }))
    }
}

// MARK: Cost

struct CostChart: View {
    let points: [CostPoint]
    let unit: Calendar.Component
    @ScaledMetric private var height = 160.0
    private static let kinds = ["Filament", "Energy", "Wear"]
    private static let colors: [Color] = [.accentTeal, .statusWarning, .statusFinished]

    var body: some View {
        Chart(points) { p in
            BarMark(x: .value("Date", p.date, unit: unit), y: .value("Cost", p.amount))
                .foregroundStyle(by: .value("Kind", p.kind))
        }
        .chartForegroundStyleScale(domain: Self.kinds, range: Self.colors)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: axisDate(unit)) } }
        .frame(height: height)
        .accessibilityLabel("Cost over time: filament, energy and printer wear")
        .accessibilityValue(String(format: "%.2f total", points.reduce(0) { $0 + $1.amount }))
        .accessibilityChartDescriptor(SeriesDescriptor(
            title: "Cost over time", xTitle: "Period", yTitle: "Cost",
            points: Dictionary(grouping: points, by: \.date).sorted { $0.key < $1.key }
                .map { (bucketLabel($0.key, unit), $0.value.reduce(0) { $0 + $1.amount }) }))
    }
}

// MARK: Activity heat map

struct ActivityHeatMap: View {
    let cells: [HeatCell]
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    @ScaledMetric private var height = 190.0

    var body: some View {
        let peak = max(cells.map(\.count).max() ?? 1, 1)
        Chart(cells) { c in
            RectangleMark(x: .value("Hour", c.hour), y: .value("Day", Self.days[c.weekday]), width: .ratio(0.92), height: .ratio(0.9))
                .foregroundStyle(Color.accentTeal.opacity(0.2 + 0.8 * Double(c.count) / Double(peak)))
        }
        .chartYScale(domain: Self.days)
        .chartXScale(domain: -0.5 ... 23.5)
        .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text(h == 0 ? "12a" : (h == 12 ? "12p" : (h < 12 ? "\(h)a" : "\(h - 12)p"))) } } } }
        .frame(height: height)
        .accessibilityLabel("Print starts by weekday and hour")
        .accessibilityValue(busiest)
        .accessibilityChartDescriptor(SeriesDescriptor(
            title: "Prints by weekday", xTitle: "Weekday", yTitle: "Prints",
            points: Self.days.indices.map { d in (Self.days[d], Double(cells.filter { $0.weekday == d }.reduce(0) { $0 + $1.count })) }))
    }

    private var busiest: String {
        guard let top = cells.max(by: { $0.count < $1.count }) else { return "No data" }
        return "Busiest: \(Self.days[top.weekday]) around \(top.hour):00 with \(top.count) prints"
    }
}

// MARK: Durations & failures

struct DurationChart: View {
    let bins: [DurationBin]
    @ScaledMetric private var height = 150.0

    var body: some View {
        Chart(bins) { b in
            BarMark(x: .value("Duration", b.label), y: .value("Prints", b.count)).foregroundStyle(Color.statusFinished)
        }
        .chartXScale(domain: bins.map(\.label))
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) } }
        .frame(height: height)
        .accessibilityLabel("Completed prints by duration")
        .accessibilityValue(bins.filter { $0.count > 0 }.map { "\($0.label): \($0.count)" }.joined(separator: ", "))
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Print durations", xTitle: "Duration", yTitle: "Prints",
                                                       points: bins.map { ($0.label, Double($0.count)) }))
    }
}

struct FailureReasonsChart: View {
    struct Row: Identifiable { let reason: String; let count: Int; var id: String { reason } }
    let rows: [Row]

    var body: some View {
        Chart(rows) { r in
            BarMark(x: .value("Failures", r.count), y: .value("Reason", r.reason))
                .foregroundStyle(Color.statusError)
                .annotation(position: .trailing) { Text("\(r.count)").font(.caption2).foregroundStyle(Color.textSecondary) }
        }
        .chartXAxis(.hidden)
        .frame(height: max(70, CGFloat(rows.count) * 30))
        .accessibilityLabel("Failures by reason")
        .accessibilityValue(rows.map { "\($0.reason) \($0.count)" }.joined(separator: ", "))
        .accessibilityChartDescriptor(SeriesDescriptor(title: "Failures by reason", xTitle: "Reason", yTitle: "Failures",
                                                       points: rows.map { ($0.reason, Double($0.count)) }))
    }
}

/// "adhesionFailure" -> "Adhesion failure" (failure-reason values the server uses).
func insFailureReasonLabel(_ key: String) -> String {
    switch key {
    case "": return "Unclassified"
    case "noStatusUpdate": return "No status update"
    case "killSwitch": return "Kill switch"
    default:
        var out = ""
        for ch in key {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : Character(ch.lowercased()))
        }
        return out
    }
}
