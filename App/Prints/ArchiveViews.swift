import AVKit
import SwiftUI

/// Who may edit or delete one archive, from the user's permission strings.
@MainActor
struct ArchiveAccess {
    let farm: FarmStore
    let userId: Int?

    private func owns(_ archive: Archive?) -> Bool { archive?.createdById != nil && archive?.createdById == userId }

    func canUpdate(_ archive: Archive?) -> Bool {
        farm.can("archives:update_all") || (farm.can("archives:update_own") && (userId == nil || owns(archive)))
    }

    func canDelete(_ archive: Archive?) -> Bool {
        farm.can("archives:delete_all") || (farm.can("archives:delete_own") && (userId == nil || owns(archive)))
    }
}

/// Prints tab and per-printer history.
struct ArchiveListView: View {
    var printerId: Int?
    var title = "Prints"
    @EnvironmentObject private var farm: FarmStore
    @State private var archives: [Archive] = []
    @State private var search = ""
    @State private var statusFilter: String?
    @State private var printerFilter: Int?
    @State private var favoritesOnly = false
    @State private var reachedEnd = false
    @State private var loading = false
    @State private var error: String?
    @State private var mergeCount = 0
    @State private var selecting = false
    @State private var picked: [Int] = []
    @State private var showMerge = false
    @State private var showCalendar = false
    @State private var comparing: ComparePick?
    @State private var exportFile: ExportFile?
    @State private var exporting = false

    private struct ComparePick: Identifiable { let ids: [Int]; var id: String { ids.map(String.init).joined(separator: ",") } }
    private struct ExportFile: Identifiable { let url: URL; var id: URL { url } }

    private var canRead: Bool { farm.can("archives:read_all") || farm.can("archives:read_own") }
    private var canMerge: Bool { farm.can("archives:update_all") && farm.can("archives:delete_all") }

