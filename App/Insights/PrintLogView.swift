import SwiftUI

/// The print log: one row per print event (reprints and runs of deleted archives included).
/// Needs `archives:read_own|read_all`; deleting needs `archives:delete_own|delete_all`, clearing `archives:delete_all`.
/// Place it inside an existing NavigationStack.
struct PrintLogView: View {
    @EnvironmentObject private var farm: FarmStore
    @StateObject private var model = PrintLogModel()
    @State private var query = APIClient.InsPrintLogQuery()
    @State private var searchText = ""
    @State private var window = 0 // days; 0 = any time
    @State private var selected: InsPrintLogEntry?
    @State private var deleteTarget: InsPrintLogEntry?
    @State private var confirmClear = false
    @State private var me: Me?

    private var canRead: Bool { farm.can("archives:read_all") || farm.can("archives:read_own") }
    private var canClear: Bool { farm.can("archives:delete_all") }

    private func canEdit(_ entry: InsPrintLogEntry) -> Bool {
        if farm.can("archives:update_all") { return true }
        guard farm.can("archives:update_own") else { return false }
        return entry.createdById != nil && entry.createdById == me?.id
    }

    private func canDelete(_ entry: InsPrintLogEntry) -> Bool {
        if farm.can("archives:delete_all") { return true }
        guard farm.can("archives:delete_own") else { return false }
        // Own-only users may delete just their runs; the server answers 403 otherwise.
        return entry.createdById != nil && entry.createdById == me?.id
    }

    private static let sorts: [(key: String, title: String)] = [
        ("date", "Date"), ("print_name", "Name"), ("printer", "Printer"), ("status", "Status"), ("duration", "Duration"),
        ("filament_used", "Filament used"), ("cost", "Cost"), ("energy", "Energy"),
    ]

