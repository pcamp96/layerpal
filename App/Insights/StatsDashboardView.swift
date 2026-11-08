import SwiftUI

/// Bambuddy's Stats page: headline tiles and charts for a date range. Needs `stats:read` for the
/// server totals and `archives:read_own|read_all` for the per-run charts; it shows whichever the user has.
/// Place it inside an existing NavigationStack.
struct StatsDashboardView: View {
    @EnvironmentObject private var farm: FarmStore
    @StateObject private var model = StatsDashboardModel()
    @State private var range = StatsRange()
    @State private var userFilter: Int?
    @State private var showCustom = false
    @State private var exportFile: StatsExportFile?
    @State private var working = false
    @State private var confirmRecalc = false
    @State private var actionNotice: String?
    @State private var actionError: String?

    private struct StatsExportFile: Identifiable { let url: URL; var id: URL { url } }

    private var canRecalculate: Bool { farm.can("archives:update_all") }

    /// The export route takes a trailing window in days (not a date range), so the selected range
    /// becomes "from its start until now".
    private var exportDays: Int {
        guard let start = range.bounds.0 else { return 3650 }
        return max(1, Int((Date().timeIntervalSince(start) / 86400).rounded(.up)))
    }

    private var canStats: Bool { farm.can("stats:read") }
    private var canRuns: Bool { farm.can("archives:read_all") || farm.can("archives:read_own") }
    private var canFilterByUser: Bool { farm.can("stats:filter_by_user") }

    /// Selected range for time-axis charts (nil for "all time").
    private var selectedDomain: ClosedRange<Date>? {
        let b = range.bounds
        guard let lo = b.0, let hi = b.1, hi > lo else { return nil }
        return lo ... hi
    }

