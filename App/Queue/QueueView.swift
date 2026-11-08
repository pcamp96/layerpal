import SwiftUI

/// A destructive (or heavy) action waiting on a confirmationDialog.
struct PendingAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    var destructive = true
    /// Returns a short note to show after it succeeds.
    let run: () async throws -> String?
}

/// Wait reason the scheduler sets on "Any <model>" jobs held after a failed print.
private let modelGateWaitReason = "The last print failed on every free matching printer"
/// error_message the scheduler writes on jobs skipped behind a failed print.
private let printerGateMessage = "Previous print failed or was aborted"

struct QueueView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var active: [QueueItem] = []
    @State private var history: [QueueItem] = []
    @State private var historyTotal = 0
    @State private var historyStatus: String?
    @State private var historyLoading = false
    @State private var batches: [QueueBatch] = []
    @State private var segment = Segment.upNext
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var adding = false
    @State private var editMode: EditMode = .inactive
    @State private var userId: Int?
    @State private var selecting = false
    @State private var selected = Set<Int>()
    @State private var bulkEditing = false
    @State private var pending: PendingAction?

    private let pageSize = 40

    enum Segment: String, CaseIterable {
        case upNext = "Up next", printing = "Printing", history = "History"
    }

    private var access: QueueAccess { QueueAccess(farm: farm, userId: userId) }

    private var pendingItems: [QueueItem] { active.filter { $0.status == "pending" }.sorted { ($0.position ?? 0) < ($1.position ?? 0) } }

    private var shown: [QueueItem] {
        switch segment {
        case .upNext: pendingItems
        case .printing: active.filter { $0.status == "printing" }
        case .history: history
        }
    }

    /// Printers whose queue is held behind a failed print, with how many jobs were skipped.
    private var gatedPrinters: [(id: Int, name: String, count: Int)] {
        var counts: [Int: (String, Int)] = [:]
        for item in active where item.status == "skipped" && item.errorMessage == printerGateMessage {
            guard let pid = item.printerId else { continue }
            counts[pid] = (item.printerName ?? "Printer \(pid)", (counts[pid]?.1 ?? 0) + 1)
        }
        return counts.map { (id: $0.key, name: $0.value.0, count: $0.value.1) }.sorted { $0.name < $1.name }
    }

    /// Models whose "Any <model>" jobs wait because the last print failed on every free printer.
    private var gatedModels: [(model: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in active where item.status == "pending" && item.printerId == nil && item.waitingReason == modelGateWaitReason {
            if let model = item.targetModel { counts[model, default: 0] += 1 }
        }
        return counts.map { (model: $0.key, count: $0.value) }.sorted { $0.model < $1.model }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Queue", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { s in
                            Text(label(s)).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.statusError)
                }
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(Color.accentTeal)
                }
                if segment == .upNext, farm.can("queue:update_all") { gateBanners }
                if segment == .upNext, !batches.isEmpty, !selecting {
                    Section("Batches") {
                        ForEach(batches) { batch in
                            NavigationLink { BatchDetailView(batchId: batch.id, initial: batch) } label: { BatchRow(batch: batch) }
                        }
                    }
                }
                if shown.isEmpty, !loading, !historyLoading {
                    ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyMessage))
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(shown) { item in
                        rowLink(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingActions(item) }
                            .swipeActions(edge: .leading) { leadingActions(item) }
                            .contextMenu { menu(item) }
                            .onAppear {
                                if segment == .history, item.id == history.last?.id { Task { await loadHistory(reset: false) } }
                            }
                    }
                    .onMove(perform: segment == .upNext && access.canReorder && !selecting ? move : nil)
                    if segment == .history, historyLoading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.bgPrimary)
            .navigationTitle("Queue")
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { if selecting, !selected.isEmpty { selectionBar } }
            .task { await loadAll() }
            .refreshable { await loadAll() }
            .onChange(of: segment) { _, new in
                selecting = false
                selected = []
                if new == .history { Task { await loadHistory(reset: true) } }
            }
            .onChange(of: historyStatus) { _, _ in Task { await loadHistory(reset: true) } }
            .sheet(isPresented: $adding, onDismiss: { Task { await loadAll() } }) { AddJobSheet() }
            .sheet(isPresented: $bulkEditing, onDismiss: { Task { await loadAll() } }) {
                BulkEditSheet(ids: Array(selected)) { selecting = false; selected = [] }
            }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { p in
                Button(p.button, role: p.destructive ? .destructive : nil) { perform(p) }
            } message: { p in Text(p.message) }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var gateBanners: some View {
        ForEach(gatedPrinters, id: \.id) { gate in
            gateRow(text: "\(gate.name): the last print failed, so \(gate.count) queued job\(gate.count == 1 ? " was" : "s were") skipped.") {
                pending = PendingAction(title: "Resume \(gate.name)?", message: "Clears the failed print's hold and puts the skipped jobs back in the queue.",
                                        button: "Resume", destructive: false) {
                    let r = try await APIClient.shared.resumePrinterQueue(gate.id)
                    return "Resumed \(gate.name): \(r.restored ?? 0) job(s) restored."
                }
            }
        }
        ForEach(gatedModels, id: \.model) { gate in
            let name = Printer.modelNames[gate.model] ?? gate.model
            gateRow(text: "\(gate.count) \"Any \(name)\" job\(gate.count == 1 ? " is" : "s are") waiting: the last print failed on every free \(name).") {
                pending = PendingAction(title: "Resume \(name) jobs?", message: "Clears the failed-print hold on every \(name) printer.",
                                        button: "Resume", destructive: false) {
                    _ = try await APIClient.shared.resumeModelQueue(gate.model)
                    return "Resumed \(name) queue."
                }
            }
        }
    }

    private func gateRow(text: String, resume: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
            Text(text).font(.footnote).foregroundStyle(Color.textSecondary)
            Spacer(minLength: 4)
            Button("Resume", action: resume).buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.small)
        }
        .listRowBackground(Color.statusWarning.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if segment == .upNext, !selecting, access.canReorder, shown.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        if segment == .upNext, access.canUpdateAny, shown.count > 1, !editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(selecting ? "Done" : "Select") {
                    withAnimation { selecting.toggle(); selected = [] }
                }
            }
        }
        if segment == .history {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Show", selection: $historyStatus) {
                        Text("All").tag(String?.none)
                        Text("Completed").tag(String?.some("completed"))
                        Text("Failed").tag(String?.some("failed"))
                        Text("Skipped").tag(String?.some("skipped"))
                        Text("Cancelled").tag(String?.some("cancelled"))
                    }
                    if access.canDeleteAny, !history.isEmpty {
                        Divider()
                        Button(role: .destructive) { confirmClearHistory() } label: { Label("Clear history", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: historyStatus == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("History filter and clear")
            }
        }
        if farm.canQueue {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add to queue")
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selected.count) selected").font(.subheadline.weight(.medium))
            Spacer()
            Button { bulkEditing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                .buttonStyle(.bordered)
            Button(role: .destructive) { confirmBulkCancel() } label: { Label("Cancel jobs", systemImage: "xmark") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private func rowLink(_ item: QueueItem) -> some View {
        if selecting {
            Button {
                if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(item.id) ? Color.accentTeal : Color.textMuted)
                    QueueRow(item: item)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
        } else {
            NavigationLink { QueueItemDetailView(item: item) } label: { QueueRow(item: item) }
        }
    }

    private func label(_ s: Segment) -> String {
        let n: Int
        switch s {
        case .upNext: n = pendingItems.count
        case .printing: n = active.filter { $0.status == "printing" }.count
        case .history: return historyTotal > 0 ? "\(s.rawValue) \(historyTotal)" : s.rawValue
        }
        return n > 0 ? "\(s.rawValue) \(n)" : s.rawValue
    }

    private var emptyTitle: String {
        switch segment { case .upNext: "Queue is empty"; case .printing: "Nothing printing from the queue"; case .history: "No history yet" }
    }

    private var emptyMessage: String {
        segment == .upNext && farm.canQueue ? "Tap + to queue a print from your library or past prints." : ""
    }

    // MARK: Row actions

    @ViewBuilder private func trailingActions(_ item: QueueItem) -> some View {
        if item.status == "pending", access.canUpdate(item) {
            Button(role: .destructive) { confirmCancel(item) } label: { Label("Cancel", systemImage: "xmark") }
        }
        if item.status == "printing", access.canUpdate(item) {
            Button(role: .destructive) { confirmStop(item) } label: { Label("Stop", systemImage: "stop.fill") }
        }
        if !["pending", "printing"].contains(item.status), access.canDelete(item) {
            Button(role: .destructive) { confirmRemove(item) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    @ViewBuilder private func leadingActions(_ item: QueueItem) -> some View {
        if item.status == "pending", item.manualStart == true, access.canUpdate(item) {
            Button { startNow(item) } label: { Label("Start", systemImage: "play.fill") }
                .tint(.accentTeal)
        }
        if item.status == "pending", access.canReorder {
            Button { moveToTop(item) } label: { Label("Top", systemImage: "arrow.up.to.line") }.tint(.statusFinished)
        }
    }

    @ViewBuilder private func menu(_ item: QueueItem) -> some View {
        if item.status == "pending", item.manualStart == true, access.canUpdate(item) {
            Button { startNow(item) } label: { Label("Start now", systemImage: "play.fill") }
        }
        if item.status == "pending", access.canReorder {
            Button { moveToTop(item) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
        }
        if item.status == "pending", access.canUpdate(item) {
            Button(role: .destructive) { confirmCancel(item) } label: { Label("Cancel", systemImage: "xmark") }
        }
    }

    private func confirmCancel(_ item: QueueItem) {
        pending = PendingAction(title: "Cancel \(item.name)?", message: "It leaves the queue and moves to history.", button: "Cancel job") {
            try await APIClient.shared.queueAction(item.id, "cancel")
            return nil
        }
    }

    private func confirmStop(_ item: QueueItem) {
        pending = PendingAction(title: "Stop \(item.name)?", message: "This stops the print on \(item.printerName ?? "the printer").", button: "Stop print") {
            try await APIClient.shared.queueAction(item.id, "stop")
            return nil
        }
    }

    private func confirmRemove(_ item: QueueItem) {
        pending = PendingAction(title: "Remove from history?", message: "\(item.name) is removed from the queue history.", button: "Remove") {
            let deleted = try await APIClient.shared.removeQueueItem(item.id)
            return deleted ? nil : "Kept as cancelled: it is the last run of its batch."
        }
    }

    private func confirmBulkCancel() {
        let ids = Array(selected)
        pending = PendingAction(title: "Cancel \(ids.count) job\(ids.count == 1 ? "" : "s")?", message: "Pending jobs leave the queue. Others are skipped.",
                                button: "Cancel \(ids.count)") {
            var failed = 0
            for id in ids {
                do { try await APIClient.shared.queueAction(id, "cancel") } catch { failed += 1 }
            }
            selecting = false
            selected = []
            return failed == 0 ? "Cancelled \(ids.count)." : "Cancelled \(ids.count - failed); \(failed) could not be cancelled."
        }
    }

    private func confirmClearHistory() {
        let status = historyStatus
        pending = PendingAction(title: "Clear \(status.map { "\($0) " } ?? "")history?",
                                message: "Removes every history entry matching this filter (\(historyTotal)). A batch's last run is kept as cancelled.",
                                button: "Clear history") {
            let r = try await APIClient.shared.clearQueueHistory(status: status)
            return "Cleared \(r.cleared)\(r.kept > 0 ? ", kept \(r.kept) for their batch" : "")."
        }
    }

    private func startNow(_ item: QueueItem) {
        Task {
            do {
                try await APIClient.shared.startQueueItem(item.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                error = nil
            } catch {
                if let warning = FriendlyError.filamentWarning(error) {
                    pending = PendingAction(title: "Start anyway?", message: warning, button: "Print anyway") {
                        try await APIClient.shared.startQueueItem(item.id, skipFilamentCheck: true)
                        return nil
                    }
                    return
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
            await loadAll()
        }
    }

    private func perform(_ action: PendingAction) {
        Task {
            do {
                notice = try await action.run()
                error = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                notice = nil
                self.error = FriendlyError.message(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await loadAll()
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = shown.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        reorder(ids)
    }

    private func moveToTop(_ item: QueueItem) {
        var ids = shown.map(\.id)
        ids.removeAll { $0 == item.id }
        ids.insert(item.id, at: 0)
        reorder(ids)
    }

    private func reorder(_ ids: [Int]) {
        Task {
            do {
                try await APIClient.shared.reorderQueue(ids)
                error = nil
            } catch {
                self.error = FriendlyError.message(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await loadAll()
        }
    }

    // MARK: Loading

    private func loadAll() async {
        loading = true
        defer { loading = false }
        if userId == nil { userId = await IdentityCache.shared.userId() }
        do {
            active = try await APIClient.shared.activeQueue()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        batches = (try? await APIClient.shared.queueBatches()) ?? []
        await loadHistory(reset: true)
    }

    private func loadHistory(reset: Bool) async {
        guard !historyLoading else { return }
        if !reset, history.count >= historyTotal { return }
        historyLoading = true
        defer { historyLoading = false }
        do {
            let page = try await APIClient.shared.queueHistory(limit: pageSize, offset: reset ? 0 : history.count, status: historyStatus)
            history = reset ? page.items : history + page.items.filter { new in !history.contains { $0.id == new.id } }
            historyTotal = page.total
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

struct QueueStatusPill: View {
    let item: QueueItem

    var body: some View {
        switch item.status {
        case "pending":
            if item.filamentShort == true {
                Pill(text: "Short on filament", tint: .statusWarning)
            } else if let reason = item.waitingReason, !reason.isEmpty {
                Pill(text: reason, tint: .statusWarning)
            } else if let when = item.scheduledTime, when > Date() {
                Pill(text: when.formatted(date: .abbreviated, time: .shortened), tint: .textSecondary, systemImage: "calendar")
            } else if item.manualStart == true {
                Pill(text: "Waiting for start", tint: .textSecondary)
            } else {
                Pill(text: "Queued", tint: .textSecondary)
            }
        case "printing": Pill(text: "Printing", tint: .accentTeal)
        case "completed": Pill(text: "Done", tint: .accentTeal)
        case "failed": Pill(text: "Failed", tint: .statusError)
        case "skipped": Pill(text: "Skipped", tint: .statusWarning)
        case "cancelled": Pill(text: "Cancelled", tint: .textMuted)
        default: Pill(text: item.status.capitalized)
        }
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: item.thumbnailPath)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "printer").font(.caption2)
                    Text(item.target).lineLimit(1)
                    if let batch = item.batchName, !batch.isEmpty {
                        Image(systemName: "square.stack.3d.up").font(.caption2)
                        Text(batch).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
                HStack(spacing: 8) {
                    QueueStatusPill(item: item)
                    if let s = item.printTimeSeconds, s > 0 {
                        Text(formatMinutes(s / 60)).font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
                    }
                    if let g = item.filamentUsedGrams, g > 0 {
                        Text(formatGrams(g)).font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
                    }
                    if let color = Color(hexRGBA: item.filamentColor?.replacingOccurrences(of: "#", with: "")) {
                        Circle().fill(color).frame(width: 9, height: 9).overlay(Circle().stroke(Color.hairline, lineWidth: 0.5))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pick something to print (library file or past print), then where.
struct AddJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.recent
    @State private var recent: [Archive] = []
    @State private var choice: Choice?

    enum Source: String, CaseIterable { case recent = "Past prints", library = "Library" }

    struct Choice: Identifiable {
        let id = UUID()
        let archiveId: Int?
        let libraryFileId: Int?
        let name: String
        let model: String?
        var plateId: Int? = nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if source == .recent {
                    List(recent) { archive in
                        Button {
                            choice = Choice(archiveId: archive.id, libraryFileId: nil, name: archive.name, model: archive.slicedForModel, plateId: archive.plateId)
                        } label: { ArchiveRow(archive: archive) }
                            .buttonStyle(.plain)
                    }
                    .task { recent = (try? await APIClient.shared.archives(limit: 60)) ?? [] }
                } else {
                    LibraryBrowser(folder: nil) { file in
                        choice = Choice(archiveId: nil, libraryFileId: file.id, name: file.name, model: file.slicedForModel)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("Add to queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $choice) { c in
                TargetPicker(title: c.name, slicedFor: c.model, archiveId: c.archiveId, libraryFileId: c.libraryFileId, initialPlateId: c.plateId) { request in
                    try await APIClient.shared.addToQueue(QueueCreateBody(archiveId: c.archiveId, libraryFileId: c.libraryFileId, request: request))
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            }
        }
    }
}

extension QueueCreateBody {
    /// POST /queue/ body for an archive or library file plus what the picker collected.
    init(archiveId: Int?, libraryFileId: Int?, request: QueueRequest) {
        self.init()
        self.archiveId = archiveId
        self.libraryFileId = libraryFileId
        printerId = request.target.printerId
        targetModel = request.target.printerId == nil ? request.target.targetModel : nil
        quantity = request.quantity
        plateId = request.plateId
        if request.target.printerId != nil, let mapping = request.amsMapping, !mapping.isEmpty {
            amsMapping = mapping
            if request.skipFilamentCheck { skipFilamentCheck = true }
        }
        if request.target.printerId != nil, let rack = request.nozzleRackChoice, !rack.isEmpty { nozzleRackChoice = rack }
        if request.manualStart { manualStart = true }
        if request.requirePreviousSuccess { requirePreviousSuccess = true }
        if request.insertAtTop { insertAtTop = true }
        if let when = request.scheduledTime, case let .string(text) = JSONScalar.date(when) { scheduledTime = text }
        if let o = request.options, o != PrintOptions() {
            bedLevelling = o.bedLevelling.rawValue
            flowCali = o.flowCali.rawValue
            vibrationCali = o.vibrationCali
            layerInspect = o.layerInspect
            timelapse = o.timelapse
            useAms = o.useAms
        }
    }
}

/// Printer choices shared by the add, edit and bulk-edit screens: a specific
/// printer, or "any printer of the model".
struct TargetChoiceSection: View {
    @Binding var target: QueueTarget
    /// Model for the "Any <model>" row (what the file was sliced for, or the job's current model).
    let model: String?
    var allowUnassigned = false
    var allowNoChange = false
    var noChangeSelected = false
    var onNoChange: (() -> Void)?
    @EnvironmentObject private var farm: FarmStore

    private var compatible: [Printer] {
        guard let model, !model.isEmpty else { return farm.activePrinters }
        let name = Printer.modelNames[model] ?? model
        let matches = farm.activePrinters.filter { $0.displayModel == name }
        return matches.isEmpty ? farm.activePrinters : matches
    }

    var body: some View {
        Section("Printer") {
            if allowNoChange {
                row(label: "Leave as is", subtitle: nil, selected: noChangeSelected) { onNoChange?() }
            }
            if let model, !model.isEmpty {
                row(label: "Any \(Printer.modelNames[model] ?? model)", subtitle: "First one that's free",
                    selected: !noChangeSelected && target.printerId == nil && target.targetModel != nil) {
                    target = QueueTarget(printerId: nil, targetModel: model)
                }
            }
            ForEach(compatible) { p in
                row(label: p.name, subtitle: farm.state(p.id).label, selected: !noChangeSelected && target.printerId == p.id) {
                    target = QueueTarget(printerId: p.id, targetModel: nil)
                }
            }
            if allowUnassigned {
                row(label: "Unassigned", subtitle: "Pick a printer later",
                    selected: !noChangeSelected && target.printerId == nil && target.targetModel == nil) {
                    target = QueueTarget(printerId: nil, targetModel: nil)
                }
            }
        }
    }

    private func row(label: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(label)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.textMuted) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentTeal) }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// ASAP, or a date and time (scheduled_time: null = ASAP).
struct ScheduleField: View {
    @Binding var date: Date?
    @State private var enabled = false
    @State private var value = Date().addingTimeInterval(3600)

    var body: some View {
        Toggle("Start at a set time", isOn: $enabled)
            .onChange(of: enabled) { _, on in date = on ? value : nil }
        if enabled {
            DatePicker("Start", selection: $value, in: Date()...)
                .onChange(of: value) { _, v in date = v }
        }
    }

    init(date: Binding<Date?>) {
        _date = date
        _enabled = State(initialValue: date.wrappedValue != nil)
        _value = State(initialValue: date.wrappedValue ?? Date().addingTimeInterval(3600))
    }
}

/// bed levelling / flow calibration / vibration / layer inspection / timelapse / AMS.
struct PrintOptionsForm: View {
    @Binding var options: PrintOptions

    var body: some View {
        Picker("Bed levelling", selection: $options.bedLevelling) {
            ForEach(TriState.allCases) { Text($0.label).tag($0) }
        }
        Picker("Flow calibration", selection: $options.flowCali) {
            ForEach(TriState.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Vibration calibration", isOn: $options.vibrationCali)
        Toggle("Layer inspection", isOn: $options.layerInspect)
        Toggle("Timelapse", isOn: $options.timelapse)
        Toggle("Use AMS", isOn: $options.useAms)
    }
}
