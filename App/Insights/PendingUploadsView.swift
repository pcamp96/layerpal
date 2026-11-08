import SwiftUI

/// Files received from virtual printers (queue mode) that wait to be archived or discarded.
/// Reading needs `queue:read_own|read_all`, archiving `queue:create`, discarding `queue:delete_all`.
/// Place it inside an existing NavigationStack.
struct PendingUploadsView: View {
    @EnvironmentObject private var farm: FarmStore
    @StateObject private var model = PendingUploadsModel()
    @State private var archiveTarget: InsPendingUpload?
    @State private var discardTarget: InsPendingUpload?
    @State private var confirmArchiveAll = false
    @State private var confirmDiscardAll = false

    private var canRead: Bool { farm.can("queue:read_all") || farm.can("queue:read_own") }
    private var canArchive: Bool { farm.can("queue:create") }
    private var canDiscard: Bool { farm.can("queue:delete_all") }

    var body: some View {
        List {
            if !canRead {
                Section { Text("Your Bambuddy account can't see pending uploads.").foregroundStyle(Color.textMuted) }
            }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.statusError).font(.footnote) }
            }
            if let notice = model.notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal).font(.footnote) }
            }
            if model.items.isEmpty, model.loaded, model.error == nil {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(Color.textMuted)
                        Text("Nothing waiting").font(.headline)
                        Text("Files sent to a virtual printer in queue mode show up here until you archive them.")
                            .font(.footnote).foregroundStyle(Color.textMuted).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                .listRowBackground(Color.clear)
            }
            if !model.items.isEmpty {
                Section {
                    ForEach(model.items) { item in
                        Button { if canArchive { archiveTarget = item } } label: { row(item) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.bgCard)
                            .swipeActions(edge: .leading) {
                                if canArchive {
                                    Button { archiveTarget = item } label: { Label("Archive", systemImage: "archivebox") }.tint(.accentTeal)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if canDiscard {
                                    Button(role: .destructive) { discardTarget = item } label: { Label("Discard", systemImage: "trash") }
                                }
                            }
                    }
                } header: {
                    Text("\(model.items.count) waiting")
                } footer: {
                    if canArchive { Text("Tap a file to archive it with tags, notes and a project. Swipe to discard.") }
                }
            }
        }
        .farmBackground()
        .navigationTitle("Pending uploads")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if model.loading, !model.loaded { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !model.items.isEmpty, canArchive || canDiscard {
                    Menu {
                        if canArchive { Button("Archive all…", systemImage: "archivebox") { confirmArchiveAll = true } }
                        if canDiscard { Button("Discard all…", systemImage: "trash", role: .destructive) { confirmDiscardAll = true } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Bulk actions")
                }
            }
        }
        // Re-run once permissions arrive (opening this before the farm loads would otherwise show nothing).
        .task(id: canRead) { if canRead { await model.load() } }
        .refreshable { await model.load() }
        .sheet(item: $archiveTarget) { item in
            ArchivePendingSheet(item: item, canListProjects: farm.can("projects:read")) { tags, notes, project in
                await model.archive(item, tags: tags, notes: notes, projectId: project)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Discard \(discardTarget?.displayName ?? "this file")?", isPresented: Binding(get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }),
                            titleVisibility: .visible, presenting: discardTarget) { item in
            Button("Discard file", role: .destructive) { Task { await model.discard(item) } }
        } message: { _ in
            Text("The received file is deleted from the server. This can't be undone.")
        }
        .confirmationDialog("Archive all \(model.items.count) files?", isPresented: $confirmArchiveAll, titleVisibility: .visible) {
            Button("Archive all") { Task { await model.archiveAll() } }
        } message: {
            Text("Each file becomes an archive without tags or notes.")
        }
        .confirmationDialog("Discard all \(model.items.count) files?", isPresented: $confirmDiscardAll, titleVisibility: .visible) {
            Button("Discard all", role: .destructive) { Task { await model.discardAll() } }
        } message: {
            Text("Every waiting file is deleted from the server. This can't be undone.")
        }
    }

    private func row(_ item: InsPendingUpload) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper").font(.title3).foregroundStyle(Color.accentTeal)
                .frame(width: 36, height: 36)
                .background(Color.accentTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file),
                      item.sourceIp.map { "from \($0)" },
                      item.uploadedAt?.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Color.textMuted)
                if item.displayName != item.filename { Text(item.filename).font(.caption2).foregroundStyle(Color.textMuted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if canArchive { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(canArchive ? "Opens archive options" : "")
    }
}

private struct ArchivePendingSheet: View {
    let item: InsPendingUpload
    let canListProjects: Bool
    let onArchive: (String?, String?, Int?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""
    @State private var notes = ""
    @State private var projectId: Int?
    @State private var projects: [Project] = []
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.displayName).font(.headline)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
                }
                Section("Tags") {
                    TextField("Comma-separated", text: $tags).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Notes") { TextField("Optional", text: $notes, axis: .vertical).lineLimit(2 ... 5) }
                if canListProjects, !projects.isEmpty {
                    Section("Project") {
                        Picker("Project", selection: $projectId) {
                            Text("None").tag(Int?.none)
                            ForEach(projects) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                    }
                }
            }
            .navigationTitle("Archive file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Archive") {
                            working = true
                            Task {
                                let ok = await onArchive(tags.isEmpty ? nil : tags, notes.isEmpty ? nil : notes, projectId)
                                working = false
                                if ok { dismiss() }
                            }
                        }
                    }
                }
            }
            .task {
                if canListProjects { projects = (try? await APIClient.shared.projects(status: "active")) ?? [] }
            }
        }
    }
}

@MainActor
final class PendingUploadsModel: ObservableObject {
    @Published private(set) var items: [InsPendingUpload] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published var error: String?
    @Published var notice: String?

    func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await APIClient.shared.insPendingUploads()
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = insMessage(error)
        }
        loaded = true
    }

    /// Returns true when the file was archived (the sheet closes on success, stays open on a server error).
    func archive(_ item: InsPendingUpload, tags: String?, notes: String?, projectId: Int?) async -> Bool {
        do {
            try await APIClient.shared.insArchivePending(item.id, tags: tags, notes: notes, projectId: projectId)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            items.removeAll { $0.id == item.id }
            notice = "Archived \(item.displayName)."
            error = nil
            return true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
            return false
        }
    }

    func discard(_ item: InsPendingUpload) async {
        do {
            try await APIClient.shared.insDiscardPending(item.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            items.removeAll { $0.id == item.id }
            notice = nil
            error = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
    }

    func archiveAll() async {
        do {
            let r = try await APIClient.shared.insArchiveAllPending()
            UINotificationFeedbackGenerator().notificationOccurred(r.failed > 0 ? .warning : .success)
            notice = "Archived \(r.archived) \(r.archived == 1 ? "file" : "files")" + (r.failed > 0 ? ", \(r.failed) failed." : ".")
            error = nil
            await load()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
    }

    func discardAll() async {
        do {
            try await APIClient.shared.insDiscardAllPending()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            notice = nil
            error = nil
            await load()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = insMessage(error)
        }
    }
}

/// Count of files waiting in pending uploads, for the badge on the More row.
/// `PendingUploadsBadge.count()` returns 0 when the user can't read the list or the call fails.
struct PendingUploadsBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.accentTeal, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityLabel("\(count) pending")
        }
    }

    /// GET /pending-uploads/count (queue:read_own | read_all).
    static func count() async -> Int { (try? await APIClient.shared.insPendingCount()) ?? 0 }
}
