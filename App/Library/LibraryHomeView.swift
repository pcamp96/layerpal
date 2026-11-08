import SwiftUI
import UniformTypeIdentifiers

/// Who may do what in the library, from the user's permission strings
/// (library:upload, library:update_own|all, library:delete_own|all).
@MainActor
struct LibAccess {
    let farm: FarmStore
    let userId: Int?

    private func owns(_ createdById: Int?) -> Bool { createdById != nil && createdById == userId }

    var canUpload: Bool { farm.can("library:upload") }
    var canMakerWorld: Bool { farm.can("makerworld:view") }
    var canImport: Bool { farm.can("makerworld:import") }
    var canTrash: Bool { farm.can("library:delete_all") || farm.can("library:delete_own") }
    var canUpdateAny: Bool { farm.can("library:update_all") || farm.can("library:update_own") }

    func canUpdate(createdBy: Int?) -> Bool {
        farm.can("library:update_all") || (farm.can("library:update_own") && (userId == nil || owns(createdBy)))
    }

    func canDelete(createdBy: Int?) -> Bool {
        farm.can("library:delete_all") || (farm.can("library:delete_own") && (userId == nil || owns(createdBy)))
    }
}

enum LibSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case name = "Name"
    case size = "Size"
    case printTime = "Print time"
    case mostPrinted = "Most printed"

    var id: String { rawValue }

    func sorted(_ files: [LibFileItem]) -> [LibFileItem] {
        switch self {
        case .newest: files.sorted { $0.date > $1.date }
        case .name: files.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .size: files.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .printTime: files.sorted { ($0.printTimeSeconds ?? 0) > ($1.printTimeSeconds ?? 0) }
        case .mostPrinted: files.sorted { ($0.printCount ?? 0) > ($1.printCount ?? 0) }
        }
    }
}

