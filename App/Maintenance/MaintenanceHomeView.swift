import SwiftUI

/// Maintenance: farm summary plus every printer's items, due and warning first.
/// Pushed from More (no NavigationStack of its own).
struct MaintenanceHomeView: View {
    init() {}

    @EnvironmentObject private var farm: FarmStore
    @State private var summary: MaintSummary?
    @State private var overview: [MaintOverview] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var markDone: MaintStatus?

    private var access: MaintAccess { MaintAccess(farm: farm) }
    private var sorted: [MaintOverview] {
        overview.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.printerName.localizedStandardCompare($1.printerName) == .orderedAscending }
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if loaded { summarySection }
            ForEach(sorted) { printer in
                Section {
                    let items = printer.activeItems
                    if items.isEmpty {
                        Text(printer.maintenanceItems.isEmpty ? "Nothing tracked" : "All items disabled").font(.footnote).foregroundStyle(Color.textMuted)
                    }
                    ForEach(items) { item in
                        NavigationLink {
                            MaintenanceItemView(item: item) { Task { await load() } }
                        } label: { MaintItemRow(item: item) }
                            .swipeActions(edge: .leading) {
                                if access.canUpdate {
                                    Button { markDone = item } label: { Label("Done", systemImage: "checkmark") }.tint(.accentTeal)
                                }
                            }
                    }
                } header: {
                    NavigationLink { MaintenancePrinterView(printerId: printer.printerId) } label: {
                        HStack {
                            Text(printer.printerName)
                            Spacer()
                            Text("\(Int(printer.totalPrintHours))h printed").textCase(nil)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                    }
                    .accessibilityHint("Opens this printer's maintenance")
                }
            }
        }
        .farmBackground()
        .navigationTitle("Maintenance")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { MaintenanceTypesView() } label: { Image(systemName: "list.bullet.rectangle") }
                    .accessibilityLabel("Maintenance types")
            }
        }
        .overlay { if loaded, overview.isEmpty, error == nil { ContentUnavailableView("Nothing tracked", systemImage: "wrench.and.screwdriver") } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $markDone) { item in
            MarkDoneSheet(item: item) { await load() }
        }
    }

    @ViewBuilder private var summarySection: some View {
        if let summary {
            Section {
                HStack(spacing: 12) {
                    stat("\(summary.totalDue)", "Due", summary.totalDue > 0 ? .statusError : .accentTeal)
                    stat("\(summary.totalWarning)", "Coming up", summary.totalWarning > 0 ? .statusWarning : .accentTeal)
                    stat("\(overview.count)", "Printers", .textSecondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.semibold)).foregroundStyle(tint)
                Text(label).font(.caption).foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            async let s = APIClient.shared.maintSummary()
            async let o = APIClient.shared.maintOverviewAll()
            summary = try await s
            overview = try await o
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }
}

/// One maintenance item line: status icon, name, when it is due.
struct MaintItemRow: View {
    let item: MaintStatus
    var showPrinter = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDue ? "exclamationmark.circle.fill" : (item.isWarning ? "clock.badge.exclamationmark" : item.symbol))
                .foregroundStyle(item.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.maintenanceTypeName).font(.subheadline)
                Text((showPrinter ? item.printerName + " · " : "") + item.dueText)
                    .font(.caption).foregroundStyle(item.isDue || item.isWarning ? item.tint : Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Optional notes, then POST /maintenance/items/{id}/perform.
struct MarkDoneSheet: View {
    let item: MaintStatus
    var onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.maintenanceTypeName).font(.headline)
                    Text(item.printerName).font(.subheadline).foregroundStyle(Color.textSecondary)
                } footer: { Text("This resets the counter to now and logs it in the item's history.") }
                Section("Notes (optional)") {
                    TextField("What you did", text: $notes, axis: .vertical).lineLimit(2 ... 6)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Mark done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark done") { perform() }.disabled(busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func perform() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.maintPerform(item.id, notes: notes)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

/// One printer's maintenance, including disabled items. Print hours can be corrected; custom types can be assigned.
struct MaintenancePrinterView: View {
    let printerId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var overview: MaintOverview?
    @State private var types: [MaintType] = []
    @State private var error: String?
    @State private var markDone: MaintStatus?
    @State private var settingHours = false
    @State private var hoursText = ""

    private var access: MaintAccess { MaintAccess(farm: farm) }
    private var assignable: [MaintType] {
        let have = Set((overview?.maintenanceItems ?? []).map(\.maintenanceTypeId))
        return types.filter { !have.contains($0.id) }
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let overview {
                Section {
                    LabeledContent("Print hours", value: String(format: "%.1f h", overview.totalPrintHours))
                    LabeledContent("Due now", value: "\(overview.dueCount)")
                    LabeledContent("Coming up", value: "\(overview.warningCount)")
                }
                Section("Items") {
                    ForEach(overview.maintenanceItems.sorted { $0.urgency < $1.urgency }) { item in
                        NavigationLink {
                            MaintenanceItemView(item: item) { Task { await load() } }
                        } label: { MaintItemRow(item: item) }
                            .swipeActions(edge: .leading) {
                                if access.canUpdate, item.enabled {
                                    Button { markDone = item } label: { Label("Done", systemImage: "checkmark") }.tint(.accentTeal)
                                }
                            }
                    }
                }
            }
        }
        .farmBackground()
        .navigationTitle(overview?.printerName ?? "Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if access.canCreate || access.canUpdate {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if access.canCreate, !assignable.isEmpty {
                            Menu("Add maintenance type") {
                                ForEach(assignable) { type in Button(type.name) { assign(type) } }
                            }
                        }
                        if access.canUpdate {
                            Button {
                                hoursText = String(format: "%.1f", overview?.totalPrintHours ?? 0)
                                settingHours = true
                            } label: { Label("Set print hours", systemImage: "clock") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Printer maintenance actions")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $markDone) { item in MarkDoneSheet(item: item) { await load() } }
        .alert("Set print hours", isPresented: $settingHours) {
            TextField("Total hours", text: $hoursText).keyboardType(.decimalPad)
            Button("Save") { saveHours() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Corrects the printer's total print hours, which maintenance intervals count from.") }
    }

    private func load() async {
        do {
            overview = try await APIClient.shared.maintPrinter(printerId)
            types = (try? await APIClient.shared.maintTypes()) ?? types
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func assign(_ type: MaintType) {
        Task {
            do {
                try await APIClient.shared.maintAssign(printerId: printerId, typeId: type.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func saveHours() {
        guard let hours = Double(hoursText.replacingOccurrences(of: ",", with: ".")), hours >= 0 else {
            error = "Enter the total print hours as a number."
            return
        }
        Task {
            do {
                try await APIClient.shared.maintSetHours(printerId: printerId, totalHours: hours)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }
}
