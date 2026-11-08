import ImageIO
import SwiftUI

/// Every online printer's camera in one scrolling grid, like Bambuddy's Cam Wall.
///
/// Built for 80 printers: the grid is lazy, and each cell refreshes its own
/// snapshot only while it is on screen (its `.task` is cancelled when it scrolls
/// away or the wall is covered). Refreshes are staggered per printer and pass
/// through a small global gate so the server never sees more than a few camera
/// grabs at once. Bambuddy's camera serves one reader at a time and a snapshot
/// taken during a live view returns the live frame, so the wall pauses whenever
/// a live view is open on top of it.
struct CamWallView: View {
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("wall.columns") private var columns = 2
    @AppStorage("wall.interval") private var interval = 8
    @State private var location: String?
    @State private var stateFilter: FarmState?
    @State private var onScreen = false

    struct Route: Hashable { let printerId: Int }

    private var shown: [Printer] {
        farm.activePrinters
            .filter { farm.state($0.id) != .offline }
            .filter { printer in
                guard let location else { return true }
                return (printer.location ?? "") == location
            }
            .filter { stateFilter == nil || farm.state($0.id) == stateFilter }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var active: Bool { onScreen && scenePhase == .active }

    var body: some View {
        let printers = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary(count: printers.count))
                    .font(.footnote).foregroundStyle(Color.textMuted)
                if printers.isEmpty {
                    EmptyStateCard(title: "No cameras to show",
                                   message: "Offline printers are skipped. Try a different filter.",
                                   symbol: "video.slash")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                        ForEach(printers) { printer in
                            NavigationLink(value: Route(printerId: printer.id)) {
                                CamWallCell(printer: printer, status: farm.statuses[printer.id],
                                            state: farm.state(printer.id), columns: columns,
                                            interval: Double(interval), active: active)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .background(Color.bgPrimary)
        .navigationTitle("Camera wall")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Route.self) { CamLiveView(printerId: $0.printerId) }
        .refreshable { await farm.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) { layoutMenu }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private func summary(count: Int) -> String {
        var parts = ["\(count) of \(farm.activePrinters.count) printers"]
        if let stateFilter { parts.append(stateFilter.label) }
        if let location { parts.append(location.isEmpty ? "No location" : location) }
        return parts.joined(separator: " · ")
    }

    private var filterMenu: some View {
        Menu {
            Picker("State", selection: $stateFilter) {
                Text("All states").tag(FarmState?.none)
                ForEach(FarmState.allCases.filter { $0 != .offline }) { Text($0.label).tag(FarmState?.some($0)) }
            }
            if farm.locations.count > 1 {
                Picker("Location", selection: $location) {
                    Text("All locations").tag(String?.none)
                    ForEach(farm.locations, id: \.self) { Text($0.isEmpty ? "No location" : $0).tag(String?.some($0)) }
                }
            }
        } label: {
            Image(systemName: stateFilter != nil || location != nil
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter cameras")
    }

    private var layoutMenu: some View {
        Menu {
            Picker("Columns", selection: $columns) {
                ForEach(1 ... 3, id: \.self) { Text($0 == 1 ? "1 column" : "\($0) columns").tag($0) }
            }
            Picker("Refresh", selection: $interval) {
                Text("Every 5 seconds").tag(5)
                Text("Every 8 seconds").tag(8)
                Text("Every 15 seconds").tag(15)
            }
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityLabel("Wall layout")
    }
}

// MARK: - Cell

private struct CamWallCell: View {
    let printer: Printer
    let status: PrinterStatus?
    let state: FarmState
    let columns: Int
    let interval: Double
    let active: Bool

    @State private var image: UIImage?
    @State private var failures = 0

    private var tiny: Bool { columns >= 3 }
    private var progress: Double { status?.isPrinting == true ? status?.progress ?? 0 : 0 }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: failures > 0 ? "video.slash" : "video").foregroundStyle(.white.opacity(0.4))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Circle().fill(state.color).frame(width: 6, height: 6)
                Text(printer.name).lineLimit(1)
            }
            .font((tiny ? Font.system(size: 10) : .caption).weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(5)
        }
        .overlay(alignment: .bottom) {
            if status?.isPrinting == true {
                VStack(spacing: 3) {
                    HStack {
                        Text("\(Int(progress))%").monospacedDigit()
                        Spacer(minLength: 4)
                        if !tiny, let r = status?.remainingTime, r > 0 { Text(formatMinutes(r)).monospacedDigit() }
                    }
                    .font((tiny ? Font.system(size: 10) : .caption2).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    FarmProgressBar(value: progress, tint: state == .paused ? .statusWarning : .accentTeal, height: 3)
                }
                .padding(.top, 14)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the live camera")
        .accessibilityAddTraits(.isButton)
        .task(id: active) { if active { await refreshLoop() } }
    }

    private var accessibilityText: String {
        var text = "\(printer.name), \(state.label)"
        if status?.isPrinting == true {
            text += ", \(Int(progress)) percent"
            if let r = status?.remainingTime, r > 0 { text += ", \(formatMinutes(r)) left" }
        }
        return text
    }

    /// Runs while the cell is on screen and the wall is frontmost; SwiftUI
    /// cancels it otherwise, which ends both the sleep and any request.
    private func refreshLoop() async {
        // Spread first loads across printers so 20 cells don't hit at once.
        try? await Task.sleep(nanoseconds: UInt64(Double(printer.id % 8) * 0.7 * 1_000_000_000))
        while !Task.isCancelled {
            let ok = await fetchOnce()
            failures = ok ? 0 : min(failures + 1, 3)
            // Back off when a camera can't deliver (disabled, busy, no camera).
            let wait = ok ? interval : min(interval * Double(1 << failures), 45)
            let jitter = Double.random(in: 0 ... 1.5)
            try? await Task.sleep(nanoseconds: UInt64((wait + jitter) * 1_000_000_000))
        }
    }

    private func fetchOnce() async -> Bool {
        await SnapshotGate.shared.acquire()
        defer { Task { await SnapshotGate.shared.release() } }
        guard !Task.isCancelled, let data = await APIClient.shared.cameraSnapshot(printer.id), !Task.isCancelled else { return false }
        let maxPixel = columns == 1 ? 1280 : 640
        let decoded = await Task.detached(priority: .utility) { Self.thumbnail(data, maxPixel: maxPixel) }.value
        guard let decoded, !Task.isCancelled else { return false }
        image = decoded
        return true
    }

    /// Downsamples off the main thread so 80 full-size JPEGs never sit in memory.
    private nonisolated static func thumbnail(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}

/// Caps simultaneous snapshot grabs across the whole wall.
actor SnapshotGate {
    static let shared = SnapshotGate(limit: 4)
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: - Live view

/// Full-size live MJPEG for one printer, with a way into its printer screen.
struct CamLiveView: View {
    let printerId: Int
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        let printer = farm.printers.first { $0.id == printerId }
        let status = farm.statuses[printerId]
        let state = farm.state(printerId)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LiveCameraView(printerId: printerId)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            StateDot(state: state)
                            Text(printer?.name ?? "Printer").font(.headline)
                            Spacer()
                            Pill(text: state.label, tint: state.color)
                        }
                        if let status, status.isPrinting {
                            Text(status.jobName).font(.subheadline).lineLimit(2)
                            FarmProgressBar(value: status.progress ?? 0, tint: state == .paused ? .statusWarning : .accentTeal)
                            HStack {
                                Text("\(Int(status.progress ?? 0))%").monospacedDigit()
                                Spacer()
                                if let r = status.remainingTime, r > 0 { Text("\(formatMinutes(r)) left").monospacedDigit() }
                            }
                            .font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                NavigationLink {
                    PrinterDetailView(printerId: printerId)
                } label: {
                    Label("Open printer", systemImage: "printer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle(printer?.name ?? "Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}