func libFormatBytes(_ bytes: Int?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// The Library page: root of the file manager. Pushed from More (no NavigationStack of its own).
struct LibraryHomeView: View {
    init() {}

    var body: some View {
        LibraryFolderView(folderId: nil)
    }
}

/// One folder level (or the root when `folderId` is nil): subfolders, files, search, sort, tags, upload.
struct LibraryFolderView: View {
    let folderId: Int?
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var tree: [LibFolderNode] = []
    @State private var files: [LibFileItem] = []
    @State private var allFiles: [LibFileItem]?
    @State private var tags: [LibTag] = []
    @State private var selectedTags: Set<Int> = []
    @State private var search = ""
    @State private var sort = LibSort.newest
    @State private var slicedOnly = false
    @State private var userId: Int?
    @State private var loaded = false
    @State private var error: String?

    @State private var importing = false
    @State private var uploadProgress: Double?
    @State private var uploadLabel = ""
    @State private var notice: String?

    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var moving: MoveTarget?
    @State private var queuing: LibFileItem?
    @State private var confirmDeleteFile: LibFileItem?
    @State private var confirmDeleteFolder = false
    @State private var showMakerWorld = false
    @State private var showTrash = false
    @State private var showLinks = false
    @State private var showTags = false
    @State private var zipImporting = false
    @State private var zipPick: ZipPick?
    @State private var showCombine = false
    @State private var showLinkExternal = false

    private struct ZipPick: Identifiable { let url: URL; var id: URL { url } }

    private var access: LibAccess { LibAccess(farm: farm, userId: userId) }
    private var node: LibFolderNode? { folderId.flatMap { tree.find($0) } }
    private var subfolders: [LibFolderNode] { folderId == nil ? tree : (node?.kids ?? []) }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canWriteHere: Bool { access.canUpload && (node?.canWrite ?? true) && node?.isReadonlyExternal != true }

    /// What the list shows: a library-wide search result, or this folder's files, filtered and sorted.
    private var visibleFiles: [LibFileItem] {
        var list = searching ? (allFiles ?? []) : files
        if searching {
            let q = search.trimmingCharacters(in: .whitespaces)
            list = list.filter { $0.filename.localizedCaseInsensitiveContains(q) }
            if !selectedTags.isEmpty { list = list.filter { f in selectedTags.isSubset(of: Set((f.tags ?? []).map(\.id))) } }
        }
        if slicedOnly { list = list.filter(\.isSliced) }
        return sort.sorted(list)
    }

    var body: some View {
        List {
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let progress = uploadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(uploadLabel).font(.footnote).lineLimit(1)
                    FarmProgressBar(value: progress * 100)
                }
                .accessibilityElement(children: .combine)
            }
            if !selectedTags.isEmpty { tagChips }
            if let node, !searching {
                if node.projectName != nil || node.archiveName != nil {
                    Button { showLinks = true } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            if let name = node.projectName { Label("Project: \(name)", systemImage: "square.stack.3d.up") }
                            if let name = node.archiveName { Label("Print: \(name)", systemImage: "clock.arrow.circlepath") }
                        }
                        .font(.footnote).foregroundStyle(Color.accentTeal)
                    }
                }
                if let folderId { FolderReadmeSection(folderId: folderId) }
            }
            if !searching, selectedTags.isEmpty, !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { folder in
                        NavigationLink { LibraryFolderView(folderId: folder.id).navigationTitle(folder.name) } label: { folderRow(folder) }
                    }
                }
            }
            Section(searching ? "Results from the whole library" : "Files") {
                ForEach(visibleFiles) { file in
                    NavigationLink {
                        LibraryFileDetailView(file: file, tree: tree, tags: tags) { Task { await load() } }
                    } label: { fileRow(file) }
                        .swipeActions(edge: .trailing) {
                            if access.canDelete(createdBy: file.createdById) {
                                Button(role: .destructive) { confirmDeleteFile = file } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if farm.canQueue, file.isSliced {
                                Button { queuing = file } label: { Label("Queue", systemImage: "plus.circle") }.tint(.accentTeal)
                            }
                        }
                        .contextMenu {
                            if farm.canQueue, file.isSliced {
                                Button { queuing = file } label: { Label("Add to queue", systemImage: "plus.circle") }
                            }
                            if access.canUpdate(createdBy: file.createdById) {
                                Button { moving = .file(file) } label: { Label("Move to folder", systemImage: "folder") }
                            }
                            if access.canDelete(createdBy: file.createdById) {
                                Button(role: .destructive) { confirmDeleteFile = file } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
            }
        }
        .farmBackground()
        .navigationTitle(node?.name ?? "Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search the whole library")
        .overlay {
            if loaded, error == nil, visibleFiles.isEmpty, subfolders.isEmpty || searching {
                ContentUnavailableView(searching ? "No matches" : "Empty folder", systemImage: searching ? "magnifyingglass" : "folder")
            }
        }
        .toolbar { toolbar }
        .task {
            userId = await IdentityCache.shared.userId()
            await load()
        }
        .refreshable { await load() }
        .onChange(of: selectedTags) { _, _ in Task { await load() } }
        .onChange(of: search) { _, text in
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, allFiles == nil { Task { await loadAll() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.uploadTypes, allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): upload(urls)
            case let .failure(err): error = err.localizedDescription
            }
        }
        .background(Color.clear.fileImporter(isPresented: $zipImporting, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls): if let url = urls.first { zipPick = ZipPick(url: url) }
            case let .failure(err): error = err.localizedDescription
            }
        })
        .sheet(item: $zipPick) { pick in
            ZipExtractSheet(zipURL: pick.url, folderId: folderId, folderName: node?.name ?? "Library root") {
                Task { await load() }
            }
        }
        .sheet(isPresented: $showTags) { LibraryTagsSheet { Task { await load() } } }
        .sheet(isPresented: $showCombine) {
            CombineSTLSheet(tree: tree, folderId: folderId) { result in
                notice = "Created \(result.filename). Open it and tap Slice to arrange and slice it."
                Task { await load() }
            }
        }
        .sheet(isPresented: $showLinkExternal) {
            LinkExternalFolderSheet(parentId: folderId, parentName: node?.name ?? "Library root") { Task { await load() } }
        }
        .sheet(item: $queuing) { file in
            TargetPicker(title: file.filename, slicedFor: file.slicedForModel, archiveId: nil, libraryFileId: file.id) { request in
                try await APIClient.shared.addToQueue(QueueCreateBody(archiveId: nil, libraryFileId: file.id, request: request))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Queued \(file.filename)."
            }
        }
        .sheet(item: $moving) { target in
            LibraryFolderPicker(tree: tree, title: target.title, exclude: target.excluded(in: tree), allowRoot: true) { destination in
                try await performMove(target, to: destination)
            }
        }
        .sheet(isPresented: $showMakerWorld, onDismiss: { Task { await load() } }) {
            NavigationStack { MakerWorldView(tree: tree, canImport: access.canImport).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { showMakerWorld = false } }
            } }
        }
        .sheet(isPresented: $showTrash, onDismiss: { Task { await load() } }) {
            NavigationStack { LibraryTrashView().toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { showTrash = false } }
            } }
        }
        .sheet(isPresented: $showLinks) {
            if let node { FolderLinksSheet(node: node) { Task { await load() } } }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename folder", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { renameFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this file?", isPresented: Binding(get: { confirmDeleteFile != nil }, set: { if !$0 { confirmDeleteFile = nil } }),
                            titleVisibility: .visible, presenting: confirmDeleteFile) { file in
            Button("Move to trash", role: .destructive) { delete(file) }
        } message: { file in
            Text("\(file.filename) goes to the trash and can be restored until it is purged. Files in linked external folders are removed immediately.")
        }
        .confirmationDialog("Delete \(node?.name ?? "folder")?", isPresented: $confirmDeleteFolder, titleVisibility: .visible) {
            Button("Delete folder and its contents", role: .destructive) { deleteFolder() }
        } message: {
            Text("This deletes the folder, every subfolder and every file in them. This cannot be undone.")
        }
    }

    // MARK: Rows

    private func folderRow(_ folder: LibFolderNode) -> some View {
        HStack {
            Label(folder.name, systemImage: folder.isExternal == true ? "externaldrive.fill" : "folder.fill").foregroundStyle(.primary)
            Spacer()
            if let n = folder.fileCount, n > 0 { Text("\(n)").font(.caption).foregroundStyle(Color.textMuted) }
        }
        .accessibilityElement(children: .combine)
    }

    private func fileRow(_ file: LibFileItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(path: file.thumbnailPath == nil ? nil : file.thumbnailAPIPath)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let model = file.slicedForModel, !model.isEmpty { Text(Printer.modelNames[model] ?? model) }
                    if let s = file.printTimeSeconds, s > 0 { Text(formatMinutes(s / 60)) }
                    if let g = file.filamentUsedGrams, g > 0 { Text(formatGrams(g)) }
                    if !file.isSliced, file.fileType != nil { Text((file.fileType ?? "").uppercased()) }
                }
                .font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                if let t = file.tags, !t.isEmpty {
                    Text(t.map(\.name).joined(separator: ", ")).font(.caption2).foregroundStyle(Color.accentTeal).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let v = file.variantCount, v > 1 {
                Pill(text: "\(v) variants", tint: .accentTeal, systemImage: "square.on.square")
            }
            if let n = file.printCount, n > 0 {
                Pill(text: "\(n)x", tint: .statusFinished, systemImage: "printer")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tags.filter { selectedTags.contains($0.id) }) { tag in
                    Button { selectedTags.remove(tag.id) } label: {
                        Pill(text: tag.name, tint: .accentTeal, systemImage: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Remove tag filter \(tag.name)")
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibSort.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Sliced files only", isOn: $slicedOnly)
                if !tags.isEmpty {
                    Menu("Filter by tag") {
                        ForEach(tags) { tag in
                            Button {
                                if selectedTags.contains(tag.id) { selectedTags.remove(tag.id) } else { selectedTags.insert(tag.id) }
                            } label: {
                                Label(tag.name, systemImage: selectedTags.contains(tag.id) ? "checkmark" : "tag")
                            }
                        }
                    }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("Sort and filter")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if canWriteHere {
                    Button { importing = true } label: { Label("Upload file", systemImage: "square.and.arrow.up") }
                    Button { newFolderName = ""; showNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    if node?.isExternal != true {
                        Button { zipImporting = true } label: { Label("Extract ZIP", systemImage: "doc.zipper") }
                    }
                    Button { showCombine = true } label: { Label("Combine STL files", systemImage: "square.stack.3d.down.right") }
                }
                if farm.can("library:update_all") {
                    Button { showTags = true } label: { Label("Manage tags", systemImage: "tag") }
                }
                if farm.can("settings:update") {
                    Button { showLinkExternal = true } label: { Label("Link server folder", systemImage: "externaldrive.badge.plus") }
                }
                if node?.isExternal == true, access.canUpload {
                    Button { rescan() } label: { Label("Rescan folder", systemImage: "arrow.triangle.2.circlepath") }
                }
                if access.canMakerWorld {
                    Button { showMakerWorld = true } label: { Label("Import from MakerWorld", systemImage: "globe") }
                }
                if access.canTrash {
                    Button { showTrash = true } label: { Label("Trash", systemImage: "trash") }
                }
                if let node {
                    Divider()
                    Button { showLinks = true } label: { Label("Linked project and print", systemImage: "link") }
                    if node.canRename != false, access.canUpdateAny, !node.isReadonlyExternal {
                        Button { renameText = node.name; renaming = true } label: { Label("Rename folder", systemImage: "pencil") }
                        Button { moving = .folder(node) } label: { Label("Move folder", systemImage: "folder") }
                    }
                    if node.canDelete != false, access.canTrash {
                        Button(role: .destructive) { confirmDeleteFolder = true } label: { Label("Delete folder", systemImage: "trash") }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Library actions")
        }
    }

    // MARK: Loading

    private func load() async {
        do {
            async let t = APIClient.shared.libFolderTree()
            let tagIds = Array(selectedTags)
            async let f = APIClient.shared.libFiles(folderId: folderId, includeRoot: true, tagIds: tagIds)
            tree = try await t
            files = try await f
            tags = (try? await APIClient.shared.libTags()) ?? tags
            allFiles = nil
            if searching { await loadAll() }
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func loadAll() async {
        do {
            allFiles = try await APIClient.shared.libFiles(folderId: nil, includeRoot: false, tagIds: Array(selectedTags))
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    // MARK: Actions

    /// 3MF (includes .gcode.3mf) and STL. Raw .gcode is refused by the server, so it isn't offered.
    static let uploadTypes: [UTType] = [UTType(filenameExtension: "3mf"), UTType(filenameExtension: "stl")].compactMap { $0 }

    private func upload(_ urls: [URL]) {
        Task {
            var done = 0
            var duplicates = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                if name.lowercased().hasSuffix(".gcode"), !name.lowercased().hasSuffix(".gcode.3mf") {
                    error = "\(name) is raw G-code. Bambu printers need a .gcode.3mf file, so Bambuddy refuses it."
                    continue
                }
                uploadLabel = urls.count > 1 ? "Uploading \(name) (\(done + 1) of \(urls.count))" : "Uploading \(name)"
                uploadProgress = 0
                do {
                    let result = try await APIClient.shared.libUpload(fileURL: url, folderId: folderId) { value in
                        Task { @MainActor in uploadProgress = value }
                    }
                    done += 1
                    if result.duplicateOf != nil { duplicates += 1 }
                    error = nil
                } catch {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.error = "\(name): \(FriendlyError.message(error))"
                    break
                }
            }
            uploadProgress = nil
            if done > 0 {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Uploaded \(done) file\(done == 1 ? "" : "s")." + (duplicates > 0 ? " \(duplicates) already existed in the library." : "")
                await load()
            }
        }
    }

    private func rescan() {
        guard let folderId else { return }
        Task {
            do {
                let scan = try await APIClient.shared.libScanFolder(folderId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Rescanned: \(scan.added) added, \(scan.removed) removed."
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await APIClient.shared.libCreateFolder(name: name, parentId: folderId)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func renameFolder() {
        guard let node else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != node.name else { return }
        Task {
            do {
                try await APIClient.shared.libRenameFolder(node.id, name: name)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func deleteFolder() {
        guard let node else { return }
        Task {
            do {
                try await APIClient.shared.libDeleteFolder(node.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func delete(_ file: LibFileItem) {
        Task {
            do {
                let trashed = try await APIClient.shared.libDeleteFile(file.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = trashed ? "Moved \(file.filename) to the trash." : "Deleted \(file.filename)."
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func performMove(_ target: MoveTarget, to destination: Int?) async throws {
        switch target {
        case let .file(file):
            let moved = try await APIClient.shared.libMoveFiles([file.id], to: destination)
            if moved == 0 { throw APIError.http(403, "{\"detail\":\"The server skipped the file. You may only move your own files.\"}") }
        case let .folder(folder):
            try await APIClient.shared.libMoveFolder(folder.id, to: destination)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await load()
        if case .folder = target { dismiss() }
    }
}

/// Something being moved to another folder.
enum MoveTarget: Identifiable {
    case file(LibFileItem)
    case folder(LibFolderNode)

    var id: String {
        switch self {
        case let .file(f): "file-\(f.id)"
        case let .folder(f): "folder-\(f.id)"
        }
    }

    var title: String {
        switch self {
        case let .file(f): "Move \(f.filename)"
        case let .folder(f): "Move \(f.name)"
        }
    }

    /// A folder can't go into itself or its own subfolders.
    func excluded(in tree: [LibFolderNode]) -> Set<Int> {
        if case let .folder(f) = self { return Set((tree.find(f.id) ?? f).flattened.map(\.id)) }
        return []
    }
}

/// Pick a destination folder (or the library root). Read-only external folders are left out.
struct LibraryFolderPicker: View {
    let tree: [LibFolderNode]
    let title: String
    var exclude: Set<Int> = []
    var allowRoot = true
    var rootLabel = "Library root"
    let onPick: (Int?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var busy = false

    private struct Row: Identifiable {
        let node: LibFolderNode
        let depth: Int
        var id: Int { node.id }
    }

    private var rows: [Row] {
        func walk(_ nodes: [LibFolderNode], _ depth: Int) -> [Row] {
            nodes.filter { !exclude.contains($0.id) }.flatMap { [Row(node: $0, depth: depth)] + walk($0.kids, depth + 1) }
        }
        return walk(tree, 0)
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if allowRoot {
                    Button { pick(nil) } label: { Label(rootLabel, systemImage: "tray.full") }
                }
                ForEach(rows) { row in
                    let writable = (row.node.canWrite ?? true) && !row.node.isReadonlyExternal
                    Button { pick(row.node.id) } label: {
                        Label(row.node.name, systemImage: "folder").padding(.leading, CGFloat(row.depth) * 16)
                    }
                    .disabled(!writable)
                }
            }
            .farmBackground()
            .foregroundStyle(.primary)
            .disabled(busy)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ id: Int?) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await onPick(id)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
