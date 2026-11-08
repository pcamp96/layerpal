import SwiftUI

/// "Advanced" disclosure on the printer screen: rows that open the motion, calibration, nozzle and
/// storage sheets, plus links to Bambuddy's web pages. Control rows only show when the account can
/// control this printer (not watch-only / cloud mode); nozzle info and links are read-only and
/// always available.
struct AdvancedSection: View {
    let printerId: Int
    let printerName: String
    let model: String?
    let status: PrinterStatus?
    @EnvironmentObject private var farm: FarmStore

    @State private var expanded = false
    @State private var sheet: Destination?
    @State private var web: AdvSafariDestination?

    enum Destination: String, Identifiable {
        case motion, calibration, nozzles, files
        var id: String { rawValue }
    }

    private var connected: Bool { status?.isConnected == true }
    private var canControl: Bool { connected && farm.canControl(printerId) }
    private var canBrowseFiles: Bool { connected && farm.can("printers:files") && status?.acceptsControl != false }
    private var isDual: Bool { status?.temperature("nozzle_2") != nil }
    private var hasNozzleInfo: Bool {
        connected && (isDual || !(status?.nozzleRack ?? []).isEmpty || !(status?.nozzles ?? []).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Advanced")
            Card(padding: 0) {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(spacing: 0) {
                        if canControl {
                            row("Move & home", "arrow.up.and.down.and.arrow.left.and.right", .motion)
                            Divider()
                            row("Calibration", "scope", .calibration, detail: activeStage)
                            Divider()
                        }
                        if hasNozzleInfo {
                            row(isDual ? "Nozzles & extruder" : "Nozzle", "circle.hexagongrid", .nozzles)
                            Divider()
                        }
                        if canBrowseFiles {
                            row("Printer storage", "internaldrive", .files)
                            Divider()
                        }
                        if let archiveId = status?.currentArchiveId, status?.isPrinting == true,
                           let url = APIClient.shared.gcodeViewerURL(archiveId: archiveId) {
                            linkRow("Open G-code viewer", "cube.transparent", url)
                            Divider()
                        }
                        if APIClient.shared.overlayURL(printerId: printerId) != nil {
                            OverlayLinkRows(printerId: printerId) { web = AdvSafariDestination(url: $0) }
                            Divider()
                        }
                        if let url = APIClient.shared.webAppURL() {
                            linkRow("Open in Bambuddy", "safari", url)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Motion, calibration, nozzles, storage, web", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline.weight(.medium))
                }
                .tint(Color.textMuted)
                .padding(14)
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .motion:
                MotionSheet(printerId: printerId, model: model, printing: status?.isPrinting == true,
                            nozzleTemp: status?.temperature("nozzle"))
            case .calibration:
                if let status { CalibrationLive(printerId: printerId, isDual: isDual, fallback: status) }
            case .nozzles:
                NozzlesSheet(printerId: printerId, model: model, canSelect: canControl)
            case .files:
                PrinterFilesSheet(printerId: printerId, printerName: printerName)
            }
        }
        .sheet(item: $web) { destination in
            AdvSafariView(url: destination.url).ignoresSafeArea()
        }
    }

    private var activeStage: String? {
        guard let stg = status?.stgCur, stg > 0, stg != 255, let name = status?.stgCurName, !name.isEmpty else { return nil }
        return name
    }

    private func row(_ title: String, _ symbol: String, _ destination: Destination, detail: String? = nil) -> some View {
        Button { sheet = destination } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(Color.statusWarning).lineLimit(1) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
            }
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { web = AdvSafariDestination(url: url) } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Color.textMuted)
            }
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens in Safari")
    }
}

/// Reads the live status so the calibration stage updates while the sheet is open.
private struct CalibrationLive: View {
    let printerId: Int
    let isDual: Bool
    let fallback: PrinterStatus
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        CalibrationSheet(printerId: printerId, status: farm.statuses[printerId] ?? fallback, isDualNozzle: isDual)
    }
}
