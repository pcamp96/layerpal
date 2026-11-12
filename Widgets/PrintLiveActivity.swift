import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LayerPalWidgets: WidgetBundle {
    var body: some Widget {
        PrintsLiveActivity()
    }
}

/// LayerPal teal and status colors (widget-local copies of App/Design/Theme.swift).
private enum Palette {
    static let green = Color(red: 0x12 / 255.0, green: 0xA5 / 255.0, blue: 0x94 / 255.0) // accent teal
    static let warning = Color(red: 0xF2 / 255.0, green: 0xA4 / 255.0, blue: 0x2B / 255.0)
    static let error = Color(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0)
    static let done = Color(red: 0x6E / 255.0, green: 0x8B / 255.0, blue: 0xFF / 255.0)

    static func tint(_ item: PrintItem) -> Color {
        switch item.phase {
        case "paused": warning
        case "error", "failed", "stopped": error
        case "finished": done
        default: green
        }
    }
}

struct PrintsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintsActivityAttributes.self) { context in
            LockScreenCard(state: context.state, isStale: context.isStale, expanded: LiveActivityPrefs.expanded)
                .activityBackgroundTint(Color(red: 0x11 / 255.0, green: 0x15 / 255.0, blue: 0x17 / 255.0).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(state.headline).font(.caption.weight(.semibold)).lineLimit(1).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        FarmBar(state: state)
                        ForEach(state.prints.prefix(3)) { CompactRow(item: $0) }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: state.errors > 0 ? "exclamationmark.triangle.fill" : "printer.fill")
                        .foregroundStyle(state.errors > 0 ? Palette.error : Palette.green)
                    if state.activeCount > 1 { Text("\(state.activeCount)").monospacedDigit() }
                }
            } compactTrailing: {
                if let lead = state.lead {
                    if let finish = lead.finishDate {
                        Text(timerInterval: Date() ... finish, countsDown: true)
                            .monospacedDigit().frame(maxWidth: 52).foregroundStyle(Palette.tint(lead))
                    } else {
                        Text(lead.phaseLabel).font(.caption2).foregroundStyle(Palette.tint(lead))
                    }
                }
            } minimal: {
                if let lead = state.lead { LiveRing(item: lead) }
            }
        }
    }
}

// MARK: - Lock Screen (iOS caps this at 160 pt tall, so it never grows with farm size)

private struct LockScreenCard: View {
    let state: PrintsActivityAttributes.ContentState
    let isStale: Bool
    let expanded: Bool

    var body: some View {
        if expanded {
            // Plain view: tapping now opens the app (the system default).
            expandedBody
        } else {
            // The whole collapsed card is a background button: first tap expands it in place.
            Button(intent: ExpandPrintsActivityIntent()) { collapsedBody }
                .buttonStyle(.plain)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill").foregroundStyle(Palette.green)
            Text(state.headline).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(isStale ? "Waiting for Bambuddy" : "\(Date(timeIntervalSince1970: state.updatedAt), style: .relative) ago")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var collapsedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(state.prints.prefix(2)) { PrintRow(item: $0) }
            HStack {
                let hidden = state.activeCount - min(2, state.prints.filter(\.isActive).count)
                if hidden > 0 { Text("+\(hidden) more") }
                Spacer()
                Text("Tap for details")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(14)
        .contentShape(Rectangle())
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            FarmBar(state: state)
            ForEach(state.prints.prefix(4)) { CompactRow(item: $0) }
            HStack {
                let hidden = state.activeCount - min(4, state.prints.filter(\.isActive).count)
                if hidden > 0 { Text("+\(hidden) more in the app") }
                Spacer()
                Text("Tap to open LayerPal")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(12)
    }
}

/// Real progress for a single print; for a farm, one block per printer colored by state.
private struct FarmBar: View {
    let state: PrintsActivityAttributes.ContentState

    var body: some View {
        // With one active print the split strip is always 100% one color and reads as a finished
        // progress bar, so show that print's real progress instead.
        if state.activeCount <= 1, let only = state.prints.first(where: \.isActive) {
            LiveBar(item: only)
        } else {
            strip
        }
    }

    @ViewBuilder private var strip: some View {
        let segments: [(Int, Color, String)] = [
            (state.errors, Palette.error, "need you"),
            (state.paused, Palette.warning, "paused"),
            (state.printing, Palette.green, "printing"),
        ].filter { $0.0 > 0 }
        let pips = Self.pips(segments.map { ($0.0, $0.1) })
        VStack(alignment: .leading, spacing: 3) {
            // One block per printer (scaled down for big farms), left-aligned with gaps,
            // so it reads as a head count rather than a progress bar.
            GeometryReader { geo in
                let gap: CGFloat = 3
                let fit = (geo.size.width - gap * CGFloat(pips.count - 1)) / CGFloat(max(1, pips.count))
                HStack(spacing: gap) {
                    ForEach(Array(pips.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: min(14, fit))
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 3) {
                        Circle().fill(seg.1).frame(width: 6, height: 6)
                        Text("\(seg.0) \(seg.2)")
                    }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// One color per printer, capped at `cap` blocks; past that each group keeps its share (at least one block).
    static func pips(_ groups: [(Int, Color)], cap: Int = 24) -> [Color] {
        let total = groups.reduce(0) { $0 + $1.0 }
        guard total > 0 else { return [] }
        return groups.flatMap { count, color -> [Color] in
            let n = total <= cap ? count : max(1, Int((Double(count) / Double(total) * Double(cap)).rounded()))
            return Array(repeating: color, count: n)
        }
    }
}

/// Collapsed card row: name, job, bar that animates between updates, countdown.
private struct PrintRow: View {
    let item: PrintItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.printer).font(.footnote.weight(.semibold)).lineLimit(1)
                if !item.jobName.isEmpty {
                    Text(item.jobName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                TimeOrPhase(item: item).font(.caption.monospacedDigit().weight(.medium))
            }
            LiveBar(item: item)
        }
    }
}

/// Expanded card row: one line, so four fit inside the height cap.
private struct CompactRow: View {
    let item: PrintItem

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.tint(item)).frame(width: 6, height: 6)
            Text(item.printer).font(.caption.weight(.semibold)).lineLimit(1)
            Text(item.jobName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if item.isActive {
                Text("\(item.progress)%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if item.totalLayers > 0 {
                    Text("L\(item.layer)/\(item.totalLayers)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            TimeOrPhase(item: item).font(.caption2.monospacedDigit().weight(.medium)).frame(minWidth: 44, alignment: .trailing)
        }
    }
}

private struct TimeOrPhase: View {
    let item: PrintItem

    var body: some View {
        if let finish = item.finishDate, item.phase == "printing" {
            Text(timerInterval: Date() ... finish, countsDown: true)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 70, alignment: .trailing)
        } else {
            Text(item.phaseLabel).foregroundStyle(Palette.tint(item))
        }
    }
}

private struct LiveBar: View {
    let item: PrintItem

    var body: some View {
        if let window = item.liveInterval {
            // Advances by itself from Bambu's estimate; real values correct it on each update.
            ProgressView(timerInterval: window, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(Palette.tint(item))
        } else {
            ProgressView(value: Double(item.progress), total: 100).tint(Palette.tint(item))
        }
    }
}

private struct LiveRing: View {
    let item: PrintItem

    var body: some View {
        if let window = item.liveInterval {
            ProgressView(timerInterval: window, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.circular).tint(Palette.tint(item))
        } else {
            ProgressView(value: Double(item.progress), total: 100).progressViewStyle(.circular).tint(Palette.tint(item))
        }
    }
}
