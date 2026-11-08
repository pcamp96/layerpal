import SwiftUI

// MARK: Templates

/// Project templates: start a new project from one (copies its settings and parts list).
/// Needs projects:read to list and projects:create to use one.
struct ProjectTemplatesView: View {
    var onCreated: () -> Void = {}
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [Project] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var chosen: Project?
    @State private var newName = ""
    @State private var creating = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) }
                ForEach(templates) { template in
                    Button {
                        newName = template.name.replacingOccurrences(of: " (Template)", with: "")
                        chosen = template
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Circle().fill(template.accent).frame(width: 10, height: 10)
                                Text(template.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            }
                            if let text = template.description, !text.isEmpty {
                                Text(text).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(2)
                            }
                            HStack(spacing: 10) {
                                if let target = template.targetCount { Label("\(target) plates", systemImage: "square.stack.3d.up") }
                                if let priority = template.priority, priority != "normal" { Text(priority.capitalized) }
                                if let budget = template.budget { Text(budget.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))) }
                            }
                            .font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                    .disabled(!farm.can("projects:create"))
                    .listRowBackground(Color.bgCard)
                }
                if loaded, templates.isEmpty, error == nil {
                    ContentUnavailableView("No templates", systemImage: "doc.on.doc",
                                           description: Text("Open a project and choose Save as template."))
                        .listRowBackground(Color.clear)
                }
                if !farm.can("projects:create"), loaded {
                    Label("Your account can't create projects, so templates are read-only.", systemImage: "lock")
                        .font(.footnote).foregroundStyle(Color.textSecondary)
                }
            }
            .listStyle(.insetGrouped)
            .farmBackground()
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .overlay { if !loaded, error == nil { ProgressView() } }
            .task { await load() }
            .refreshable { await load() }
            .alert("New project from template", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
                TextField("Project name", text: $newName)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(chosen?.name ?? "") becomes a new active project with its parts list copied and nothing acquired yet.")
            }
            .disabled(creating)
        }
    }

    private func load() async {
        do {
            templates = try await APIClient.shared.projectTemplates()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func create() {
        guard let template = chosen else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        creating = true
        Task {
            defer { creating = false; chosen = nil }
            do {
                let project = try await APIClient.shared.createProject(fromTemplate: template.id, name: name.isEmpty ? nil : name)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Created \(project.name)."
                onCreated()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                if case APIError.http(403, _) = error {
                    self.error = "Bambuddy refused. Your account needs projects:create, and this app's API key needs the manage-projects scope."
                } else {
                    self.error = FriendlyError.message(error)
                }
            }
        }
    }
}

// MARK: Queue

/// This project's queue items (GET /projects/{id}/queue), with the project's own files below
/// them so they can be queued in one go.
struct ProjectQueueSection: View {
    let projectId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var entries: [ProjectQueueEntry] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Queue", trailing: entries.isEmpty ? nil : "\(entries.count)")
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if entries.isEmpty, loaded, error == nil {
                Card { Text("Nothing from this project is queued.").font(.footnote).foregroundStyle(Color.textMuted) }
            } else if !entries.isEmpty {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                            if index < entries.count - 1 { Divider().padding(.leading, 70) }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .projectQueueChanged)) { _ in Task { await load() } }
    }

    private func row(_ entry: ProjectQueueEntry) -> some View {
        HStack(spacing: 12) {
            RemoteImage(path: entry.thumbnailPath)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(entry.id)").font(.subheadline.weight(.medium))
                    Pill(text: entry.statusLabel, tint: entry.tint)
                }
                Text(destination(entry)).font(.caption).foregroundStyle(Color.textSecondary)
                if let reason = entry.waitingReason, !reason.isEmpty {
                    Text(reason).font(.caption2).foregroundStyle(Color.statusWarning).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func destination(_ entry: ProjectQueueEntry) -> String {
        if let id = entry.printerId, let printer = farm.printers.first(where: { $0.id == id }) { return printer.name }
        if let model = entry.targetModel, !model.isEmpty { return "Any \(Printer.modelNames[model] ?? model)" }
        return "Any printer"
    }

    private func load() async {
        do {
            entries = try await APIClient.shared.projectQueue(projectId)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }
}

extension Notification.Name {
    static let projectQueueChanged = Notification.Name("LayerPal.projectQueueChanged")
}

// MARK: Project files (library folders linked to the project)

/// Sliced files in the folders linked to this project, with how many copies are done, and a
/// button to queue them (POST /library/files/add-to-queue; the print counts toward the project).
struct ProjectFilesSection: View {
    let projectId: Int
    let targetSets: Int?
    @EnvironmentObject private var farm: FarmStore
    @State private var files: [LibFileItem] = []
    @State private var progress: [Int: Int] = [:]
    @State private var folders: [LibFolderNode] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var queuing = false

    private var canRead: Bool { farm.can("library:read_all") || farm.can("library:read_own") }
    private var sliced: [LibFileItem] { files.filter(\.isSliced) }

    var body: some View {
        Group {
            if canRead, !folders.isEmpty || !loaded {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Project files", trailing: files.isEmpty ? nil : "\(files.count)")
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                    if !files.isEmpty {
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                                    row(file)
                                    if index < files.count - 1 { Divider().padding(.leading, 66) }
                                }
                            }
                        }
                        if farm.canQueue, !sliced.isEmpty {
                            Button { queuing = true } label: { Label("Queue project files", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
                        }
                    } else if loaded {
                        Card { Text("The linked folders have no files yet.").font(.footnote).foregroundStyle(Color.textMuted) }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $queuing) {
            ProjectQueueFilesSheet(files: sliced) {
                NotificationCenter.default.post(name: .projectQueueChanged, object: nil)
            }
        }
    }

    private func row(_ file: LibFileItem) -> some View {
        let done = progress[file.id] ?? 0
        return HStack(spacing: 12) {
            RemoteImage(path: file.thumbnailPath == nil ? nil : file.thumbnailAPIPath)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if !file.isSliced { Text("Not sliced") }
                    if let s = file.printTimeSeconds, s > 0 { Text(formatMinutes(s / 60)) }
                    if let g = file.filamentUsedGrams, g > 0 { Text(formatGrams(g)) }
                }
                .font(.caption).foregroundStyle(Color.textMuted)
                if let targetSets, targetSets > 0 {
                    FarmProgressBar(value: min(100, Double(done) / Double(targetSets) * 100), height: 4)
                }
            }
            Spacer(minLength: 0)
            if let targetSets, targetSets > 0 {
                Text("\(done)/\(targetSets)").font(.caption.monospacedDigit()).foregroundStyle(done >= targetSets ? Color.accentTeal : Color.textSecondary)
            } else if done > 0 {
                Pill(text: "\(done)x", tint: .statusFinished, systemImage: "checkmark")
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard canRead else { return }
        do {
            let linked = try await APIClient.shared.libFolders(projectId: projectId)
            folders = linked
            var all: [LibFileItem] = []
            for folder in linked {
                all += (try? await APIClient.shared.libFiles(folderId: folder.id, includeRoot: false)) ?? []
            }
            files = all
            let counts = (try? await APIClient.shared.projectFileProgress(projectId)) ?? []
            progress = Dictionary(uniqueKeysWithValues: counts.map { ($0.fileId, $0.completedCount) })
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }
}

/// Pick files and a printer, then queue them. Needs queue:create.
struct ProjectQueueFilesSheet: View {
    let files: [LibFileItem]
    var onQueued: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var target = QueueTarget()
    @State private var saving = false
    @State private var error: String?
    @State private var result: AddFilesResult?

    init(files: [LibFileItem], onQueued: @escaping () -> Void = {}) {
        self.files = files
        self.onQueued = onQueued
        _selected = State(initialValue: Set(files.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Files") {
                    ForEach(files) { file in
                        Button {
                            if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(file.id) ? Color.accentTeal : Color.textMuted)
                                Text(file.filename).foregroundStyle(.primary).lineLimit(2)
                            }
                        }
                        .accessibilityAddTraits(selected.contains(file.id) ? .isSelected : [])
                    }
                }
                TargetChoiceSection(target: $target, model: nil, allowUnassigned: true)
                if let result {
                    Section {
                        Label("Queued \(result.added.count) file\(result.added.count == 1 ? "" : "s").", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentTeal)
                        ForEach(result.errors, id: \.fileId) { failure in
                            Text("\(failure.filename): \(failure.error)").font(.footnote).foregroundStyle(Color.statusError)
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Queue project files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue \(selected.count)") { queue() }.disabled(saving || selected.isEmpty || result != nil)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func queue() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let ids = files.map(\.id).filter(selected.contains)
                result = try await APIClient.shared.addLibraryFilesToQueue(ids: ids, printerId: target.printerId, targetModel: target.targetModel)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                error = nil
                onQueued()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: Parts list (BOM)

/// Parts to buy or make for a project, with how many are in hand.
struct ProjectBOMSection: View {
    let projectId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var items: [BOMItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: BOMEdit?
    @State private var deleting: BOMItem?

    private struct BOMEdit: Identifiable { let item: BOMItem?; var id: Int { item?.id ?? -1 } }

    private var canWrite: Bool { farm.can("projects:update") }
    private var totalCost: Double { items.reduce(0) { $0 + ($1.lineCost ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Parts list", trailing: items.isEmpty ? nil : "\(items.filter(\.complete).count)/\(items.count) done")
                if canWrite {
                    Button { editing = BOMEdit(item: nil) } label: { Image(systemName: "plus.circle") }.accessibilityLabel("Add part")
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if items.isEmpty, loaded, error == nil {
                Card { Text("No parts yet. Add the screws, magnets and other things this project needs.").font(.footnote).foregroundStyle(Color.textMuted) }
            } else if !items.isEmpty {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < items.count - 1 { Divider().padding(.leading, 14) }
                        }
                        if totalCost > 0 {
                            Divider()
                            HStack {
                                Text("Total").font(.subheadline).foregroundStyle(Color.textMuted)
                                Spacer()
                                Text(totalCost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))).font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $editing) { edit in
            BOMEditSheet(projectId: projectId, item: edit.item) { await load() }
        }
        .confirmationDialog("Delete this part?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete \(item.name)", role: .destructive) { remove(item) }
        } message: { _ in Text("It is removed from this project's parts list.") }
    }

    private func row(_ item: BOMItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.complete ? Color.accentTeal : Color.textMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text("\(item.quantityAcquired) of \(item.quantityNeeded)").monospacedDigit()
                    if let cost = item.lineCost { Text(cost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))) }
                    if let archive = item.archiveName { Label(archive, systemImage: "clock.arrow.circlepath").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
                if let remarks = item.remarks, !remarks.isEmpty { Text(remarks).font(.caption).foregroundStyle(Color.textMuted) }
                if let link = item.sourcingUrl.flatMap(URL.init(string:)) {
                    Link(destination: link) { Label("Where to buy", systemImage: "link").font(.caption) }
                }
            }
            Spacer(minLength: 0)
            if canWrite {
                Stepper("", onIncrement: { setAcquired(item, item.quantityAcquired + 1) }, onDecrement: { setAcquired(item, max(0, item.quantityAcquired - 1)) })
                    .labelsHidden()
                    .accessibilityLabel("Acquired \(item.name)")
                    .accessibilityValue("\(item.quantityAcquired) of \(item.quantityNeeded)")
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .contextMenu {
            if canWrite {
                Button { editing = BOMEdit(item: item) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .onTapGesture { if canWrite { editing = BOMEdit(item: item) } }
    }

    private func setAcquired(_ item: BOMItem, _ value: Int) {
        Task {
            do {
                var patch = LibPatch()
                patch["quantity_acquired"] = .int(value)
                let updated = try await APIClient.shared.updateBOMItem(projectId, item.id, patch)
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = updated }
                UISelectionFeedbackGenerator().selectionChanged()
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = bomError(error)
            }
        }
    }

    private func remove(_ item: BOMItem) {
        Task {
            do {
                try await APIClient.shared.deleteBOMItem(projectId, item.id)
                items.removeAll { $0.id == item.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = bomError(error)
            }
        }
    }

    private func load() async {
        do {
            items = try await APIClient.shared.projectBOM(projectId)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }
}

private func bomError(_ error: Error) -> String {
    if case APIError.http(403, _) = error {
        return "Bambuddy refused. Changing the parts list needs projects:update, and this app's API key needs the manage-projects scope."
    }
    return FriendlyError.message(error)
}

struct BOMEditSheet: View {
    let projectId: Int
    let item: BOMItem?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BOMDraft
    @State private var saving = false
    @State private var error: String?

    init(projectId: Int, item: BOMItem?, onSaved: @escaping () async -> Void) {
        self.projectId = projectId
        self.item = item
        self.onSaved = onSaved
        _draft = State(initialValue: item.map(BOMDraft.init) ?? BOMDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Part") {
                    TextField("Name", text: $draft.name)
                    TextField("Quantity needed", text: $draft.quantity).keyboardType(.numberPad)
                    TextField("Price each (optional)", text: $draft.unitPrice).keyboardType(.decimalPad)
                }
                Section("Where to get it") {
                    TextField("Link (optional)", text: $draft.url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Remarks (optional)", text: $draft.remarks, axis: .vertical)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle(item == nil ? "Add part" : "Edit part")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        if let problem = draft.problem { error = problem; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if let item {
                    let patch = draft.patch(from: item)
                    if !patch.isEmpty { _ = try await APIClient.shared.updateBOMItem(projectId, item.id, patch) }
                } else {
                    _ = try await APIClient.shared.addBOMItem(projectId, draft)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onSaved()
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = bomError(error)
            }
        }
    }
}

// MARK: Timeline

struct ProjectTimelineSection: View {
    let projectId: Int
    @State private var events: [ProjectTimelineEvent] = []
    @State private var expanded = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    SectionHeader(title: "Timeline", trailing: events.isEmpty ? nil : "\(events.count)")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timeline, \(expanded ? "expanded" : "collapsed")")
            if expanded {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: event.symbol).foregroundStyle(Color.accentTeal).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.subheadline)
                                    if let text = event.description, !text.isEmpty { Text(text).font(.caption).foregroundStyle(Color.textSecondary) }
                                    if let when = event.timestamp { Text(when.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Color.textMuted) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .accessibilityElement(children: .combine)
                            if index < events.count - 1 { Divider().padding(.leading, 44) }
                        }
                        if events.isEmpty, loaded { Text("No events yet.").font(.footnote).foregroundStyle(Color.textMuted).padding(12) }
                    }
                }
            }
        }
        .task(id: expanded) {
            guard expanded, !loaded else { return }
            events = (try? await APIClient.shared.projectTimeline(projectId)) ?? []
            loaded = true
        }
    }
}
