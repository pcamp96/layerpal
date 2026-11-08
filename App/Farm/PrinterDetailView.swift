import SwiftUI

struct PrinterDetailView: View {
    let printerId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var upNext: [QueueItem] = []
    @State private var actionError: String?
    @State private var confirmStop = false
    @State private var editingTemp: TempTarget?
    @State private var busy = false
    @State private var showSkipObjects = false

    struct TempTarget: Identifiable {
        let kind: String
        let label: String
        let nozzle: Int?
        let current: Double?
        var id: String { kind + String(nozzle ?? -1) }
    }

    private var printer: Printer? { farm.printers.first { $0.id == printerId } }
    private var status: PrinterStatus? { farm.statuses[printerId] }
    private var state: FarmState { farm.state(printerId) }
    private var controllable: Bool { farm.canControl(printerId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if status?.isConnected == true {
                    LiveCameraView(printerId: printerId)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                jobCard
                FirmwareBadge(printerId: printerId)
                if status?.isConnected == true { controlCard }
                temperatureCard
                if let status, status.isConnected {
                    AMSSection(printerId: printerId, status: status, controllable: controllable,
                               canRFID: farm.can("printers:ams_rfid"), run: run)
                    HMSAlertsSection(printerId: printerId, problems: status.problems, canControl: controllable, run: run)
                    if controllable {
                        MoreControlsSection(printerId: printerId, model: printer?.displayModel ?? "", status: status, run: run)
                    }
                }
                AdvancedSection(printerId: printerId, printerName: printer?.name ?? "This printer",
                                model: printer?.model, status: status)
                SmartPlugCard(printerId: printerId, printerName: printer?.name ?? "This printer",
                              printing: status?.isPrinting == true, run: run)
                if !upNext.isEmpty { upNextCard }
                if farm.can("printer_sensor_history:read") || farm.can("ams_history:read") {
                    NavigationLink {
                        PrinterHistoryView(printerId: printerId, printerName: printer?.name ?? "Printer")
                    } label: {
                        Card(padding: 12) {
                            HStack {
                                Label("Temperature and AMS history", systemImage: "chart.xyaxis.line")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    ArchiveListView(printerId: printerId, title: "\(printer?.name ?? "Printer") history")
                } label: {
                    Card(padding: 12) {
                        HStack {
                            Label("Print history", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle(printer?.name ?? "Printer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(printer?.name ?? "Printer").font(.headline)
                    HStack(spacing: 4) {
                        StateDot(state: state)
                        Text([printer?.displayModel, printer?.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
        .task { await loadQueue() }
        .refreshable { await farm.refresh(); await loadQueue() }
        .alert("Couldn't do that", isPresented: .constant(actionError != nil), presenting: actionError) { _ in
            Button("OK") { actionError = nil }
        } message: { Text($0) }
        .confirmationDialog("Stop this print?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop print", role: .destructive) { run { try await APIClient.shared.stop(printerId) } }
        } message: {
            Text("\(status?.jobName ?? "The current print") will be cancelled. This can't be undone.")
        }
        .sheet(isPresented: $showSkipObjects) {
            SkipObjectsSheet(printerId: printerId, canSkip: controllable)
        }
        .sheet(item: $editingTemp) { target in
            TemperatureSheet(target: target) { value in
                run { try await APIClient.shared.setTemperature(printerId, kind: target.kind, target: value, nozzle: target.nozzle) }
            }
            .presentationDetents([.height(260)])
        }
    }

    // MARK: Job

    @ViewBuilder private var jobCard: some View {
        Card {
            if let status, status.isPrinting {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteImage(path: status.coverUrl)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Pill(text: status.stgCurName?.isEmpty == false ? status.stgCurName! : state.label, tint: state.color)
                            Text(status.jobName).font(.headline).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text("\(Int(status.progress ?? 0))%").font(.title2.weight(.bold).monospacedDigit())
                    }
                    FarmProgressBar(value: status.progress ?? 0, tint: state == .paused ? .statusWarning : .accentTeal, height: 8)
                    HStack {
                        stat("Layer", status.totalLayers.map { "\(status.layerNum ?? 0) / \($0)" } ?? "–")
                        Spacer()
                        stat("Left", status.remainingTime.map { $0 > 0 ? formatMinutes($0) : "–" } ?? "–")
                        Spacer()
                        stat("Done at", (status.remainingTime ?? 0) > 0
                            ? Date().addingTimeInterval(TimeInterval((status.remainingTime ?? 0) * 60)).formatted(date: .omitted, time: .shortened)
                            : "–")
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: state.symbol).font(.title2).foregroundStyle(state.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state == .offline ? "Offline" : (status?.phase == "finished" ? "Print finished" : (status?.phase == "failed" ? "Print failed" : "Ready")))
                            .font(.headline)
                        Text(status?.jobName.isEmpty == false ? status!.jobName : (state == .offline ? "Bambuddy can't reach this printer." : "Nothing printing."))
                            .font(.footnote).foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    if status?.awaitingPlateClear == true, farm.can("printers:clear_plate") {
                        Button("Plate cleared") { run { try await APIClient.shared.clearPlate(printerId) } }
                            .buttonStyle(.borderedProminent).tint(.accentTeal)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Color.textMuted).textCase(.uppercase)
            Text(value).font(.subheadline.monospacedDigit().weight(.medium))
        }
    }

    // MARK: Controls

    @ViewBuilder private var controlCard: some View {
        if !farm.canControl {
            InfoRow(symbol: "lock", text: "Your Bambuddy account can view this printer but not control it.")
        } else if status?.acceptsControl == false {
            InfoRow(symbol: "eye", text: "Watch-only: this printer isn't in LAN-only Developer Mode, so its firmware rejects commands from Bambuddy.")
        } else if let status {
            Card {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        if status.phase == "paused" {
                            controlButton("Resume", "play.fill", .accentTeal) { try await APIClient.shared.resume(printerId) }
                        } else if status.isPrinting {
                            controlButton("Pause", "pause.fill", .statusWarning) { try await APIClient.shared.pause(printerId) }
                        }
                        if status.isPrinting {
                            Button { confirmStop = true } label: { tileLabel("Stop", "stop.fill", .statusError) }
                                .buttonStyle(.plain)
                        }
                        controlButton(status.chamberLight == true ? "Light on" : "Light off",
                                      status.chamberLight == true ? "lightbulb.fill" : "lightbulb", .statusFinished) {
                            try await APIClient.shared.setLight(printerId, on: !(status.chamberLight ?? false))
                        }
                        if status.isPrinting {
                            Menu {
                                ForEach([(1, "Silent"), (2, "Standard"), (3, "Sport"), (4, "Ludicrous")], id: \.0) { level, name in
                                    Button { run { try await APIClient.shared.setSpeed(printerId, level: level) } } label: {
                                        if status.speedLevel == level { Label(name, systemImage: "checkmark") } else { Text(name) }
                                    }
                                }
                            } label: {
                                tileLabel(speedName(status.speedLevel), "speedometer", .textSecondary)
                            }
                        }
                    }
                    if status.isPrinting {
                        Button { showSkipObjects = true } label: {
                            HStack {
                                Label("Skip objects", systemImage: "square.dashed")
                                Spacer()
                                if let count = status.printableObjectsCount, count > 0 {
                                    Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(Color.textMuted)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(busy)
        }
    }

    private func speedName(_ level: Int?) -> String {
        switch level { case 1: "Silent"; case 3: "Sport"; case 4: "Ludicrous"; default: "Standard" }
    }

    private func controlButton(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () async throws -> Void) -> some View {
        Button { run(action) } label: { tileLabel(title, symbol, tint) }.buttonStyle(.plain)
    }

    private func tileLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Temperatures

    @ViewBuilder private var temperatureCard: some View {
        if let status, status.isConnected {
            let tiles = temperatureTiles(status)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Temperatures")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(tiles) { tile in
                        Button {
                            if controllable { editingTemp = tile }
                        } label: {
                            Card(padding: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tile.label).font(.caption).foregroundStyle(Color.textMuted)
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(tile.current.map { "\(Int($0.rounded()))°" } ?? "–").font(.title3.weight(.semibold).monospacedDigit())
                                        if let t = target(status, tile), t > 0 {
                                            Text("/ \(Int(t))°").font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted)
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!controllable)
                    }
                }
            }
        }
    }

    private func temperatureTiles(_ s: PrinterStatus) -> [TempTarget] {
        var tiles: [TempTarget] = []
        if s.temperature("nozzle_2") != nil {
            tiles.append(TempTarget(kind: "nozzle", label: "Right nozzle", nozzle: 0, current: s.temperature("nozzle")))
            tiles.append(TempTarget(kind: "nozzle", label: "Left nozzle", nozzle: 1, current: s.temperature("nozzle_2")))
        } else {
            tiles.append(TempTarget(kind: "nozzle", label: "Nozzle", nozzle: nil, current: s.temperature("nozzle")))
        }
        tiles.append(TempTarget(kind: "bed", label: "Bed", nozzle: nil, current: s.temperature("bed")))
        if let c = s.temperature("chamber"), c > 0 {
            tiles.append(TempTarget(kind: "chamber", label: "Chamber", nozzle: nil, current: c))
        }
        return tiles
    }

    private func target(_ s: PrinterStatus, _ t: TempTarget) -> Double? {
        switch (t.kind, t.nozzle) {
        case ("nozzle", 1): s.temperature("nozzle_2_target")
        case ("nozzle", _): s.temperature("nozzle_target")
        default: s.temperature("\(t.kind)_target")
        }
    }

    // MARK: Alerts & queue

    private var upNextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Up next on this printer", trailing: "\(upNext.count)")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(upNext.prefix(5).enumerated()), id: \.element.id) { index, item in
                        QueueRow(item: item).padding(.horizontal, 12).padding(.vertical, 8)
                        if index < min(upNext.count, 5) - 1 { Divider().padding(.leading, 64) }
                    }
                }
            }
        }
    }

    private func loadQueue() async {
        upNext = ((try? await APIClient.shared.queue(status: "pending")) ?? []).filter { $0.printerId == printerId }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

struct TraySwatch: View {
    let tray: AMSTray
    var active = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hexRGBA: tray.trayColor) ?? Color.bgRaised)
                    .frame(height: 34)
                if tray.isEmpty {
                    Image(systemName: "minus").foregroundStyle(Color.textMuted)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(active ? Color.accentTeal : Color.hairline, lineWidth: active ? 2 : 0.75))
            Text(tray.isEmpty ? "Empty" : (tray.trayType ?? "?")).font(.caption2.weight(.medium)).lineLimit(1)
            if !tray.isEmpty, let remain = tray.remain, remain >= 0 {
                Text("\(remain)%").font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct InfoRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Card(padding: 12) {
            Label(text, systemImage: symbol).font(.footnote).foregroundStyle(Color.textSecondary)
        }
    }
}

private struct TemperatureSheet: View {
    let target: PrinterDetailView.TempTarget
    let onSet: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Set \(target.label.lowercased()) temperature").font(.headline)
            Text("\(Int(value))°").font(.system(size: 44, weight: .bold).monospacedDigit())
            Slider(value: $value, in: 0 ... maxTemp, step: 5).tint(.accentTeal)
            HStack {
                Button("Turn off") { onSet(0); dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Set") { onSet(Int(value)); dismiss() }.buttonStyle(.borderedProminent).tint(.accentTeal)
            }
        }
        .padding()
        .onAppear { value = (target.current ?? 0).rounded() }
    }

    private var maxTemp: Double {
        switch target.kind { case "bed": 120; case "chamber": 65; default: 320 }
    }
}