    var body: some View {
        List {
            if !canRead {
                Section { Text("Your Bambuddy account can't read the print log.").foregroundStyle(Color.textMuted) }
            }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.statusError).font(.footnote) }
            }
            if !model.items.isEmpty {
                Section {
                    ForEach(model.items) { entry in
                        Button { selected = entry } label: { row(entry) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.bgCard)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canDelete(entry) {
                                    Button(role: .destructive) { deleteTarget = entry } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                            .task {
                                if entry.id == model.items.last?.id { await model.loadMore(query) }
                            }
                    }
                    if model.loadingMore { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
                } header: {
                    Text("\(model.total) \(model.total == 1 ? "print" : "prints")")
                }
            } else if model.loaded, model.error == nil {
                Section { Text(isFiltered ? "No prints match these filters." : "No prints logged yet.").foregroundStyle(Color.textMuted) }
            }
        }
        .farmBackground()
        .navigationTitle("Print log")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if model.loading, model.items.isEmpty { ProgressView() } }
        .searchable(text: $searchText, prompt: "Search by print name")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .task(id: searchText) {
            // Debounce typing; the first run (empty text) goes straight through.
            if !searchText.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            query.search = searchText
        }
        .task(id: query) { if canRead { await model.reload(query) } }
        .onChange(of: canRead) { _, ok in if ok, !model.loaded { Task { await model.reload(query) } } }
        .task { me = try? await APIClient.shared.me(); await InsCurrency.refresh() }
        .refreshable { await model.reload(query) }
        .sheet(item: $selected) { entry in
            PrintLogDetailSheet(entry: entry, archiveDeleted: model.deletedArchiveIds.contains(entry.archiveId ?? -1), canEdit: canEdit(entry)) {
                selected = nil
                Task { await model.reload(query) }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Delete this print from the log?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { entry in
            Button("Delete log entry", role: .destructive) { Task { await model.delete(entry, query) } }
        } message: { entry in
            Text("\(entry.title) drops out of the statistics. The archive itself is not touched.")
        }
        .confirmationDialog("Clear the whole print log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear print log", role: .destructive) { Task { await model.clear(query) } }
        } message: {
            Text("Every logged print you can see is removed and the statistics reset. Archives and the queue are not touched. This can't be undone.")
        }
    }

    private var isFiltered: Bool { !query.search.isEmpty || query.status != nil || query.printerId != nil || query.dateFrom != nil }

    private var menu: some View {
        Menu {
            Picker("Status", selection: $query.status) {
                Text("Any status").tag(String?.none)
                ForEach(InsStatus.all, id: \.self) { Text(InsStatus.label($0)).tag(String?.some($0)) }
            }
            Picker("Printer", selection: $query.printerId) {
                Text("Any printer").tag(Int?.none)
                ForEach(farm.printers) { Text($0.name).tag(Int?.some($0.id)) }
            }
            Picker("Period", selection: $window) {
                Text("Any time").tag(0)
                Text("Last 7 days").tag(7)
                Text("Last 30 days").tag(30)
                Text("Last 90 days").tag(90)
            }
            .onChange(of: window) { _, days in query.dateFrom = days == 0 ? nil : Self.utcStamp(daysAgo: days) }
            Picker("Sort by", selection: $query.sortBy) {
                ForEach(Self.sorts, id: \.key) { Text($0.title).tag($0.key) }
            }
            Picker("Order", selection: $query.descending) {
                Text("Newest / highest first").tag(true)
                Text("Oldest / lowest first").tag(false)
            }
            if canClear {
                Divider()
                Button("Clear print log…", role: .destructive) { confirmClear = true }
            }
        } label: {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter and sort")
    }

    /// created_at is stored as naive UTC, so send the cutoff the same way.
    private static func utcStamp(daysAgo: Int) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86400))
    }

    private func row(_ entry: InsPrintLogEntry) -> some View {
        HStack(spacing: 12) {
            RemoteImage(path: entry.thumbnailPath == nil ? nil : "print-log/\(entry.id)/thumbnail")
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([entry.printerName, entry.whenText?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                HStack(spacing: 8) {
                    Pill(text: InsStatus.label(entry.status), tint: tint(entry.status))
                    if let s = entry.durationSeconds, s > 0 { Text(formatMinutes(s / 60)).font(.caption).foregroundStyle(Color.textSecondary) }
                    if let g = entry.filamentUsedGrams, g > 0 { Text(formatGrams(g)).font(.caption).foregroundStyle(Color.textSecondary) }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows details")
    }

    private func tint(_ status: String) -> Color {
        switch status {
        case "completed": .accentTeal
        case "failed", "aborted": .statusError
        default: .statusWarning
        }
    }
}

private struct PrintLogDetailSheet: View {
    let entry: InsPrintLogEntry
    let archiveDeleted: Bool
    let canEdit: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @AppStorage(InsCurrency.key) private var currency = InsCurrency.code

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        RemoteImage(path: entry.thumbnailPath == nil ? nil : "print-log/\(entry.id)/thumbnail", contentMode: .fit)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.headline)
                            Pill(text: InsStatus.label(entry.status), tint: entry.status == "completed" ? .accentTeal : (entry.status == "failed" ? .statusError : .statusWarning))
                        }
                    }
                }
                Section("Run") {
                    row("Printer", entry.printerName)
                    row("Started", entry.startedAt?.formatted(date: .abbreviated, time: .shortened))
                    row("Finished", entry.completedAt?.formatted(date: .abbreviated, time: .shortened))
                    row("Duration", entry.durationSeconds.map { formatMinutes($0 / 60) })
                    row("Plate", entry.plateId.map { "Plate \($0)" })
                    row("Quantity", entry.quantity.map { "\($0)" })
                    row("Started by", entry.createdByUsername)
                    if archiveDeleted { row("Archive", "Deleted (the run stays logged)") }
                }
                Section("Filament and cost") {
                    row("Material", entry.filamentType)
                    row("Used", entry.filamentUsedGrams.map { formatGrams($0) })
                    row("Filament cost", money(entry.cost))
                    row("Energy", entry.energyKwh.map { String(format: "%.3f kWh", $0) })
                    row("Energy cost", money(entry.energyCost))
                    row("Wear cost", money(entry.wearCost))
                    row("Total cost", money(entry.totalCost))
                }
                if let reason = entry.failureReason, !reason.isEmpty {
                    Section("Failure") { Text(insFailureReasonLabel(reason)) }
                }
                if let verdict = entry.userVerdict, !verdict.isEmpty {
                    Section("Quality verdict") { Text(verdict == "good" ? "Good print" : (verdict == "reject" ? "Rejected" : verdict.capitalized)) }
                }
                if let notes = entry.notes, !notes.isEmpty { Section("Notes") { Text(notes) } }
            }
            .farmBackground()
            .navigationTitle("Print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canEdit { ToolbarItem(placement: .topBarLeading) { Button("Edit") { editing = true } } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $editing) { PrintLogEditSheet(entry: entry, archiveDeleted: archiveDeleted, onSaved: onSaved) }
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(title, value: value) }
    }

    private func money(_ v: Double?) -> String? { v.map { $0.formatted(.currency(code: currency)) } }
}

@MainActor
final class PrintLogModel: ObservableObject {
    @Published private(set) var items: [InsPrintLogEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var deletedArchiveIds: Set<Int> = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var loaded = false
    @Published var error: String?

    private var generation = 0
    private let pageSize = 50

    func reload(_ query: APIClient.InsPrintLogQuery) async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let page = try await APIClient.shared.insPrintLog(query, limit: pageSize, offset: 0)
            guard mine == generation else { return }
            items = page.items
            total = page.total
            deletedArchiveIds = Set(page.deletedArchiveIds ?? [])
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            guard mine == generation else { return }
            self.error = insMessage(error)
            loaded = true
        }
    }

    func loadMore(_ query: APIClient.InsPrintLogQuery) async {
        guard !loadingMore, !loading, items.count < total else { return }
        let mine = generation
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await APIClient.shared.insPrintLog(query, limit: pageSize, offset: items.count)
            guard mine == generation else { return }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            total = page.total
            deletedArchiveIds.formUnion(page.deletedArchiveIds ?? [])
        } catch {
            if mine == generation, !(error is CancellationError) { self.error = insMessage(error) }
        }
    }

    func delete(_ entry: InsPrintLogEntry, _ query: APIClient.InsPrintLogQuery) async {
        do {
            try await APIClient.shared.insDeletePrintLogEntry(entry.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            items.removeAll { $0.id == entry.id }
            total = max(0, total - 1)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
    }

    func clear(_ query: APIClient.InsPrintLogQuery) async {
        do {
            _ = try await APIClient.shared.insClearPrintLog()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await reload(query)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
    }
}
