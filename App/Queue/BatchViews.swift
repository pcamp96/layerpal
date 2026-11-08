import SwiftUI

/// A batch ("Cup x 10") in the queue list: name and how far along it is.
struct BatchRow: View {
    let batch: QueueBatch

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: batch.thumbnailPath)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.caption)
                    Text(batch.name).font(.subheadline.weight(.medium)).lineLimit(1)
                }
                FarmProgressBar(value: batch.progressPercent)
                Text(summary).font(.caption).foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts = ["\(batch.completedCount ?? 0)/\(batch.total) done"]
        if let n = batch.printingCount, n > 0 { parts.append("\(n) printing") }
        if let n = batch.pendingCount, n > 0 { parts.append("\(n) queued") }
        if let n = batch.failedCount, n > 0 { parts.append("\(n) failed") }
        return parts.joined(separator: " · ")
    }
}

/// Batch detail: per-plate progress, queue the remaining runs, ungroup, or cancel the lot.
struct BatchDetailView: View {
    let batchId: Int
    @State var initial: QueueBatch?
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [QueueItem] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var pending: PendingAction?

    private var batch: QueueBatch? { initial }

    var body: some View {
        List {
            if let batch {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(batch.name).font(.headline)
                        FarmProgressBar(value: batch.progressPercent)
                        HStack(spacing: 14) {
                            stat("Done", batch.completedCount)
                            stat("Printing", batch.printingCount)
                            stat("Queued", batch.pendingCount)
                            stat("Failed", batch.failedCount)
                            stat("Cancelled", batch.cancelledCount)
                        }
                        if let notes = batch.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(Color.textSecondary) }
                        if let due = batch.dueDate {
                            Label("Due \(due.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                                .font(.footnote).foregroundStyle(Color.textSecondary)
                        }
                        if let by = batch.createdByUsername { Text("Added by \(by)").font(.caption).foregroundStyle(Color.textMuted) }
                    }
                }
                if let plates = batch.plates, plates.count > 1 || batch.hasTargets == true {
                    Section("Plates") {
                        ForEach(plates) { plate in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plate.title).font(.subheadline.weight(.medium))
                                Text("\(plate.completedCount ?? 0)/\(plate.quantityTarget ?? 0) done · \(plate.remaining ?? 0) still to queue")
                                    .font(.caption).foregroundStyle(Color.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Color.accentTeal) }
            Section {
                if let n = batch?.dispatchableCount, n > 0, farm.canQueue {
                    Button { dispatch() } label: { Label("Queue the remaining \(n)", systemImage: "play.rectangle.on.rectangle") }
                }
                if farm.can("queue:update_all") || farm.can("queue:update_own") {
                    Button { confirmUngroup() } label: { Label("Ungroup (keep the jobs)", systemImage: "rectangle.stack.badge.minus") }
                }
                if farm.can("queue:delete_all") {
                    Button(role: .destructive) { confirmCancel() } label: { Label("Cancel batch", systemImage: "xmark.circle") }
                }
            }
            .disabled(busy)
            if !items.isEmpty {
                Section("Jobs in this batch") {
                    ForEach(items) { item in
                        NavigationLink { QueueItemDetailView(item: item) } label: { QueueRow(item: item) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .farmBackground()
        .navigationTitle("Batch")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button(p.button, role: p.destructive ? .destructive : nil) { perform(p) }
        } message: { p in Text(p.message) }
    }

    private func stat(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value ?? 0)").font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(Color.textMuted)
        }
    }

    private func dispatch() {
        Task {
            busy = true
            defer { busy = false }
            do {
                initial = try await APIClient.shared.dispatchBatch(batchId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Done. The batch's remaining runs are in the queue."
                error = nil
                await load()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func confirmUngroup() {
        pending = PendingAction(title: "Ungroup this batch?", message: "The jobs stay in the queue; they just stop being a batch.", button: "Ungroup",
                                destructive: false) {
            _ = try await APIClient.shared.ungroupBatch(batchId)
            dismiss()
            return nil
        }
    }

    private func confirmCancel() {
        pending = PendingAction(title: "Cancel the whole batch?", message: "Pending jobs in it are cancelled. Prints already running are not stopped.",
                                button: "Cancel batch") {
            try await APIClient.shared.cancelBatch(batchId)
            dismiss()
            return nil
        }
    }

    private func perform(_ action: PendingAction) {
        Task {
            busy = true
            defer { busy = false }
            do {
                notice = try await action.run()
                error = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = FriendlyError.message(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func load() async {
        async let fresh = try? APIClient.shared.queueBatch(batchId)
        if let all = try? await APIClient.shared.activeQueue() {
            items = all.filter { $0.batchId == batchId && $0.status != "skipped" }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        }
        if let fresh = await fresh { initial = fresh }
    }
}
