import SwiftUI

/// Pending, running and failed scheduled dryings for one printer, shown under its AMS cards.
/// Listing needs `printers:read`; cancelling or dismissing needs `printers:control`.
struct ScheduledDryingsSection: View {
    let printerId: Int
    let canCancel: Bool
    /// Bump to reload straight away (after scheduling a new run).
    let refresh: Int
    @StateObject private var store = ScheduledDryingStore()
    @State private var target: InsScheduledDrying?

    var body: some View {
        let rows = store.items.filter { $0.printerId == printerId }
        Group {
            if !rows.isEmpty {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Scheduled drying", systemImage: "calendar.badge.clock").font(.subheadline.weight(.semibold))
                        ForEach(rows) { row($0) }
                        if let error = store.error { Text(error).font(.caption).foregroundStyle(Color.statusError) }
                    }
                }
            }
        }
        // Reload now when `refresh` changes, then every 30 s while the printer screen is open.
        .task(id: refresh) {
            while !Task.isCancelled {
                await store.load(printerId: printerId)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                            titleVisibility: .visible, presenting: target) { item in
            Button(item.status == "failed" ? "Dismiss" : (item.status == "running" ? "Stop drying and cancel" : "Cancel schedule"),
                   role: item.status == "failed" ? nil : .destructive) {
                Task { await store.cancel(item, printerId: printerId) }
            }
        } message: { item in
            if item.status == "running" { Text("The AMS stops heating its spools.") }
        }
    }

    private var dialogTitle: String {
        switch target?.status {
        case "failed": "Dismiss this failed run?"
        case "running": "Cancel the running drying?"
        default: "Cancel this scheduled drying?"
        }
    }

    private func amsName(_ id: Int) -> String {
        if id >= 128 { return "AMS HT \(id - 127)" }
        guard id >= 0, id < 26, let scalar = UnicodeScalar(65 + id) else { return "AMS \(id)" }
        return "AMS \(Character(scalar))"
    }

    private func row(_ item: InsScheduledDrying) -> some View {
        let failed = item.status == "failed"
        let running = item.status == "running"
        let tint: Color = failed ? .statusError : .statusWarning
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : (running ? "flame.fill" : "clock.fill"))
                .foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                if failed {
                    Text("Scheduled drying failed").font(.caption.weight(.semibold)).foregroundStyle(tint)
                    Text(item.failedText).font(.caption)
                } else if running {
                    Text("Running").font(.caption.weight(.semibold)).foregroundStyle(tint)
                } else {
                    Text(item.startAfter.map { "Starts \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Starts as soon as possible")
                        .font(.caption.weight(.semibold)).foregroundStyle(tint)
                    if let why = item.waitingText { Text(why).font(.caption).foregroundStyle(Color.textSecondary) }
                }
                Text([amsName(item.amsId), item.filament.isEmpty ? nil : item.filament, "\(item.temp)°C", "\(item.durationHours) h"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 0)
            if canCancel {
                Button { target = item } label: {
                    Image(systemName: failed ? "xmark.circle" : "trash").font(.callout)
                }
                .buttonStyle(.plain).foregroundStyle(Color.textSecondary)
                .accessibilityLabel(failed ? "Dismiss failed drying" : "Cancel scheduled drying")
            }
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class ScheduledDryingStore: ObservableObject {
    @Published private(set) var items: [InsScheduledDrying] = []
    @Published var error: String?

    func load(printerId: Int) async {
        do {
            items = try await APIClient.shared.insScheduledDryings(printerId: printerId)
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            // Keep the last list; a flaky poll shouldn't blank the card.
            if items.isEmpty { self.error = nil } else { self.error = insMessage(error) }
        }
    }

    func cancel(_ item: InsScheduledDrying, printerId: Int) async {
        do {
            try await APIClient.shared.insCancelScheduledDrying(item.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            items.removeAll { $0.id == item.id }
            error = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
        await load(printerId: printerId)
    }
}

/// "Schedule drying": same material presets as the Dry sheet, plus when to start
/// (after a delay, or at a set time; the server takes either as `start_after`).
struct ScheduleDryingSheet: View {
    let unit: AMSUnit
    let printerId: Int
    let anyLoaded: Bool
    let onScheduled: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case delay = "After a delay", atTime = "At a time"
        var id: String { rawValue }
    }

    /// Delay choices (minutes): 15 min up to a day.
    private static let delays: [Int] = [15, 30, 60, 120, 240, 480, 720, 1440]

    @State private var filament = "PLA"
    @State private var temp = 45
    @State private var hours = 12
    @State private var rotate = false
    @State private var mode = Mode.delay
    @State private var delayMinutes = 60
    @State private var startAt = Date().addingTimeInterval(3600)
    @State private var working = false
    @State private var error: String?

    private var isHT: Bool { unit.moduleType == "n3s" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filament") {
                    Picker("Material", selection: $filament) {
                        ForEach(DryingSheet.presets, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    .onChange(of: filament) { _, new in apply(new) }
                }
                Section("Settings") {
                    Stepper(value: $temp, in: 45 ... 85, step: 5) { LabeledContent("Temperature", value: "\(temp)°C") }
                    Stepper(value: $hours, in: 1 ... 24) { LabeledContent("Duration", value: "\(hours) h") }
                    if !anyLoaded { Toggle("Rotate spool during drying", isOn: $rotate) }
                }
                Section("Start") {
                    Picker("Start", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch mode {
                    case .delay:
                        Picker("Wait", selection: $delayMinutes) {
                            ForEach(Self.delays, id: \.self) { Text(delayLabel($0)).tag($0) }
                        }
                    case .atTime:
                        DatePicker("Start at", selection: $startAt, in: Date().addingTimeInterval(120)...)
                    }
                }
                Section {
                    Text("Bambuddy starts the drying cycle when the time comes, even if LayerPal is closed. If the printer is busy or offline it waits and retries.")
                        .font(.footnote).foregroundStyle(Color.textMuted)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.statusError).font(.footnote) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgPrimary)
            .navigationTitle(unit.isHT ? "Schedule AMS HT drying" : "Schedule AMS drying")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button("Schedule") { Task { await submit() } } }
                }
            }
            .onAppear {
                let first = (unit.tray ?? []).first { !$0.isEmpty }?.trayType ?? ""
                filament = DryingSheet.resolve(first)
                apply(filament)
            }
        }
    }

    private func delayLabel(_ minutes: Int) -> String { minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h" }

    private func apply(_ key: String) {
        guard let preset = DryingSheet.presets.first(where: { $0.0 == key })?.1 else { return }
        temp = isHT ? preset.n3s : preset.n3f
        hours = isHT ? preset.n3sHours : preset.n3fHours
    }

    private func submit() async {
        let start = mode == .delay ? Date().addingTimeInterval(Double(delayMinutes) * 60) : startAt
        guard start > Date().addingTimeInterval(30) else {
            error = "Pick a start time in the future."
            return
        }
        working = true
        defer { working = false }
        do {
            try await APIClient.shared.insScheduleDrying(printerId: printerId, amsId: unit.id, temp: temp, hours: hours, filament: filament,
                                                         rotateTray: rotate && !anyLoaded, startAfter: start)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScheduled()
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
    }
}
