import SwiftUI

/// Home tab: the whole farm at a glance, built to scale from 3 printers to 80+.
struct FarmView: View {
    @EnvironmentObject private var farm: FarmStore
    @EnvironmentObject private var push: PushManager
    @AppStorage("farm.layout") private var layoutRaw = Layout.auto.rawValue
    @AppStorage("farm.sort") private var sortRaw = Sort.status.rawValue
    @State private var filter: FarmState?
    @State private var locationFilter: String?
    @State private var search = ""
    @State private var path = NavigationPath()

    enum Layout: String, CaseIterable { case auto, cards, compact }
    enum Sort: String, CaseIterable {
        case status, finishing, name
        var label: String { switch self { case .status: "Status"; case .finishing: "Finishing soonest"; case .name: "Name" } }
    }

    private var layout: Layout { Layout(rawValue: layoutRaw) ?? .auto }
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .status }
    private var compact: Bool { layout == .compact || (layout == .auto && farm.activePrinters.count > 12) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                    if ServerConfig.serverURL == nil {
                        EmptyStateCard(title: "Connect your Bambuddy",
                                       message: "Add your server in Settings to see your farm.", symbol: "server.rack")
                    } else {
                        FarmSummaryLine()
                        HStack(spacing: 8) {
                            StatusStrip(filter: $filter)
                            if farm.locations.count > 1 { locationMenu }
                        }
                        ConnectionBanner()
                        let attention = farm.needsAttention.filter(inSelectedLocation)
                        if filter == nil, search.isEmpty, !attention.isEmpty {
                            NeedsAttentionSection(printers: attention)
                        }
                        printerSections
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color.bgPrimary)
            .navigationTitle("Farm")
            .navigationDestination(for: Printer.self) { PrinterDetailView(printerId: $0.id) }
            .searchable(text: $search, prompt: "Printers, jobs, locations")
            .refreshable { await farm.refresh() }
            .toolbar { toolbar }
            .onChange(of: push.openPrinterName) { _, name in open(name) }
            .onChange(of: farm.printers) { _, _ in open(push.openPrinterName) }
        }
    }

    // MARK: Sections

    @ViewBuilder private var printerSections: some View {
        let shown = filtered
        if shown.isEmpty, !farm.printers.isEmpty {
            EmptyStateCard(title: "No printers match", message: filter.map { "Nothing is \($0.label.lowercased()) right now." } ?? "Try a different search.",
                           symbol: "line.3.horizontal.decrease.circle")
        }
        let groups = grouped(shown)
        ForEach(groups, id: \.0) { location, printers in
            VStack(alignment: .leading, spacing: 8) {
                if groups.count > 1 {
                    SectionHeader(title: location.isEmpty ? "No location" : location, trailing: "\(printers.count)")
                }
                if compact {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(printers.enumerated()), id: \.element.id) { index, printer in
                                NavigationLink(value: printer) { CompactPrinterRow(printer: printer) }
                                    .buttonStyle(.plain)
                                if index < printers.count - 1 { Divider().padding(.leading, 34) }
                            }
                        }
                    }
                } else {
                    ForEach(printers) { printer in
                        NavigationLink(value: printer) { PrinterCard(printer: printer) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var filtered: [Printer] {
        var list = farm.activePrinters
        if let filter { list = list.filter { farm.state($0.id) == filter } }
        list = list.filter(inSelectedLocation)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { p in
                [p.name, p.displayModel, p.location ?? "", farm.statuses[p.id]?.jobName ?? ""]
                    .contains { $0.lowercased().contains(q) }
            }
        }
        switch sort {
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .finishing:
            list.sort { (farm.statuses[$0.id]?.isPrinting == true ? farm.statuses[$0.id]?.remainingTime ?? .max : .max)
                < (farm.statuses[$1.id]?.isPrinting == true ? farm.statuses[$1.id]?.remainingTime ?? .max : .max) }
        case .status:
            let order = FarmState.allCases
            list.sort {
                let a = order.firstIndex(of: farm.state($0.id)) ?? 0, b = order.firstIndex(of: farm.state($1.id)) ?? 0
                return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
            }
        }
        return list
    }

    private func inSelectedLocation(_ printer: Printer) -> Bool {
        guard let locationFilter else { return true }
        return (printer.location ?? "") == locationFilter
    }

    private var locationMenu: some View {
        Menu {
            Picker("Location", selection: $locationFilter) {
                Text("All locations").tag(String?.none)
                ForEach(farm.locations, id: \.self) { Text($0.isEmpty ? "No location" : $0).tag(String?.some($0)) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                if let locationFilter { Text(locationFilter.isEmpty ? "None" : locationFilter).lineLimit(1).frame(maxWidth: 110) }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(locationFilter == nil ? Color.bgCard : Color.accentTeal.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(locationFilter == nil ? Color.hairline : Color.accentTeal.opacity(0.6), lineWidth: 0.75))
        }
        .accessibilityLabel(locationFilter.map { "Location filter, \($0.isEmpty ? "no location" : $0)" } ?? "Filter by location")
    }

    private func grouped(_ list: [Printer]) -> [(String, [Printer])] {
        let byLocation = Dictionary(grouping: list) { $0.location ?? "" }
        return farm.locations.compactMap { loc in byLocation[loc].map { (loc, $0) } }
    }

    private func open(_ name: String?) {
        guard let name, let printer = farm.printers.first(where: { $0.name == name }) else { return }
        path = NavigationPath([printer])
        push.openPrinterName = nil
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if farm.can("camera:view"), ServerConfig.serverURL != nil {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { CamWallView() } label: { Image(systemName: "video.fill") }
                    .accessibilityLabel("Camera wall")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Layout", selection: $layoutRaw) {
                    Label("Automatic", systemImage: "wand.and.stars").tag(Layout.auto.rawValue)
                    Label("Cards", systemImage: "rectangle.grid.1x2").tag(Layout.cards.rawValue)
                    Label("Compact", systemImage: "list.bullet").tag(Layout.compact.rawValue)
                }
                Picker("Sort", selection: $sortRaw) {
                    ForEach(Sort.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

// MARK: - Summary

/// One compact line: "7 printing · next done in 12m · 3 idle".
private struct FarmSummaryLine: View {
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        if !farm.activePrinters.isEmpty {
            Text(text)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var text: String {
        var parts = ["\(farm.count(.printing)) printing"]
        if let soonest = farm.printingSoonestFirst.first, let r = farm.statuses[soonest.id]?.remainingTime, r > 0 {
            parts.append("next done in \(formatMinutes(r))")
        }
        let idle = farm.count(.idle)
        if idle > 0 { parts.append("\(idle) idle") }
        let attention = farm.needsAttention.count
        if attention > 0 { parts.append("\(attention) need you") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Status strip

private struct StatusStrip: View {
    @EnvironmentObject private var farm: FarmStore
    @Binding var filter: FarmState?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", count: farm.activePrinters.count, color: .textSecondary, selected: filter == nil) { filter = nil }
                ForEach(FarmState.allCases) { state in
                    let n = farm.count(state)
                    if n > 0 || state == .printing {
                        chip(label: state.label, count: n, color: state.color, selected: filter == state) {
                            filter = filter == state ? nil : state
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(label: String, count: Int, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.subheadline.weight(.medium))
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? color.opacity(0.18) : Color.bgCard, in: Capsule())
            .overlay(Capsule().stroke(selected ? color.opacity(0.6) : Color.hairline, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ConnectionBanner: View {
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        switch farm.connection {
        case .live, .connecting:
            EmptyView()
        case .polling:
            Label("Live updates paused, refreshing every 15 seconds", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Color.textMuted)
        case let .offline(message):
            Card {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Can't reach Bambuddy").font(.subheadline.weight(.semibold))
                        Text(message).font(.caption).foregroundStyle(Color.textMuted)
                    }
                } icon: {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.statusError)
                }
            }
        }
    }
}

// MARK: - Needs attention

private struct NeedsAttentionSection: View {
    @EnvironmentObject private var farm: FarmStore
    let printers: [Printer]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Needs you", trailing: "\(printers.count)")
            ForEach(printers) { printer in
                NavigationLink(value: printer) { row(printer) }.buttonStyle(.plain)
            }
        }
    }

    private func row(_ printer: Printer) -> some View {
        let status = farm.statuses[printer.id]
        let state = farm.state(printer.id)
        return Card(padding: 12) {
            HStack(spacing: 12) {
                Image(systemName: status?.awaitingPlateClear == true && state != .error ? "tray.and.arrow.up.fill" : state.symbol)
                    .font(.title3)
                    .foregroundStyle(state == .error ? Color.statusError : (state == .paused ? Color.statusWarning : Color.statusFinished))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(printer.name).font(.subheadline.weight(.semibold))
                    Text(reason(status, state)).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(2)
                }
                Spacer()
                if status?.awaitingPlateClear == true, farm.can("printers:clear_plate") || farm.canControl {
                    Button("Cleared") { Task { try? await APIClient.shared.clearPlate(printer.id); await farm.refresh() } }
                        .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.small)
                } else if state == .paused, farm.canControl(printer.id) {
                    Button("Resume") { Task { try? await APIClient.shared.resume(printer.id) } }
                        .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
        }
    }

    private func reason(_ status: PrinterStatus?, _ state: FarmState) -> String {
        if let problem = status?.problems.first {
            return problem.description ?? "Printer error \(problem.fullCode ?? problem.code ?? "")"
        }
        if status?.awaitingPlateClear == true {
            return state == .offline ? "Offline · plate still marked as needing a clear." : "Print done. Clear the plate so the queue can continue."
        }
        if state == .paused { return "Paused\(status.map { " at \(Int($0.progress ?? 0))%" } ?? "") · \(status?.jobName ?? "")" }
        return state.label
    }
}

// MARK: - Printer rows

struct PrinterCard: View {
    @EnvironmentObject private var farm: FarmStore
    let printer: Printer

    var body: some View {
        let status = farm.statuses[printer.id]
        let state = farm.state(printer.id)
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StateDot(state: state)
                    Text(printer.name).font(.headline)
                    Text(printer.displayModel).font(.caption).foregroundStyle(Color.textMuted)
                    Spacer()
                    Pill(text: status?.stgCurName?.isEmpty == false && state == .printing ? status!.stgCurName! : state.label,
                         tint: state.color)
                }
                if let status, status.isPrinting {
                    HStack(alignment: .top, spacing: 12) {
                        PrintThumbnail(printerId: printer.id, coverPath: status.coverUrl,
                                       cameraAllowed: farm.can("camera:view"))
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(status.jobName).font(.subheadline.weight(.medium)).lineLimit(1)
                            FarmProgressBar(value: status.progress ?? 0, tint: state == .paused ? .statusWarning : .accentTeal)
                            HStack {
                                Text("\(Int(status.progress ?? 0))%").monospacedDigit()
                                if let total = status.totalLayers, total > 0 {
                                    Text("· \(status.layerNum ?? 0)/\(total)").foregroundStyle(Color.textMuted)
                                }
                                Spacer()
                                if let r = status.remainingTime, r > 0 {
                                    Text(formatMinutes(r))
                                    Text(Date().addingTimeInterval(TimeInterval(r * 60)), format: .dateTime.hour().minute())
                                        .foregroundStyle(Color.textMuted)
                                }
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                } else if let status, status.isConnected {
                    HStack(spacing: 14) {
                        TempLabel(symbol: "flame", value: status.temperature("nozzle"))
                        TempLabel(symbol: "square.stack.3d.down.forward", value: status.temperature("bed"))
                        if let c = status.temperature("chamber"), c > 0 { TempLabel(symbol: "thermometer.medium", value: c) }
                        Spacer()
                        if status.awaitingPlateClear == true { Pill(text: "Clear plate", tint: .statusFinished, systemImage: "tray.and.arrow.up") }
                    }
                    .font(.caption)
                }
                if let problem = status?.problems.first {
                    Label(problem.description ?? "Printer alert", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.statusError).lineLimit(2)
                }
            }
        }
    }
}

struct CompactPrinterRow: View {
    @EnvironmentObject private var farm: FarmStore
    let printer: Printer

    var body: some View {
        let status = farm.statuses[printer.id]
        let state = farm.state(printer.id)
        HStack(spacing: 10) {
            StateDot(state: state).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(printer.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(printer.displayModel).font(.caption2).foregroundStyle(Color.textMuted)
                }
                if let status, status.isPrinting {
                    Text(status.jobName).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                    FarmProgressBar(value: status.progress ?? 0, tint: state == .paused ? .statusWarning : .accentTeal, height: 4)
                } else {
                    Text(status?.problems.first?.description ?? (status?.awaitingPlateClear == true ? "Clear plate" : state.label))
                        .font(.caption).foregroundStyle(state == .error ? Color.statusError : Color.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let status, status.isPrinting {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(status.progress ?? 0))%").font(.subheadline.monospacedDigit().weight(.semibold))
                    if let r = status.remainingTime, r > 0 {
                        Text(formatMinutes(r)).font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct StateDot: View {
    let state: FarmState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 9, height: 9)
            .opacity(state == .printing && pulse ? 0.45 : 1)
            .animation(state == .printing ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel(state.label)
    }
}

struct TempLabel: View {
    let symbol: String
    let value: Double?

    var body: some View {
        if let value {
            Label("\(Int(value.rounded()))°", systemImage: symbol)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
        }
    }
}

struct EmptyStateCard: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title).foregroundStyle(Color.textMuted)
                Text(title).font(.headline)
                Text(message).font(.footnote).foregroundStyle(Color.textMuted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}
