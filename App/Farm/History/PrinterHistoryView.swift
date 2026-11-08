import Accessibility
import Charts
import SwiftUI

/// Heater temperatures (nozzle, bed, chamber) and AMS humidity/temperature over time for one printer.
/// Sensor history needs `printer_sensor_history:read`; AMS history needs `ams_history:read`.
/// Push it from the printer screen; it has no navigation stack of its own.
struct PrinterHistoryView: View {
    let printerId: Int
    let printerName: String
    @EnvironmentObject private var farm: FarmStore
    @StateObject private var model = PrinterHistoryModel()
    @State private var hours = 24
    @State private var amsId: Int?
    @State private var amsMode = AMSMode.humidity

    private enum AMSMode: String, CaseIterable, Identifiable {
        case humidity = "Humidity", temperature = "Temperature"
        var id: String { rawValue }
    }

    private static let ranges: [(hours: Int, label: String)] = [(1, "1h"), (6, "6h"), (24, "24h"), (48, "48h"), (168, "7d")]

    private var canSensors: Bool { farm.can("printer_sensor_history:read") }
    private var canAMS: Bool { farm.can("ams_history:read") }
    private var units: [AMSUnit] { farm.statuses[printerId]?.ams ?? [] }
    private var selectedAMS: Int? { amsId ?? units.first?.id }

    private func amsName(_ id: Int) -> String {
        if id >= 128 { return "AMS HT \(id - 127)" }
        guard id >= 0, id < 26, let scalar = UnicodeScalar(65 + id) else { return "AMS \(id)" }
        return "AMS \(Character(scalar))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $hours) {
                    ForEach(Self.ranges, id: \.hours) { Text($0.label).tag($0.hours) }
                }
                .pickerStyle(.segmented)

