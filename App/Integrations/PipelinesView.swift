import SwiftUI
import UIKit

extension PipeStatus.Tint {
    var color: Color {
        switch self {
        case .good: .accentTeal
        case .busy: .statusFinished
        case .bad: .statusError
        case .warn: .statusWarning
        case .neutral: .textMuted
        }
    }
}

/// Slicer pipelines (Bambuddy: Pipeline Runs). Reading runs needs `pipelines:read`; starting, cancelling
/// and retrying need `pipelines:run`, which an API key only carries when it can queue AND manage the
/// library. Authoring pipelines and clearing run history (`pipelines:write`) are admin-only, so they go through the admin session.
struct PipelinesView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var runs: [PipeRun] = []
    @State private var total = 0
    @State private var pipelines: [PipePipeline] = []
    @State private var statusFilter: String?
    @State private var loaded = false
    @State private var error: String?
    @State private var startFor: PipePipeline?
    @State private var loadingMore = false
    @ObservedObject private var session = AdminSession.shared
    @StateObject private var runner = AdminActionRunner()
    @State private var managing = false
    @State private var confirmClear = false
    @State private var clearedMessage: String?

    /// Shown unless the signed-in account is known to lack pipelines:write (a key never has it).
    private var canAuthor: Bool { !session.isSignedIn || session.can("pipelines:write") }

    private let pageSize = 25
    private let statuses = ["queued", "slicing", "dispatching", "in_progress", "completed", "partial_failure", "failed", "cancelled"]

    private var canRun: Bool { farm.can("pipelines:run") }

    var body: some View {
        Group {
            if !farm.can("pipelines:read") {
                ContentUnavailableView("Not available for this key", systemImage: "lock.fill",
                                       description: Text("LayerPal's Bambuddy login doesn't have pipelines:read."))
            } else {
                content
            }
        }
        .background(Color.bgPrimary)
        .navigationTitle("Pipelines")
        .toolbar {
            if farm.can("pipelines:read"), canAuthor {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { managing = true } label: { Label("Manage pipelines", systemImage: "slider.horizontal.3") }
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear finished runs", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Pipeline actions")
                }
            }
        }
        .navigationDestination(isPresented: $managing) {
            PipelineManagerView { pipelines = []; await load() }
        }
        .confirmationDialog("Clear finished runs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear finished runs", role: .destructive) { clearRuns() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every completed, failed, cancelled and partly failed run you're allowed to cancel. Active runs and their queue jobs stay. This needs a Bambuddy sign-in.")
        }
        .alert("Run history", isPresented: Binding(get: { clearedMessage != nil }, set: { if !$0 { clearedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(clearedMessage ?? "") }
        .adminActions(runner)
    }

    private func clearRuns() {
        runner.run {
            let deleted = try await AdminSession.shared.perform { try await APIClient.shared.clearPipelineRuns(bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            clearedMessage = deleted == 0 ? "No finished runs to clear." : "Cleared \(deleted) run\(deleted == 1 ? "" : "s")."
            await load()
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError).padding(.horizontal, 4) }
                if let message = runner.error { Text(message).font(.footnote).foregroundStyle(Color.statusError).padding(.horizontal, 4) }
                if !pipelines.isEmpty {
                    SectionHeader(title: "Pipelines", trailing: "\(pipelines.count)")
                    ForEach(pipelines) { pipeline in pipelineCard(pipeline) }
                }
                HStack {
                    SectionHeader(title: "Runs", trailing: total > 0 ? "\(total)" : nil)
                    Menu {
                        Button("All statuses") { statusFilter = nil }
                        ForEach(statuses, id: \.self) { s in Button(PipeStatus.label(s)) { statusFilter = s } }
                    } label: {
                        Label(statusFilter.map(PipeStatus.label) ?? "Filter", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.footnote)
                    }
                    .accessibilityLabel("Filter runs by status")
                }
                if runs.isEmpty, loaded {
                    Card { Text(statusFilter == nil ? "No pipeline runs yet" : "No runs with this status").font(.subheadline).foregroundStyle(Color.textMuted) }
                }
                ForEach(runs) { run in
                    NavigationLink { PipeRunDetailView(runId: run.id, canRun: canRun) { await load() } } label: { runRow(run) }
                        .buttonStyle(.plain)
                }
                if runs.count < total {
                    Button { Task { await loadMore() } } label: {
                        HStack { Spacer(); if loadingMore { ProgressView() } else { Text("Load more") }; Spacer() }
                    }
                    .buttonStyle(.bordered).disabled(loadingMore)
                }
            }
            .padding()
        }
        .overlay { if !loaded, error == nil { ProgressView() } }
        .onChange(of: statusFilter) { _, _ in Task { await load() } }
        .sheet(item: $startFor) { pipeline in
            NavigationStack { PipeStartSheet(pipeline: pipeline) { await load() } }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .refreshable { await load() }
    }

    private func pipelineCard(_ pipeline: PipePipeline) -> some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pipeline.name).font(.subheadline.weight(.semibold))
                    if let d = pipeline.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Color.textSecondary) }
                    Text("\(pipeline.targetText) · \(pipeline.fanoutText)").font(.caption).foregroundStyle(Color.textMuted)
                }
                Spacer()
                if canRun {
                    Button { startFor = pipeline } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.small)
                        .accessibilityLabel("Run \(pipeline.name)")
                }
            }
        }
    }

    private func runRow(_ run: PipeRun) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(run.pipelineName ?? "Pipeline run").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Pill(text: run.statusLabel, tint: run.statusTint.color)
                }
                if let file = run.sourceFilename { Text(file).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1) }
                if run.copies > 1 || run.isActive {
                    FarmProgressBar(value: Double(run.copiesCompleted ?? 0) / Double(max(1, run.copies)) * 100, tint: run.statusTint.color)
                }
                HStack(spacing: 8) {
                    Text("\(run.copiesCompleted ?? 0)/\(run.copies) done")
                    if let f = run.copiesFailed, f > 0 { Text("\(f) failed").foregroundStyle(Color.statusError) }
                    if let c = run.copiesCancelled, c > 0 { Text("\(c) cancelled") }
                    Spacer()
                    if let created = run.createdAt { Text(created.formatted(.relative(presentation: .named))) }
                }
                .font(.caption).foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            if pipelines.isEmpty { pipelines = (try? await APIClient.shared.pipePipelines()) ?? [] }
            let page = try await APIClient.shared.pipeRuns(limit: max(pageSize, runs.count), offset: 0, status: statusFilter)
            runs = page.runs
            total = page.total ?? page.runs.count
            error = nil
        } catch {
            if !Task.isCancelled { self.error = AdminError.friendly(error) }
        }
        loaded = true
    }

    private func loadMore() async {
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await APIClient.shared.pipeRuns(limit: pageSize, offset: runs.count, status: statusFilter)
            runs += page.runs.filter { new in !runs.contains { $0.id == new.id } }
            total = page.total ?? total
        } catch { self.error = AdminError.friendly(error) }
    }
}

