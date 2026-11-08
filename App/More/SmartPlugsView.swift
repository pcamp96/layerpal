import SwiftUI
import UIKit

/// Every smart plug Bambuddy knows about, with its linked printer, live state
/// and power reading. Reading needs `smart_plugs:read`; switching needs
/// `smart_plugs:control`. Powering off a plug that feeds a printing printer
/// gets a strong warning.
struct SmartPlugsView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var plugs: [FarmPlug] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var generation = 0
    @State private var pending: PendingSwitch?
    @State private var search = ""

    struct PendingSwitch: Identifiable {
        let plug: FarmPlug
        let turnOn: Bool
        var id: Int { plug.id }
    }

    private var filtered: [FarmPlug] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return plugs }
        return plugs.filter { plug in
            plug.name.lowercased().contains(q) || (printerName(plug)?.lowercased().contains(q) ?? false)
        }
    }

    private var canControl: Bool { farm.can("smart_plugs:control") }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(filtered) { plug in
                SmartPlugRow(plug: plug, printerName: printerName(plug), printing: isPrinting(plug),
                             canControl: canControl, generation: generation) { turnOn in
                    pending = PendingSwitch(plug: plug, turnOn: turnOn)
                }
            }
        }
        .farmBackground()
        .navigationTitle("Smart plugs")
        .searchable(text: $search, prompt: "Plug or printer")
        .overlay {
            if loaded, plugs.isEmpty, error == nil {
                ContentUnavailableView("No smart plugs", systemImage: "powerplug",
                                       description: Text("Add plugs in Bambuddy's Settings."))
            } else if !loaded, error == nil {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(title(for: pending), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { item in
            Button(item.turnOn ? "Turn on" : "Turn off", role: item.turnOn ? nil : .destructive) { apply(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(message(for: item))
        }
    }

    private func printerName(_ plug: FarmPlug) -> String? {
        plug.printerId.flatMap { id in farm.printers.first { $0.id == id }?.name }
    }

    private func isPrinting(_ plug: FarmPlug) -> Bool {
        guard let id = plug.printerId else { return false }
        return farm.statuses[id]?.isPrinting == true
    }

    private func title(for item: PendingSwitch?) -> String {
        guard let item else { return "" }
        return item.turnOn ? "Turn on \(item.plug.name)?" : "Turn off \(item.plug.name)?"
    }

    private func message(for item: PendingSwitch) -> String {
        let printer = printerName(item.plug) ?? "its printer"
        if item.plug.isScript { return "This runs the \(item.plug.name) script." }
        if !item.turnOn, isPrinting(item.plug), item.plug.controlsPrinterPower != false {
            return "\(printer) is printing right now. Cutting its power will ruin the print and can damage the printer. Only do this in an emergency."
        }
        if !item.turnOn, item.plug.printerId != nil { return "\(printer) will lose power." }
        return item.turnOn ? "Power will be switched on." : "Power will be switched off."
    }

    private func apply(_ item: PendingSwitch) {
        Task {
            do {
                try await APIClient.shared.controlSmartPlug(item.plug.id, action: item.turnOn ? "on" : "off")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                generation += 1
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        do {
            plugs = try await APIClient.shared.smartPlugs()
            error = nil
            generation += 1
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

private struct SmartPlugRow: View {
    let plug: FarmPlug
    let printerName: String?
    let printing: Bool
    let canControl: Bool
    let generation: Int
    let onSwitch: (Bool) -> Void

    @State private var status: FarmPlugStatus?

    private var isOn: Bool? {
        let raw = (status?.state ?? plug.lastState)?.uppercased()
        return raw.map { $0 == "ON" }
    }

    private var reachable: Bool { status?.reachable ?? true }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: plug.isScript ? "terminal.fill" : "powerplug.fill")
                .foregroundStyle(reachable ? (isOn == true ? Color.accentTeal : Color.textMuted) : Color.statusError)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(plug.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    if let printerName {
                        Label(printerName, systemImage: "printer").labelStyle(.titleAndIcon)
                    }
                    if printing { Pill(text: "Printing", tint: .accentTeal) }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
                detailLine
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .task(id: generation) { await refresh() }
    }

    @ViewBuilder private var detailLine: some View {
        if !reachable {
            Text("Unreachable").font(.caption).foregroundStyle(Color.statusError)
        } else if let energy = status?.energy, energy.power != nil || energy.today != nil {
            HStack(spacing: 8) {
                if let w = energy.power { Label(String(format: "%.0f W", w), systemImage: "bolt.fill") }
                if let kwh = energy.today { Text(String(format: "%.2f kWh today", kwh)) }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted)
        } else if plug.enabled == false {
            Text("Disabled").font(.caption).foregroundStyle(Color.textMuted)
        }
    }

    @ViewBuilder private var control: some View {
        if plug.isScript {
            if canControl {
                Button("Run") { onSwitch(true) }.buttonStyle(.bordered).controlSize(.small)
            }
        } else if let isOn {
            if canControl, !plug.isMonitorOnly, reachable {
                Toggle("Power", isOn: Binding(get: { isOn }, set: { onSwitch($0) }))
                    .labelsHidden().tint(.accentTeal)
                    .accessibilityLabel("\(plug.name) power")
            } else {
                Pill(text: isOn ? "On" : "Off", tint: isOn ? .accentTeal : .textMuted)
            }
        } else {
            Pill(text: "Unknown", tint: .textMuted)
        }
    }

    private func refresh() async {
        guard !plug.isScript else { return }
        status = try? await APIClient.shared.smartPlugStatus(plug.id)
    }
}