                if !canSensors, !canAMS {
                    InfoRow(symbol: "lock.fill", text: "Your Bambuddy account can't view printer history.")
                }
                if canSensors { sensorSection }
                if canAMS, !units.isEmpty { amsSection }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("\(printerName) history")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: hours) { if canSensors { await model.loadSensors(printerId: printerId, hours: hours) } }
        .task(id: AMSKey(hours: hours, ams: selectedAMS)) {
            if canAMS, let id = selectedAMS { await model.loadAMS(printerId: printerId, amsId: id, hours: hours) }
        }
        .refreshable {
            if canSensors { await model.loadSensors(printerId: printerId, hours: hours) }
            if canAMS, let id = selectedAMS { await model.loadAMS(printerId: printerId, amsId: id, hours: hours) }
        }
    }

    private struct AMSKey: Hashable { let hours: Int; let ams: Int? }

    // MARK: Heaters

    @ViewBuilder private var sensorSection: some View {
        let series = (model.sensors?.series ?? []).filter { !$0.data.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Temperatures", trailing: "solid = measured, dashed = target")
            Card {
                if model.sensorsLoading, model.sensors == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if let error = model.sensorsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.statusError)
                } else if series.isEmpty {
                    Text("No temperature history in this range. Bambuddy records it while the printer is connected.")
                        .font(.footnote).foregroundStyle(Color.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HeaterChart(series: series, hours: hours)
                        ForEach(series) { s in
                            HStack {
                                Circle().fill(HeaterChart.color(s.sensorKind)).frame(width: 8, height: 8)
                                Text(s.title).font(.footnote.weight(.medium))
                                Spacer()
                                Text("min \(deg(s.minValue))  avg \(deg(s.avgValue))  max \(deg(s.maxValue))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(Color.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func deg(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))°" } ?? "–" }

    // MARK: AMS

    @ViewBuilder private var amsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "AMS", trailing: amsMode == .humidity ? "good ≤ 40%, fair ≤ 60%" : nil)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if units.count > 1 {
                            Picker("AMS unit", selection: Binding(get: { selectedAMS ?? 0 }, set: { amsId = $0 })) {
                                ForEach(units) { Text(amsName($0.id)).tag($0.id) }
                            }
                            .pickerStyle(.menu)
                        } else if let only = units.first {
                            Text(amsName(only.id)).font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Picker("Metric", selection: $amsMode) {
                            ForEach(AMSMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 220)
                    }
                    if model.amsLoading, model.ams == nil {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if let error = model.amsError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.statusError)
                    } else if let ams = model.ams, ams.data.contains(where: { amsMode == .humidity ? $0.humidity != nil : $0.temperature != nil }) {
                        AMSChart(points: ams.data, mode: amsMode == .humidity ? .humidity : .temperature, hours: hours)
                        HStack {
                            stat("Average", amsMode == .humidity ? pct(ams.avgHumidity) : deg(ams.avgTemperature))
                            Spacer()
                            stat("Min", amsMode == .humidity ? pct(ams.minHumidity) : deg(ams.minTemperature))
                            Spacer()
                            stat("Max", amsMode == .humidity ? pct(ams.maxHumidity) : deg(ams.maxTemperature))
                        }
                    } else {
                        Text("No AMS history in this range.").font(.footnote).foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
    }

    private func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Color.textMuted)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Charts

/// Averages a long series down to roughly `target` points so a week of samples stays smooth to draw.
private func decimate<T>(_ items: [T], target: Int = 240, value: (T) -> Double?, merge: (ArraySlice<T>, Double?) -> T) -> [T] {
    guard items.count > target else { return items }
    let step = Int((Double(items.count) / Double(target)).rounded(.up))
    return stride(from: 0, to: items.count, by: step).map { start in
        let slice = items[start ..< min(start + step, items.count)]
        let values = slice.compactMap(value)
        return merge(slice, values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
    }
}

private func timeAxis(_ hours: Int) -> Date.FormatStyle {
    hours > 24 ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
}

struct HeaterChart: View {
    let series: [InsHeaterSeries]
    let hours: Int
    @ScaledMetric private var height = 200.0

    static func color(_ kind: String) -> Color {
        switch kind {
        case "nozzle": .statusError
        case "nozzle_2": .statusWarning
        case "bed": .statusFinished
        default: .accentTeal
        }
    }

    var body: some View {
        let drawn = series.map { s -> (InsHeaterSeries, [InsHeaterPoint]) in
            (s, decimate(s.data, value: { $0.value }, merge: { slice, avg in
                InsHeaterPoint(recordedAt: slice[slice.startIndex].recordedAt, value: avg,
                               target: slice.last?.target)
            }))
        }
        Chart {
            ForEach(drawn, id: \.0.sensorKind) { s, points in
                ForEach(points) { p in
                    if let v = p.value {
                        LineMark(x: .value("Time", p.recordedAt), y: .value("°C", v), series: .value("Series", s.sensorKind))
                            .foregroundStyle(by: .value("Sensor", s.title))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(points) { p in
                    if let t = p.target, t > 0 {
                        LineMark(x: .value("Time", p.recordedAt), y: .value("°C", t), series: .value("Series", s.sensorKind + "-target"))
                            .foregroundStyle(by: .value("Sensor", s.title))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.title), range: series.map { Self.color($0.sensorKind) })
        .chartLegend(.hidden)
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } } } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: timeAxis(hours)) } }
        .frame(height: height)
        .accessibilityLabel("Heater temperatures over the last \(hours) hours")
        .accessibilityValue(series.map { "\($0.title) \($0.minValue.map { String(Int($0)) } ?? "?") to \($0.maxValue.map { String(Int($0)) } ?? "?") degrees" }.joined(separator: ", "))
        .accessibilityChartDescriptor(HistoryDescriptor(
            title: "Heater temperatures", yTitle: "Degrees Celsius",
            series: drawn.map { s, pts in (s.title, pts.compactMap { p in p.value.map { (p.recordedAt, $0) } }) }))
    }
}

struct AMSChart: View {
    enum Mode { case humidity, temperature }
    let points: [InsAMSPoint]
    let mode: Mode
    let hours: Int
    @ScaledMetric private var height = 180.0

    var body: some View {
        let drawn = decimate(points, value: { mode == .humidity ? $0.humidity : $0.temperature }, merge: { slice, avg in
            InsAMSPoint(recordedAt: slice[slice.startIndex].recordedAt, humidity: mode == .humidity ? avg : nil,
                        humidityRaw: nil, temperature: mode == .temperature ? avg : nil)
        })
        let tint: Color = mode == .humidity ? .statusFinished : .statusWarning
        Chart {
            ForEach(drawn) { p in
                if let v = mode == .humidity ? p.humidity : p.temperature {
                    LineMark(x: .value("Time", p.recordedAt), y: .value(mode == .humidity ? "Humidity" : "Temperature", v))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Time", p.recordedAt), y: .value(mode == .humidity ? "Humidity" : "Temperature", v))
                        .foregroundStyle(tint.opacity(0.12))
                }
            }
            if mode == .humidity {
                RuleMark(y: .value("Good", 40)).foregroundStyle(Color.accentTeal.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("Fair", 60)).foregroundStyle(Color.statusWarning.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: mode == .humidity))
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))\(mode == .humidity ? "%" : "°")") } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: timeAxis(hours)) } }
        .frame(height: height)
        .accessibilityLabel("AMS \(mode == .humidity ? "humidity" : "temperature") over the last \(hours) hours")
        .accessibilityChartDescriptor(HistoryDescriptor(
            title: mode == .humidity ? "AMS humidity" : "AMS temperature", yTitle: mode == .humidity ? "Percent" : "Degrees Celsius",
            series: [(mode == .humidity ? "Humidity" : "Temperature",
                      drawn.compactMap { p in (mode == .humidity ? p.humidity : p.temperature).map { (p.recordedAt, $0) } })]))
    }
}