// MARK: - Run detail

private struct PipeRunDetailView: View {
    let runId: Int
    let canRun: Bool
    var onChanged: () async -> Void

    @State private var run: PipeRun?
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var busy = false
    @State private var retried: PipeRun?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if let run {
                    summary(run)
                    if canRun, run.isActive || run.canRetry { actions(run) }
                    if let message = run.errorMessage, !message.isEmpty {
                        SectionHeader(title: "Log")
                        Card { Text(message).font(.footnote.monospaced()).textSelection(.enabled) }
                    }
                    SectionHeader(title: "Copies", trailing: "\(run.jobs?.count ?? 0)")
                    ForEach(run.jobs ?? []) { job in Card { jobRow(job) } }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("Run #\(runId)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(run?.isActive == false ? 30 : 4))
            }
        }
        .refreshable { await load() }
        .confirmationDialog("Cancel this run?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel run", role: .destructive) { cancel() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Queued copies are cancelled. Prints already running keep going on the printer until you stop them.")
        }
        .navigationDestination(item: $retried) { new in PipeRunDetailView(runId: new.id, canRun: canRun, onChanged: onChanged) }
    }

    private func summary(_ run: PipeRun) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(run.pipelineName ?? "Pipeline run").font(.headline)
                    Spacer()
                    Pill(text: run.statusLabel, tint: run.statusTint.color)
                }
                if let file = run.sourceFilename { Text(file).font(.subheadline).foregroundStyle(Color.textSecondary) }
                FarmProgressBar(value: Double(run.copiesCompleted ?? 0) / Double(max(1, run.copies)) * 100, tint: run.statusTint.color)
                Text("\(run.copiesCompleted ?? 0) of \(run.copies) done"
                    + ((run.copiesFailed ?? 0) > 0 ? " · \(run.copiesFailed ?? 0) failed" : "")
                    + ((run.copiesCancelled ?? 0) > 0 ? " · \(run.copiesCancelled ?? 0) cancelled" : "")
                    + ((run.copiesInProgress ?? 0) > 0 ? " · \(run.copiesInProgress ?? 0) running" : ""))
                    .font(.caption).foregroundStyle(Color.textMuted)
                if run.eligibilityOverridden == true { Pill(text: "Eligibility overridden", tint: .statusWarning, systemImage: "exclamationmark.triangle") }
                if let parent = run.parentRunId { Text("Retry of run #\(parent)").font(.caption).foregroundStyle(Color.textMuted) }
                Group {
                    if let d = run.createdAt { Text("Created \(d.formatted(date: .abbreviated, time: .shortened))") }
                    if let d = run.startedAt { Text("Started \(d.formatted(date: .abbreviated, time: .shortened))") }
                    if let d = run.completedAt { Text("Finished \(d.formatted(date: .abbreviated, time: .shortened))") }
                }
                .font(.caption).foregroundStyle(Color.textMuted)
            }
        }
    }

    private func actions(_ run: PipeRun) -> some View {
        VStack(spacing: 8) {
            if run.isActive {
                Button(role: .destructive) { confirmCancel = true } label: { Label("Cancel run", systemImage: "xmark.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(busy)
            }
            if run.canRetry {
                Button { retry() } label: { Label("Retry failed copies", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(busy)
            }
        }
    }

    private func jobRow(_ job: PipeJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Copy \((job.copyIndex ?? 0) + 1)").font(.subheadline.weight(.semibold))
                Spacer()
                Pill(text: PipeStatus.label(job.status), tint: PipeStatus.tint(job.status).color)
            }
            if let name = job.assignedPrinterName { Label(name, systemImage: "printer").font(.caption).foregroundStyle(Color.textSecondary) }
            if let message = job.errorMessage, !message.isEmpty { Text(message).font(.caption).foregroundStyle(Color.statusError) }
            if let d = job.completedAt ?? job.dispatchedAt {
                Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            run = try await APIClient.shared.pipeRun(runId)
            error = nil
        } catch { if !Task.isCancelled { self.error = AdminError.friendly(error) } }
    }

    private func cancel() {
        busy = true
        Task {
            defer { busy = false }
            do {
                run = try await APIClient.shared.pipeCancel(runId)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await onChanged()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func retry() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let new = try await APIClient.shared.pipeRetryFailed(runId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onChanged()
                retried = new
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Start a run

private struct PipeStartSheet: View {
    let pipeline: PipePipeline
    var onStarted: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [LibFileItem] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var selected: LibFileItem?
    @State private var copies = 1
    @State private var running = false
    @State private var error: String?
    @State private var blocked: PipeEligibility?

    private var filtered: [LibFileItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? files : files.filter { $0.filename.lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                Stepper("Copies: \(copies)", value: $copies, in: 1 ... 100)
            } footer: {
                Text("Bambuddy slices the file with \(pipeline.name), then queues one print per copy. \(pipeline.targetText).")
            }
            if let blocked {
                Section("Not eligible") {
                    ForEach(blocked.lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(Color.statusWarning) }
                    Button("Run anyway", role: .destructive) { start(force: true) }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            Section("Source file") {
                if !loaded { ProgressView() }
                ForEach(filtered) { file in
                    Button {
                        selected = file
                        blocked = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.filename).font(.subheadline).lineLimit(2)
                                if let type = file.fileType { Text(type.uppercased()).font(.caption2).foregroundStyle(Color.textMuted) }
                            }
                            Spacer()
                            if selected?.id == file.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentTeal) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(selected?.id == file.id ? .isSelected : [])
                }
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Library file")
        .navigationTitle("Run \(pipeline.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if running { ProgressView() } else { Button("Run") { start(force: false) }.disabled(selected == nil) }
            }
        }
        .task {
            do { files = try await APIClient.shared.libFiles(folderId: nil, includeRoot: false, recursive: true).sorted { $0.date > $1.date } }
            catch { self.error = AdminError.friendly(error) }
            loaded = true
        }
    }

    private func start(force: Bool) {
        guard let selected else { return }
        running = true
        error = nil
        Task {
            defer { running = false }
            do {
                switch try await APIClient.shared.pipeStartRun(pipelineId: pipeline.id, libraryFileId: selected.id, copies: copies, force: force) {
                case .started:
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    await onStarted()
                    dismiss()
                case let .blocked(report):
                    blocked = report
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
