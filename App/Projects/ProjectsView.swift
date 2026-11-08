import SwiftUI

/// Projects list. No NavigationStack of its own: the More tab pushes it.
struct ProjectsView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var projects: [Project] = []
    @State private var statusFilter: String? = "active"
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    @State private var showTemplates = false

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(projects) { project in
                NavigationLink { ProjectDetailView(projectId: project.id, initial: project) } label: { ProjectRow(project: project) }
                    .listRowBackground(Color.bgCard)
            }
            if projects.isEmpty, !loading {
                ContentUnavailableView(statusFilter == nil ? "No projects" : "No \(statusFilter ?? "") projects",
                                       systemImage: "folder",
                                       description: Text(farm.can("projects:create") ? "Tap + to start one." : ""))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .farmBackground()
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $statusFilter) {
                        Text("All").tag(String?.none)
                        Text("Active").tag(String?.some("active"))
                        Text("Completed").tag(String?.some("completed"))
                        Text("Archived").tag(String?.some("archived"))
                    }
                } label: {
                    Image(systemName: statusFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter projects by status")
            }
            if farm.can("projects:create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { creating = true } label: { Label("New project", systemImage: "plus") }
                        Button { showTemplates = true } label: { Label("From template", systemImage: "doc.on.doc") }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New project")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTemplates = true } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Templates")
                }
            }
        }
        .task(id: statusFilter) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { NewProjectSheet() }
        .sheet(isPresented: $showTemplates) { ProjectTemplatesView { Task { await load() } } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            projects = try await APIClient.shared.projects(status: statusFilter)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(project.accent).frame(width: 10, height: 10)
                Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Pill(text: project.statusLabel, tint: project.statusTint)
            }
            if let progress = project.progress, project.targetCount != nil {
                FarmProgressBar(value: progress, tint: project.accent)
            }
            HStack(spacing: 12) {
                if let count = project.archiveCount { Label("\(count) prints", systemImage: "clock.arrow.circlepath") }
                if let target = project.targetCount, let done = project.completedCount {
                    Label("\(done)/\(target) done", systemImage: "checkmark.circle")
                }
                if let queued = project.queueCount, queued > 0 { Label("\(queued) queued", systemImage: "list.bullet") }
            }
            .font(.caption).foregroundStyle(Color.textSecondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var details = ""
    @State private var target = ""
    @State private var priority = ProjectPriority.normal
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $details, axis: .vertical)
                }
                Section {
                    TextField("Target number of plates (optional)", text: $target).keyboardType(.numberPad)
                    Picker("Priority", selection: $priority) {
                        ForEach(ProjectPriority.allCases) { Text($0.label).tag($0) }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await APIClient.shared.createProject(name: name.trimmingCharacters(in: .whitespaces), description: details,
                                                         targetCount: Int(target), priority: priority.rawValue)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            // Creating projects also needs the "manage projects" scope on this app's API key.
            if case APIError.http(403, _) = error {
                self.error = "Bambuddy refused. Your account needs projects:create, and this app's API key needs the manage-projects scope. LayerPal keys are created without it, so make a key with it in Bambuddy's API Keys settings."
            } else {
                self.error = FriendlyError.message(error)
            }
        }
    }
}

struct ProjectDetailView: View {
    let projectId: Int
    @State var initial: Project?
    @EnvironmentObject private var farm: FarmStore
    @State private var archives: [Archive] = []
    @State private var error: String?
    @State private var loadingArchives = false
    @State private var notice: String?