    private struct LoadKey: Hashable { let range: StatsRange; let user: Int?; let stats: Bool; let runs: Bool }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rangeBar
                if !canStats, !canRuns {
                    InfoRow(symbol: "lock.fill", text: "Your Bambuddy account can't view statistics.")
                }
                if let error = model.payload?.statsError ?? model.payload?.runsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.statusError)
                }
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.statusError)
                }
                if let actionNotice {
                    Label(actionNotice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal)
                }
                if model.loading, model.payload == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                if let payload = model.payload {
                    content(payload)
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if (model.loading && model.payload != nil) || working { ProgressView() }
            }
            if canStats || canRecalculate {
                ToolbarItem(placement: .topBarTrailing) { toolsMenu }
            }
        }
        .sheet(item: $exportFile) { file in AdvShareSheet(items: [file.url]) }
        .confirmationDialog("Recalculate all costs?", isPresented: $confirmRecalc, titleVisibility: .visible) {
            Button("Recalculate costs", role: .destructive) { recalculateCosts() }
        } message: {
            Text("Reprices every archive and its runs from the current spool and filament prices. A cost you set by hand on an archive is replaced by the recalculated one. This can't be undone.")
        }
        .task(id: LoadKey(range: range, user: userFilter, stats: canStats, runs: canRuns)) {
            await model.load(range: range, createdBy: userFilter, wantStats: canStats, wantRuns: canRuns)
        }
        .task(id: canFilterByUser) { if canFilterByUser { await model.loadUsers() } }
        .task { await model.loadCurrency() }
        .refreshable { await model.load(range: range, createdBy: userFilter, wantStats: canStats, wantRuns: canRuns) }
        .sheet(isPresented: $showCustom) { customSheet }
    }

    // MARK: Export and cost recalculation

    private var toolsMenu: some View {
        Menu {
            if canStats {
                let window = range.preset == .all ? "all time" : "last \(exportDays) days"
                Button { export("csv") } label: { Label("Export CSV (\(window))", systemImage: "tablecells") }
                Button { export("xlsx") } label: { Label("Export Excel (\(window))", systemImage: "tablecells.badge.ellipsis") }
            }
            if canRecalculate {
                if canStats { Divider() }
                Button(role: .destructive) { confirmRecalc = true } label: { Label("Recalculate costs…", systemImage: "arrow.triangle.2.circlepath") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(working)
        .accessibilityLabel("Export and tools")
    }

    /// GET /archives/stats/export (stats:read). The server builds the summary, failure breakdown and per-printer figures.
    private func export(_ format: String) {
        working = true
        actionError = nil
        actionNotice = nil
        Task {
            defer { working = false }
            do {
                exportFile = StatsExportFile(url: try await APIClient.shared.exportStatsFile(format: format, days: exportDays, createdBy: userFilter))
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                actionError = insMessage(error)
            }
        }
    }

    /// POST /archives/recalculate-costs (archives:update_all), then the stats reload so the tiles show the new prices.
    private func recalculateCosts() {
        working = true
        actionError = nil
        actionNotice = nil
        Task {
            defer { working = false }
            do {
                let result = try await APIClient.shared.recalculateCosts()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                var text = "Recalculated costs for \(result.updated ?? 0) archive\(result.updated == 1 ? "" : "s")."
                if let kept = result.preserved, kept > 0 { text += " \(kept) kept the price Spoolman set." }
                if let down = result.spoolmanUnreachable, down > 0 { text += " Spoolman wasn't reachable, so \(down) usage record\(down == 1 ? "" : "s") kept their price." }
                actionNotice = text
                await model.load(range: range, createdBy: userFilter, wantStats: canStats, wantRuns: canRuns)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                actionError = insMessage(error)
            }
        }
    }

    // MARK: Controls

    private var rangeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StatsPreset.allCases) { preset in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            range.preset = preset
                            if preset == .custom { showCustom = true }
                        } label: {
                            Text(preset.title).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(range.preset == preset ? Color.accentTeal : Color.bgCard, in: Capsule())
                                .foregroundStyle(range.preset == preset ? Color.white : Color.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(range.preset == preset ? .isSelected : [])
                    }
                }
            }
            HStack {
                if range.preset == .custom {
                    Button { showCustom = true } label: {
                        Label("\(range.customFrom.formatted(date: .abbreviated, time: .omitted)) to \(range.customTo.formatted(date: .abbreviated, time: .omitted))",
                              systemImage: "calendar").font(.footnote)
                    }
                }
                Spacer()
                if canFilterByUser, !model.users.isEmpty {
                    Menu {
                        Picker("User", selection: $userFilter) {
                            Text("All users").tag(Int?.none)
                            Text("No user (system)").tag(Int?.some(-1))
                            ForEach(model.users) { Text($0.username).tag(Int?.some($0.id)) }
                        }
                    } label: {
                        Label(userLabel, systemImage: "person.crop.circle").font(.footnote)
                    }
                }
            }
        }
    }

    private var userLabel: String {
        switch userFilter {
        case nil: "All users"
        case .some(-1): "No user"
        case let id?: model.users.first { $0.id == id }?.username ?? "User"
        }
    }

    private var customSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $range.customFrom, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $range.customTo, in: ...Date(), displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCustom = false } } }
        }
        .presentationDetents([.height(260)])
    }

    // MARK: Content

    @ViewBuilder private func content(_ payload: InsightsPayload) -> some View {
        let agg = payload.aggregate
        tiles(payload)
        if payload.stats?.energyDataWarmingUp == true {
            InfoRow(symbol: "hourglass", text: "Energy totals are still warming up. Bambuddy needs a few hourly snapshots to price them.")
        }
        if let agg, agg.rowCount > 0 {
            charts(agg, payload)
        } else if agg != nil {
            InfoRow(symbol: "chart.bar", text: "No prints in this range.")
        } else if canStats, !canRuns {
            InfoRow(symbol: "lock.fill", text: "Per-print charts need permission to read archives.")
        }
        if let stats = payload.stats, !stats.timeAccuracyByPrinter.isEmpty || stats.averageTimeAccuracy != nil {
            accuracyCard(stats)
        }
        if let failures = payload.failures, failures.failedPrints > 0, !failures.failuresByReason.isEmpty {
            InsightCard(title: "Failure reasons", subtitle: String(format: "%.1f%% failed", failures.failureRate)) {
                FailureReasonsChart(rows: failures.failuresByReason.sorted { $0.value > $1.value }.prefix(8)
                    .map { .init(reason: insFailureReasonLabel($0.key), count: $0.value) })
            }
        }
        if let agg, !agg.records.isEmpty { recordsCard(agg.records) }
        if let agg, agg.rowCount >= 50000 {
            Text("Showing the most recent 50,000 prints in this range.").font(.caption).foregroundStyle(Color.textMuted)
        }
    }

    private struct Tile: Identifiable {
        let title: String
        let value: String
        let symbol: String
        var tint: Color = .accentTeal
        var id: String { title }
    }

    private func money(_ v: Double) -> String { v.formatted(.currency(code: model.currencyCode)) }

    private func tiles(_ payload: InsightsPayload) -> some View {
        let s = payload.stats
        let a = payload.aggregate
        let total = s?.totalPrints ?? a?.total ?? 0
        let done = s?.successfulPrints ?? a?.completed ?? 0
        let failed = s?.failedPrints ?? a?.failed ?? 0
        let cancelled = s?.cancelledPrints ?? a?.cancelled ?? 0
        let hours = s?.totalPrintTimeHours ?? Double(a?.seconds ?? 0) / 3600
        let grams = s?.totalFilamentGrams ?? a?.grams ?? 0
        let cost = s?.totalCost ?? a?.filamentCost ?? 0
        let kwh = s?.totalEnergyKwh ?? a?.energyKwh ?? 0
        let energyCost = s?.totalEnergyCost ?? a?.energyCost ?? 0
        let wear = s?.totalWearCost ?? a?.wearCost ?? 0
        // Success rate divides by completed + failed only: cancelled prints don't drag it down.
        let rate = done + failed > 0 ? Double(done) / Double(done + failed) : nil

        var tiles = [
            Tile(title: "Prints", value: "\(total)", symbol: "printer.fill"),
            Tile(title: "Success rate", value: rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", symbol: "checkmark.seal.fill",
                 tint: (rate ?? 1) < 0.85 ? .statusWarning : .accentTeal),
            Tile(title: "Print time", value: formatHours(hours), symbol: "clock.fill", tint: .statusFinished),
            Tile(title: "Filament", value: formatGrams(grams), symbol: "scribble.variable", tint: .statusWarning),
            Tile(title: "Failed", value: "\(failed)", symbol: "xmark.octagon.fill", tint: failed > 0 ? .statusError : .textSecondary),
            Tile(title: "Cancelled", value: "\(cancelled)", symbol: "stop.circle.fill", tint: .textSecondary),
            Tile(title: "Filament cost", value: money(cost), symbol: "dollarsign.circle.fill"),
            Tile(title: "Energy", value: String(format: "%.2f kWh", kwh), symbol: "bolt.fill", tint: .statusWarning),
            Tile(title: "Energy cost", value: money(energyCost), symbol: "bolt.circle.fill", tint: .statusWarning),
        ]
        // The wear tile only appears once a printer has a wear cost.
        if wear > 0 { tiles.append(Tile(title: "Wear cost", value: money(wear), symbol: "wrench.fill", tint: .textSecondary)) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(tiles) { t in
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(t.title, systemImage: t.symbol).font(.caption).foregroundStyle(t.tint).labelStyle(.titleAndIcon)
                        Text(t.value).font(.title3.weight(.bold).monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func charts(_ agg: StatsAggregate, _ payload: InsightsPayload) -> some View {
        let names = printerNames(payload.stats)
        let unitName = agg.unit == .hour ? "per hour" : (agg.unit == .day ? "per day" : (agg.unit == .weekOfYear ? "per week" : "per month"))
        InsightCard(title: "Prints over time", subtitle: unitName) { PrintsOverTimeChart(points: agg.outcomes, unit: agg.unit, domain: selectedDomain) }
        if !agg.printers.isEmpty {
            InsightCard(title: "Print hours per printer") {
                HoursPerPrinterChart(rows: agg.printers.prefix(12).map {
                    .init(name: $0.printerId.map { names[$0] ?? "Printer \($0)" } ?? "Unknown", hours: $0.hours, prints: $0.prints)
                })
            }
        }
        if !agg.materials.isEmpty {
            InsightCard(title: "Filament by material") { FilamentMaterialChart(rows: Array(agg.materials.prefix(10))) }
        }
        if !agg.colors.isEmpty {
            InsightCard(title: "Filament by color") { FilamentColorChart(rows: Array(agg.colors.prefix(10))) }
        }
        if agg.rates.count >= 2 {
            InsightCard(title: "Success rate trend", subtitle: unitName) { SuccessTrendChart(points: agg.rates, unit: agg.unit, domain: selectedDomain) }
        }
        if !agg.costs.isEmpty {
            InsightCard(title: "Cost over time", subtitle: model.currencyCode) { CostChart(points: agg.costs, unit: agg.unit) }
        }
        if !agg.heat.isEmpty {
            InsightCard(title: "Activity") { ActivityHeatMap(cells: agg.heat) }
        }
        if agg.durations.contains(where: { $0.count > 0 }) {
            InsightCard(title: "Completed print durations") { DurationChart(bins: agg.durations) }
        }
    }

    private func accuracyCard(_ stats: InsStats) -> some View {
        let names = printerNames(stats)
        let rows = stats.timeAccuracyByPrinter.compactMap { key, value -> TimeAccuracyChart.Row? in
            let id = Int(key)
            return .init(name: id.flatMap { names[$0] } ?? (id.map { "Printer \($0)" } ?? "Unknown"), accuracy: value)
        }.sorted { $0.accuracy > $1.accuracy }
        return InsightCard(title: "Time accuracy", subtitle: stats.averageTimeAccuracy.map { "avg \(Int($0.rounded()))%" }) {
            VStack(alignment: .leading, spacing: 8) {
                if !rows.isEmpty { TimeAccuracyChart(rows: rows) }
                Text("Slicer estimate divided by actual time on completed prints. Over 100% means it finished faster than estimated.")
                    .font(.caption).foregroundStyle(Color.textMuted)
            }
        }
    }

    private func recordsCard(_ records: [RecordItem]) -> some View {
        InsightCard(title: "Records") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(records) { r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recordTitle(r.kind)).font(.subheadline.weight(.medium))
                            if let d = r.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1) }
                        }
                        Spacer()
                        Text(r.kind == .costliest ? money(Double(r.value) ?? 0) : r.value).font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func recordTitle(_ kind: RecordItem.Kind) -> String {
        switch kind {
        case .longest: "Longest print"
        case .heaviest: "Heaviest print"
        case .costliest: "Most expensive print"
        case .busiestDay: "Busiest day"
        }
    }

    /// Live printer names win over the names recorded in the log, so a rename shows straight away.
    private func printerNames(_ stats: InsStats?) -> [Int: String] {
        var map: [Int: String] = [:]
        for (key, name) in stats?.printerNames ?? [:] { if let id = Int(key) { map[id] = name } }
        for p in farm.printers { map[p.id] = p.name }
        return map
    }
}

@MainActor
final class StatsDashboardModel: ObservableObject {
    @Published private(set) var payload: InsightsPayload?
    @Published private(set) var loading = false
    @Published private(set) var users: [InsUser] = []
    @Published private(set) var currencyCode = InsCurrency.code

    private var generation = 0

    func load(range: StatsRange, createdBy: Int?, wantStats: Bool, wantRuns: Bool) async {
        generation += 1
        let mine = generation
        loading = true
        let result = await InsightsLoader.load(range: range, createdBy: createdBy, wantStats: wantStats, wantRuns: wantRuns)
        // A newer request (range change) or a cancelled task must not overwrite fresher data.
        guard mine == generation, !Task.isCancelled else { return }
        payload = result
        loading = false
    }

    func loadUsers() async { users = (try? await APIClient.shared.insUsers()) ?? [] }

    func loadCurrency() async {
        currencyCode = await InsCurrency.refresh()
    }
}
