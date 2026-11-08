import ActivityKit
import Foundation

/// One Live Activity for the whole farm.
///
/// Wire contract with the LayerPal relay (`layerpal-relay/src/events.ts`):
/// attributes-type "PrintsActivityAttributes", attributes {"title"},
/// content-state {"prints": [PrintItem], "printing", "paused", "errors", "updatedAt"}.
/// Rename nothing without changing the relay too.
struct PrintsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The few rows worth showing: problems first, then soonest to finish.
        var prints: [PrintItem]
        /// Farm-wide counts (can exceed the rows shown).
        var printing: Int
        var paused: Int
        var errors: Int
        var updatedAt: Double
    }

    var title: String
}

struct PrintItem: Codable, Hashable, Identifiable {
    var printer: String
    /// printing | paused | error | finished | failed | stopped
    var phase: String
    var progress: Int
    var layer: Int
    var totalLayers: Int
    /// Epoch seconds. With finishAt, iOS animates the bar between updates; 0 = unknown.
    var startAt: Double
    var finishAt: Double
    var jobName: String

    var id: String { printer }
}

extension PrintItem {
    var isActive: Bool { ["preparing", "printing", "paused", "error"].contains(phase) }

    var phaseLabel: String {
        switch phase {
        case "preparing": "Preparing"
        case "printing": "Printing"
        case "paused": "Paused"
        case "error": "Needs attention"
        case "finished": "Done"
        case "failed": "Failed"
        case "stopped": "Stopped"
        default: phase.capitalized
        }
    }

    /// Time window iOS can animate across without any push.
    var liveInterval: ClosedRange<Date>? {
        guard phase == "printing", startAt > 0, finishAt > startAt else { return nil }
        let end = Date(timeIntervalSince1970: finishAt)
        guard end > Date() else { return nil }
        return Date(timeIntervalSince1970: startAt) ... end
    }

    var finishDate: Date? {
        guard isActive, phase != "paused", finishAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: finishAt)
        return date > Date() ? date : nil
    }
}

extension PrintsActivityAttributes.ContentState {
    var activeCount: Int { printing + paused + errors }

    /// The print the compact Dynamic Island follows: a problem if there is one, else the next to finish.
    var lead: PrintItem? { prints.first }

    var headline: String {
        if activeCount == 0 { return prints.count == 1 ? "Print done" : "Prints done" }
        var parts = ["\(printing) printing"]
        if paused > 0 { parts.append("\(paused) paused") }
        if errors > 0 { parts.append("\(errors) need\(errors == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }
}

extension PrintsActivityAttributes.ContentState {
    /// Builds the card from live statuses (used while the app is open).
    static func from(_ statuses: [(name: String, status: PrinterStatusSnapshot)], now: Date = Date()) -> Self {
        let t = now.timeIntervalSince1970
        var items: [PrintItem] = statuses.compactMap { name, s in
            guard s.isActive else { return nil }
            let finish = s.remainingMinutes > 0 ? t + Double(s.remainingMinutes * 60) : 0
            var start = 0.0
            if s.phase == "printing", finish > t {
                let p = Double(s.progress) / 100
                start = p <= 0 ? t : (p < 0.995 ? finish - (finish - t) / (1 - p) : 0)
            }
            return PrintItem(printer: name, phase: s.phase, progress: s.progress, layer: s.layer, totalLayers: s.totalLayers,
                             startAt: start, finishAt: finish, jobName: s.jobName)
        }
        let rank = ["error": 0, "paused": 1, "printing": 2, "preparing": 2]
        items.sort {
            let a = rank[$0.phase] ?? 3, b = rank[$1.phase] ?? 3
            if a != b { return a < b }
            return ($0.finishAt == 0 ? .infinity : $0.finishAt) < ($1.finishAt == 0 ? .infinity : $1.finishAt)
        }
        return Self(prints: Array(items.prefix(4)),
                    printing: items.filter { $0.phase == "printing" || $0.phase == "preparing" }.count,
                    paused: items.filter { $0.phase == "paused" }.count,
                    errors: items.filter { $0.phase == "error" }.count,
                    updatedAt: t)
    }
}

/// The bits of a printer status the card needs (kept free of app-only types so the widget can compile it).
struct PrinterStatusSnapshot {
    var phase: String
    var progress: Int
    var remainingMinutes: Int
    var layer: Int
    var totalLayers: Int
    var jobName: String
    var isActive: Bool { ["preparing", "printing", "paused", "error"].contains(phase) }
}