    private var effectivePrinter: Int? { printerId ?? printerFilter }
    private var filtering: Bool { statusFilter != nil || favoritesOnly || printerFilter != nil }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if mergeCount > 0, canMerge, printerId == nil, !selecting {
                Button { showMerge = true } label: {
                    Label("\(mergeCount) group\(mergeCount == 1 ? "" : "s") of duplicate prints can be merged", systemImage: "arrow.triangle.merge")
                        .font(.footnote)
                }
                .listRowBackground(Color.bgCard)
            }
            if selecting {
                Label(picked.count < 2 ? "Pick 2 to 5 prints to compare" : "\(picked.count) selected", systemImage: "rectangle.split.2x1")
                    .font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.bgCard)
            }
            ForEach(visible) { archive in
                Group {
                    if selecting {
                        Button { togglePick(archive.id) } label: {
                            HStack {
                                Image(systemName: picked.contains(archive.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(archive.id) ? Color.accentTeal : Color.textMuted)
                                ArchiveRow(archive: archive, showPrinter: printerId == nil)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked.contains(archive.id) ? .isSelected : [])
                    } else {
                        NavigationLink { ArchiveDetailView(archiveId: archive.id, initial: archive) } label: {
                            ArchiveRow(archive: archive, showPrinter: printerId == nil)
                        }
                    }
                }
                .onAppear { if archive.id == visible.last?.id { Task { await loadMore() } } }
                .listRowBackground(Color.bgPrimary)
            }
            if loading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
            if visible.isEmpty, !loading {
                ContentUnavailableView(search.isEmpty && !filtering ? "No prints yet" : "No matches", systemImage: "clock.arrow.circlepath")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .farmBackground()
        .navigationTitle(title)
        .searchable(text: $search, prompt: "Search prints")
        .onSubmit(of: .search) { Task { await reload() } }
        .onChange(of: search) { _, q in if q.isEmpty { Task { await reload() } } }
        .onChange(of: printerFilter) { _, _ in Task { await reload() } }
        .toolbar {
            if selecting {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selecting = false; picked = [] } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Compare") { comparing = ComparePick(ids: picked) }.disabled(picked.count < 2)
                }
            } else if canRead {
                ToolbarItem(placement: .topBarTrailing) { toolsMenu }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $favoritesOnly) { Label("Favorites only", systemImage: "star") }
                    Picker("Status", selection: $statusFilter) {
                        Text("All statuses").tag(String?.none)
                        Text("Completed").tag(String?.some("completed"))
                        Text("Failed").tag(String?.some("failed"))
                        Text("Cancelled").tag(String?.some("cancelled"))
                    }
                    if printerId == nil {
                        Picker("Printer", selection: $printerFilter) {
                            Text("All printers").tag(Int?.none)
                            ForEach(farm.printers) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                    }
                } label: {
                    Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter prints")
            }
        }
        .task {
            if archives.isEmpty { await reload() }
            await refreshMergeCount()
        }
        .refreshable {
            await reload()
            await refreshMergeCount()
        }
        .sheet(isPresented: $showMerge) {
            ArchiveMergeView {
                Task {
                    await reload()
                    await refreshMergeCount()
                }
            }
        }
        .sheet(isPresented: $showCalendar) { ArchiveCalendarView(printerId: printerId) }
        .sheet(item: $comparing, onDismiss: { selecting = false; picked = [] }) { pick in ArchiveCompareView(ids: pick.ids) }
        .sheet(item: $exportFile) { file in AdvShareSheet(items: [file.url]) }
    }

    private func refreshMergeCount() async {
        guard canMerge, printerId == nil else { return }
        mergeCount = (try? await APIClient.shared.archiveMergeCount()) ?? 0
    }

    private var toolsMenu: some View {
        Menu {
            Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
            Button { selecting = true; picked = [] } label: { Label("Compare prints", systemImage: "rectangle.split.2x1") }
            if canMerge, printerId == nil {
                Button { showMerge = true } label: { Label("Merge duplicates", systemImage: "arrow.triangle.merge") }
            }
            Menu {
                Button { export("csv") } label: { Label("CSV", systemImage: "tablecells") }
                Button { export("xlsx") } label: { Label("Excel (XLSX)", systemImage: "tablecells.badge.ellipsis") }
                if farm.can("stats:read") {
                    Button { exportStatistics() } label: { Label("Statistics, 30 days (CSV)", systemImage: "chart.bar") }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: exporting ? "hourglass" : "ellipsis.circle")
        }
        .disabled(exporting)
        .accessibilityLabel("Print tools")
    }

    private func togglePick(_ id: Int) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else if picked.count < 5 {
            picked.append(id)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            error = "You can compare at most 5 prints."
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func export(_ format: String) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let q = search.trimmingCharacters(in: .whitespaces)
                let status = statusFilter == "cancelled" ? nil : statusFilter
                exportFile = ExportFile(url: try await APIClient.shared.exportArchives(
                    format: format, status: status, printerId: effectivePrinter, projectId: nil,
                    search: q.count >= 2 ? q : nil, dateFrom: nil, dateTo: nil))
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func exportStatistics() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportFile = ExportFile(url: try await APIClient.shared.exportStats(format: "csv", days: 30))
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private var visible: [Archive] {
        archives.filter { archive in
            if favoritesOnly, archive.isFavorite != true { return false }
            guard let statusFilter else { return true }
            return statusFilter == "cancelled" ? ["cancelled", "aborted", "stopped"].contains(archive.status) : archive.status == statusFilter
        }
    }

    private func reload() async {
        archives = []
        reachedEnd = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        do {
            let q = search.trimmingCharacters(in: .whitespaces)
            if q.count >= 2 {
                archives = try await APIClient.shared.searchArchives(q, status: nil, printerId: effectivePrinter)
                reachedEnd = true
            } else {
                // The list route has no status or favorite filter, so those apply to what has been fetched;
                // keep pulling pages until a filtered view has something to show.
                var pages = 0
                repeat {
                    let page = try await APIClient.shared.archives(limit: 40, offset: archives.count, printerId: effectivePrinter)
                    archives += page
                    reachedEnd = page.count < 40
                    pages += 1
                } while !reachedEnd && visible.count < 12 && filtering && pages < 6
            }
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

struct ArchiveRow: View {
    let archive: Archive
    var showPrinter = true
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: "archives/\(archive.id)/thumbnail")
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(archive.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    if archive.isFavorite == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                HStack(spacing: 6) {
                    Circle().fill(archive.stateColor).frame(width: 7, height: 7)
                    Text(archive.stateLabel)
                    if showPrinter, let name = farm.printers.first(where: { $0.id == archive.printerId })?.name {
                        Text("· \(name)")
                    }
                    if archive.status == "completed", archive.confirmRequested == true, archive.userVerdict == nil {
                        Pill(text: "Needs review", tint: .statusWarning)
                    } else if archive.userVerdict == "reject" {
                        Pill(text: "Rejected", tint: .statusError, systemImage: "hand.thumbsdown")
                    }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
                if let date = archive.completedAt ?? archive.startedAt {
                    Text(date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let s = archive.actualTimeSeconds ?? archive.printTimeSeconds, s > 0 {
                    Text(formatMinutes(s / 60)).font(.caption.monospacedDigit())
                }
                if let g = archive.filamentUsedGrams, g > 0 {
                    Text(formatGrams(g)).font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ArchiveDetailView: View {
    let archiveId: Int
    @State var initial: Archive?
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var reprinting = false
    @State private var message: String?
    @State private var error: String?
    @State private var userId: Int?
    @State private var plates: [ArchivePlate] = []
    @State private var editing = false
    @State private var choosingProject = false
    @State private var confirmingDelete = false
    @State private var timelapseURL: URL?
    @State private var playing = false
    @State private var loadingTimelapse = false
    @State private var busy = false

    private var archive: Archive? { initial }
    private var access: ArchiveAccess { ArchiveAccess(farm: farm, userId: userId) }
    private var canEdit: Bool { access.canUpdate(archive) }
    private var hasTimelapse: Bool { (archive?.timelapseCount ?? 0) > 0 || archive?.timelapsePath != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(path: "archives/\(archiveId)/thumbnail", contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let archive {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(archive.name).font(.title3.weight(.semibold))
                        HStack(spacing: 8) {
                            Pill(text: archive.stateLabel, tint: archive.stateColor)
                            if let p = farm.printers.first(where: { $0.id == archive.printerId }) {
                                Pill(text: p.name, tint: .textSecondary, systemImage: "printer")
                            }
                            if let verdict = archive.userVerdict {
                                Pill(text: verdict == "good" ? "Good" : "Rejected", tint: verdict == "good" ? .accentTeal : .statusError,
                                     systemImage: verdict == "good" ? "hand.thumbsup" : "hand.thumbsdown")
                            }
                        }
                        if !archive.tagList.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) { ForEach(archive.tagList, id: \.self) { Pill(text: $0, tint: .accentTeal, systemImage: "tag") } }
                            }
                        }
                        if let reason = archive.failureReason, !reason.isEmpty {
                            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.statusError)
                        }
                    }
                    if archive.status == "completed", archive.confirmRequested == true, archive.userVerdict == nil, canEdit {
                        verdictPrompt
                    }
                    Card {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            fact("Print time", (archive.actualTimeSeconds ?? archive.printTimeSeconds).map { formatMinutes($0 / 60) })
                            fact("Filament", archive.filamentUsedGrams.map(formatGrams))
                            fact("Material", archive.filamentType)
                            fact("Layer height", archive.layerHeight.map { String(format: "%.2f mm", $0) })
                            fact("Nozzle", archive.nozzleDiameter.map { String(format: "%.1f mm", $0) })
                            fact("Finished", archive.completedAt?.formatted(date: .abbreviated, time: .shortened))
                            if let cost = archive.cost, cost > 0 { fact("Cost", cost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))) }
                            fact("Bed", archive.bedType)
                            if let runs = archive.runCount, runs > 1 { fact("Printed", "\(runs) times") }
                            fact("Added by", archive.createdByUsername)
                            fact("Designer", archive.designer)
                        }
                    }
                    if farm.can("projects:read") || archive.projectName != nil { projectRow(archive) }
                    if plates.count > 1 { platesSection }
                    ArchiveFoldersSection(archiveId: archiveId)
                    if hasTimelapse { timelapseSection }
                    if let photos = archive.photos, !photos.isEmpty {
                        SectionHeader(title: "Photos", trailing: "\(photos.count)")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(photos, id: \.self) { photo in
                                    RemoteImage(path: "archives/\(archiveId)/photos/\(photo)")
                                        .frame(width: 140, height: 105)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                    }
                    if let notes = archive.notes, !notes.isEmpty {
                        SectionHeader(title: "Notes")
                        Card { Text(notes).font(.callout) }
                    }
                    VStack(spacing: 10) {
                        if farm.canQueue {
                            Button { reprinting = true } label: {
                                Label("Print again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
                        }
                        if let link = archive.makerworldUrl.flatMap(URL.init(string:)) {
                            Link(destination: link) {
                                Label("Open on MakerWorld", systemImage: "globe").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                    if let message { Text(message).font(.footnote).foregroundStyle(Color.textMuted) }
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            do { initial = try await APIClient.shared.toggleFavorite(archiveId) } catch { self.error = FriendlyError.message(error) }
                        }
                    } label: {
                        Image(systemName: archive?.isFavorite == true ? "star.fill" : "star")
                    }
                    .accessibilityLabel(archive?.isFavorite == true ? "Remove favorite" : "Favorite")
                }
            }
            if canEdit || access.canDelete(archive) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canEdit { Button { editing = true } label: { Label("Edit notes and tags", systemImage: "square.and.pencil") } }
                        if canEdit, archive?.status == "completed" { verdictMenu }
                        if access.canDelete(archive) {
                            Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete print", systemImage: "trash") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More actions")
                }
            }
        }
        .task {
            userId = await IdentityCache.shared.userId()
            if let fresh = try? await APIClient.shared.archive(archiveId) { initial = fresh }
            plates = (try? await APIClient.shared.archivePlates(archiveId)) ?? []
        }
        .sheet(isPresented: $reprinting) {
            TargetPicker(title: archive?.name ?? "Print", slicedFor: archive?.slicedForModel, archiveId: archiveId,
                         initialPlateId: archive?.plateId) { request in
                try await APIClient.shared.addToQueue(QueueCreateBody(archiveId: archiveId, libraryFileId: nil, request: request))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                message = "Added to the queue."
            }
        }
        .sheet(isPresented: $editing) {
            if let archive { ArchiveEditSheet(archive: archive) { initial = $0 } }
        }
        .sheet(isPresented: $choosingProject) {
            ProjectPickerSheet(currentId: archive?.projectId) { projectId in
                var patch = SparsePatch()
                patch["project_id"] = .optionalInt(projectId)
                initial = try await APIClient.shared.updateArchive(archiveId, patch)
            }
        }
        .fullScreenCover(isPresented: $playing) { if let timelapseURL { TimelapsePlayerView(url: timelapseURL) } }
        .confirmationDialog("Delete this print?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete print", role: .destructive) { deleteArchive() }
        } message: {
            Text("The print's files are removed from the server. Its filament and time still count in your statistics.")
        }
    }

    // MARK: Sections

    private var verdictPrompt: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("How did it turn out?", systemImage: "questionmark.circle").font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    Button { setVerdict("good") } label: { Label("Good", systemImage: "hand.thumbsup").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.accentTeal)
                    Button { setVerdict("reject") } label: { Label("Reject", systemImage: "hand.thumbsdown").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.statusError)
                }
                .disabled(busy)
            }
        }
    }

    @ViewBuilder private var verdictMenu: some View {
        Menu {
            Button { setVerdict("good") } label: { Label("Good", systemImage: "hand.thumbsup") }
            Button { setVerdict("reject") } label: { Label("Reject", systemImage: "hand.thumbsdown") }
            if archive?.userVerdict != nil { Button { setVerdict(nil) } label: { Label("Clear verdict", systemImage: "xmark") } }
        } label: { Label("Outcome verdict", systemImage: "checkmark.seal") }
    }

    private func projectRow(_ archive: Archive) -> some View {
        Card(padding: 0) {
            Button { choosingProject = true } label: {
                HStack {
                    Label("Project", systemImage: "folder")
                    Spacer()
                    Text(archive.projectName ?? "None").foregroundStyle(Color.textMuted)
                    if canEdit && farm.can("projects:read") { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted) }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(canEdit && farm.can("projects:read")))
        }
    }

    private var platesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Plates", trailing: "\(plates.count)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(plates) { plate in
                        VStack(alignment: .leading, spacing: 4) {
                            RemoteImage(path: plate.thumbnailPath, contentMode: .fit)
                                .frame(width: 110, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(plate.title).font(.caption.weight(.medium)).lineLimit(1)
                            if let s = plate.printTimeSeconds, s > 0 { Text(formatMinutes(s / 60)).font(.caption2).foregroundStyle(Color.textMuted) }
                        }
                        .frame(width: 110)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var timelapseSection: some View {
        Button { Task { await playTimelapse() } } label: {
            HStack {
                if loadingTimelapse { ProgressView() } else { Image(systemName: "play.rectangle.fill") }
                Text(loadingTimelapse ? "Loading timelapse" : "Play timelapse")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .disabled(loadingTimelapse)
    }

    @ViewBuilder private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(Color.textMuted).textCase(.uppercase)
                Text(value).font(.subheadline.weight(.medium))
            }
        }
    }

    // MARK: Actions

    private func setVerdict(_ verdict: String?) {
        Task {
            busy = true
            defer { busy = false }
            var patch = SparsePatch()
            patch["user_verdict"] = verdict.map(JSONScalar.string) ?? .null
            do {
                initial = try await APIClient.shared.updateArchive(archiveId, patch)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func deleteArchive() {
        Task {
            do {
                try await APIClient.shared.deleteArchive(archiveId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func playTimelapse() async {
        loadingTimelapse = true
        defer { loadingTimelapse = false }
        do {
            let url = try await APIClient.shared.downloadTimelapse(archiveId)
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension) else {
                try? FileManager.default.removeItem(at: url)
                error = "This timelapse is a .\(url.pathExtension) file, which iOS can't play. Bambuddy converts it to MP4 in the background; try again later."
                return
            }
            timelapseURL = url
            playing = true
            error = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }
}

/// Plays a downloaded timelapse with AVKit.
struct TimelapsePlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(.white)
            .padding()
            .accessibilityLabel("Close timelapse")
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Edit an archive's notes and tags (PATCH /archives/{id}).
struct ArchiveEditSheet: View {
    let archive: Archive
    let onSaved: (Archive) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes: String
    @State private var tags: String
    @State private var error: String?
    @State private var saving = false

    init(archive: Archive, onSaved: @escaping (Archive) -> Void) {
        self.archive = archive
        self.onSaved = onSaved
        _notes = State(initialValue: archive.notes ?? "")
        _tags = State(initialValue: archive.tagList.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(4 ... 12)
                }
                Section {
                    TextField("Tags, separated by commas", text: $tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("Tags") }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Edit print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        let cleanTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        var patch = SparsePatch()
        if notes != (archive.notes ?? "") { patch["notes"] = .string(notes) }
        if cleanTags != archive.tagList.joined(separator: ",") { patch["tags"] = .string(cleanTags) }
        guard !patch.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            onSaved(try await APIClient.shared.updateArchive(archive.id, patch))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }
}