/// Audio graph for time series: x is the time, y the reading.
struct HistoryDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let yTitle: String
    let series: [(name: String, points: [(Date, Double)])]

    func makeChartDescriptor() -> AXChartDescriptor {
        let all = series.flatMap(\.points)
        let lo = all.map(\.0).min() ?? Date(), hi = all.map(\.0).max() ?? Date().addingTimeInterval(1)
        let x = AXNumericDataAxisDescriptor(title: "Time", range: lo.timeIntervalSince1970 ... max(hi.timeIntervalSince1970, lo.timeIntervalSince1970 + 1),
                                            gridlinePositions: []) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
        let ys = all.map(\.1)
        let yLo = ys.min() ?? 0, yHi = ys.max() ?? 1
        let y = AXNumericDataAxisDescriptor(title: yTitle, range: yLo ... max(yHi, yLo + 1), gridlinePositions: []) { String(format: "%.1f", $0) }
        let descriptors = series.map { s in
            AXDataSeriesDescriptor(name: s.name, isContinuous: true, dataPoints: s.points.map { AXDataPoint(x: $0.0.timeIntervalSince1970, y: $0.1) })
        }
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: descriptors)
    }

    func updateChartDescriptor(_: AXChartDescriptor) {}
}

@MainActor
final class PrinterHistoryModel: ObservableObject {
    @Published private(set) var sensors: InsSensorHistory?
    @Published private(set) var sensorsLoading = false
    @Published private(set) var sensorsError: String?
    @Published private(set) var ams: InsAMSHistory?
    @Published private(set) var amsLoading = false
    @Published private(set) var amsError: String?

    func loadSensors(printerId: Int, hours: Int) async {
        sensorsLoading = true
        defer { sensorsLoading = false }
        do {
            let result = try await APIClient.shared.insSensorHistory(printerId: printerId, hours: hours)
            guard !Task.isCancelled else { return }
            sensors = result
            sensorsError = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch { sensorsError = insMessage(error) }
    }

    func loadAMS(printerId: Int, amsId: Int, hours: Int) async {
        amsLoading = true
        defer { amsLoading = false }
        do {
            let result = try await APIClient.shared.insAMSHistory(printerId: printerId, amsId: amsId, hours: hours)
            guard !Task.isCancelled else { return }
            ams = result
            amsError = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch { amsError = insMessage(error) }
    }
}