    private var project: Project? { initial }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let project {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(project.accent).frame(width: 12, height: 12)
                            Text(project.name).font(.title3.weight(.semibold))
                        }
                        HStack(spacing: 8) {
                            Pill(text: project.statusLabel, tint: project.statusTint)
                            if let priority = project.priority, priority != "normal" { Pill(text: priority.capitalized, tint: .statusWarning) }
                            if let due = project.dueDate {
                                Pill(text: due.formatted(date: .abbreviated, time: .omitted), tint: .textSecondary, systemImage: "calendar")
                            }
                        }
                        if let text = project.description, !text.isEmpty { Text(text).font(.callout).foregroundStyle(Color.textSecondary) }
                    }
                    statsCard(project)
                    if let notes = project.notes, !notes.isEmpty {
                        SectionHeader(title: "Notes")
                        Card { Text(notes).font(.callout) }
                    }
                    if let url = project.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label(url.absoluteString, systemImage: "link").lineLimit(1) }.font(.subheadline)
                    }
                    ProjectQueueSection(projectId: projectId)
                    ProjectFilesSection(projectId: projectId, targetSets: project.targetSets)
                    ProjectBOMSection(projectId: projectId)
                    ProjectTimelineSection(projectId: projectId)
                }
                SectionHeader(title: "Prints in this project", trailing: archives.isEmpty ? nil : "\(archives.count)")
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) }
                if archives.isEmpty, !loadingArchives {
                    Card { Text("Nothing here yet. Open a print and choose Project to add it.").font(.footnote).foregroundStyle(Color.textMuted) }
                } else {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(archives.enumerated()), id: \.element.id) { index, archive in
                                NavigationLink { ArchiveDetailView(archiveId: archive.id, initial: archive) } label: {
                                    ArchiveRow(archive: archive).padding(.horizontal, 12).padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                if index < archives.count - 1 { Divider().padding(.leading, 76) }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if farm.can("projects:update") || farm.can("projects:create"), let project {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if farm.can("projects:update") {
                            ForEach(["active", "completed", "archived"], id: \.self) { status in
                                Button {
                                    Task { await setStatus(status) }
                                } label: {
                                    Label(status.capitalized, systemImage: project.status == status ? "checkmark" : "circle")
                                }
                            }
                        }
                        if farm.can("projects:create") {
                            Divider()
                            Button { Task { await saveTemplate() } } label: { Label("Save as template", systemImage: "doc.on.doc") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Project actions")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func statsCard(_ project: Project) -> some View {
        let s = project.stats
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                if let progress = project.progress, let target = project.targetCount {
                    Text("\(Int(progress))% of \(target) plates").font(.subheadline.weight(.medium))
                    FarmProgressBar(value: progress, tint: project.accent)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    fact("Completed", s?.completedPrints ?? project.completedCount)
                    fact("Failed", s?.failedPrints ?? project.failedCount)
                    fact("In progress", s?.inProgressPrints)
                    fact("Queued", s?.queuedPrints ?? project.queueCount)
                    if let h = s?.totalPrintTimeHours, h > 0 { fact("Print time", formatHours(h)) }
                    if let g = s?.totalFilamentGrams, g > 0 { fact("Filament", formatGrams(g)) }
                    if let cost = s?.estimatedCost, cost > 0 {
                        fact("Est. cost", cost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")))
                    }
                    if let parts = s?.partsProgressPercent, let target = project.targetPartsCount {
                        fact("Parts", "\(Int(parts))% of \(target)")
                    }
                    if let sets = project.targetSets, sets > 0 { fact("Copies per file", String(sets)) }
                    if let total = s?.bomTotalItems, total > 0 { fact("Parts list", "\(s?.bomCompletedItems ?? 0)/\(total) acquired") }
                    if let bom = s?.bomCost, bom > 0 {
                        fact("Parts cost", bom.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")))
                    }
                    if let kwh = s?.totalEnergyKwh, kwh > 0 { fact("Energy", String(format: "%.2f kWh", kwh)) }
                    if let budget = project.budget, budget > 0 {
                        fact("Budget", budget.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")))
                    }
                }
            }
        }
    }

    @ViewBuilder private func fact(_ label: String, _ value: Int?) -> some View {
        if let value { fact(label, String(value)) }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Color.textMuted).textCase(.uppercase)
            Text(value).font(.subheadline.weight(.medium))
        }
    }

    private func setStatus(_ status: String) async {
        do {
            initial = try await APIClient.shared.setProjectStatus(projectId, status: status)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }

    private func saveTemplate() async {
        do {
            let template = try await APIClient.shared.createTemplate(fromProject: projectId)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            error = nil
            notice = "Saved \(template.name)."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }

    private func load() async {
        loadingArchives = true
        defer { loadingArchives = false }
        async let fresh = try? APIClient.shared.project(projectId)
        do {
            archives = try await APIClient.shared.projectArchives(projectId)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        if let fresh = await fresh { initial = fresh }
    }
}

/// Pick a project for an archive (PATCH /archives/{id} with project_id).
struct ProjectPickerSheet: View {
    let currentId: Int?
    let onPick: (Int?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [Project] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if currentId != nil {
                    Button(role: .destructive) { pick(nil) } label: { Label("Remove from project", systemImage: "minus.circle") }
                }
                ForEach(projects) { project in
                    Button { pick(project.id) } label: {
                        HStack {
                            Circle().fill(project.accent).frame(width: 10, height: 10)
                            Text(project.name)
                            Spacer()
                            if project.id == currentId { Image(systemName: "checkmark").foregroundStyle(Color.accentTeal) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                if projects.isEmpty, loaded, error == nil {
                    ContentUnavailableView("No active projects", systemImage: "folder")
                }
            }
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { projects = try await APIClient.shared.projects(status: "active") } catch { self.error = FriendlyError.message(error) }
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ id: Int?) {
        Task {
            do {
                try await onPick(id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
