import SwiftUI

/// One library file: thumbnail, plates, print facts, notes, tags, and the actions
/// (add to queue, rename, move, delete). Pushed from the folder list.
struct LibraryFileDetailView: View {
    let file: LibFileItem
    let tree: [LibFolderNode]
    let tags: [LibTag]
    var onChange: () -> Void = {}

    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LibFileDetail?
    @State private var plates: [LibPlate] = []
    @State private var plate: Int?
    @State private var fileTags: [LibTagRef]
    @State private var userId: Int?
    @State private var error: String?
    @State private var notice: String?
    @State private var queuing = false
    @State private var slicing = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var editingNotes = false
    @State private var notesText = ""
    @State private var moving = false
    @State private var confirmDelete = false
    @State private var busy = false

    init(file: LibFileItem, tree: [LibFolderNode], tags: [LibTag], onChange: @escaping () -> Void = {}) {
        self.file = file
        self.tree = tree
        self.tags = tags
        self.onChange = onChange
        _fileTags = State(initialValue: file.tags ?? [])
    }

    private var access: LibAccess { LibAccess(farm: farm, userId: userId) }
    private var name: String { detail?.filename ?? file.filename }
    private var canEdit: Bool { access.canUpdate(createdBy: detail?.createdById ?? file.createdById) }
    private var canDelete: Bool { access.canDelete(createdBy: detail?.createdById ?? file.createdById) }
    /// STL and 3MF can be sliced on the server (STEP can't); the slice route needs library:upload.
    private var canSlice: Bool {
        let lower = name.lowercased()
        return farm.can("library:upload") && (lower.hasSuffix(".stl") || lower.hasSuffix(".3mf"))
    }
    private var meta: [String: LibJSON] { detail?.metadata ?? [:] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(path: file.thumbnailPath == nil ? nil : file.thumbnailAPIPath, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Thumbnail of \(name)")
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        Pill(text: file.isSliced ? "Sliced" : "Not sliced", tint: file.isSliced ? .accentTeal : .statusWarning)
                        if let model = detail?.slicedForModel ?? file.slicedForModel, !model.isEmpty {
                            Pill(text: Printer.modelNames[model] ?? model, tint: .textSecondary, systemImage: "printer")
                        }
                        if let size = libFormatBytes(detail?.fileSize ?? file.fileSize) { Pill(text: size) }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if let notice { Text(notice).font(.footnote).foregroundStyle(Color.accentTeal) }
                if farm.canQueue, file.isSliced {
                    Button { queuing = true } label: { Label("Add to queue", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.accentTeal).controlSize(.large)
                } else if farm.canQueue {
                    Label(canSlice ? "Only sliced files (.gcode.3mf) can be queued. Slice this one below, or in your slicer and upload the result."
                                   : "Only sliced files (.gcode.3mf) can be queued. Slice this one in your slicer and upload the result.",
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Color.textMuted)
                }
                if canSlice {
                    Button { slicing = true } label: {
                        Label(file.isSliced ? "Re-slice on the server" : "Slice on the server", systemImage: "square.3.layers.3d.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                if plates.count > 1 { platesSection }
                VariantSection(file: file, canEdit: canEdit, onChange: onChange)
                SectionHeader(title: "Details")
                Card {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        fact("Print time", (detail?.printTimeSeconds ?? file.printTimeSeconds).flatMap { $0 > 0 ? formatMinutes($0 / 60) : nil })
                        fact("Filament", filamentText)
                        fact("Printed", "\(detail?.printCount ?? file.printCount ?? 0) times")
                        fact("Last printed", detail?.lastPrintedAt?.formatted(date: .abbreviated, time: .shortened))
                        fact("Layer height", meta.num("layerHeight").map { String(format: "%.2f mm", $0) })
                        fact("Nozzle", meta.num("nozzleDiameter").map { String(format: "%.1f mm", $0) })
                        fact("Bed type", meta.str("bedType"))
                        fact("Layers", meta.num("totalLayers").map { String(Int($0)) })
                        fact("Designer", meta.str("designer"))
                        fact("Folder", detail?.folderName ?? (file.folderId == nil ? "Library root" : nil))
                        fact("Project", detail?.projectName)
                        fact("Added by", detail?.createdByUsername ?? file.createdByUsername)
                        fact("Added", (detail?.createdAt ?? file.createdAt)?.formatted(date: .abbreviated, time: .shortened))
                        fact("Duplicates", (detail?.duplicateCount ?? 0) > 0 ? "\(detail?.duplicateCount ?? 0) other copies" : nil)
                    }
                }
                if let source = detail?.sourceUrl, let url = URL(string: source) {
                    Link(destination: url) { Label("Open source page", systemImage: "globe") }.font(.subheadline)
                }
                if let link = detail?.externalUrl, let url = URL(string: link) {
                    Link(destination: url) { Label(link, systemImage: "link") }.font(.subheadline).lineLimit(1)
                }
                tagsSection
                SectionHeader(title: "Notes")
                Card {
                    HStack(alignment: .top) {
                        Text(detail?.notes?.isEmpty == false ? detail!.notes! : "No notes")
                            .font(.subheadline)
                            .foregroundStyle(detail?.notes?.isEmpty == false ? Color.primary : Color.textMuted)
                        Spacer(minLength: 0)
                        if canEdit {
                            Button { notesText = detail?.notes ?? ""; editingNotes = true } label: { Image(systemName: "pencil") }
                                .accessibilityLabel("Edit notes")
                        }
                    }
                }
                if canEdit || canDelete { manageButtons }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("File")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task {
            userId = await IdentityCache.shared.userId()
            await load()
        }
        .sheet(isPresented: $slicing) {
            LibrarySliceSheet(fileId: file.id, filename: name, isThreeMF: name.lowercased().hasSuffix(".3mf"), plates: plates,
                              initialPlate: plate) { onChange() }
        }
        .sheet(isPresented: $queuing) {
            TargetPicker(title: name, slicedFor: detail?.slicedForModel ?? file.slicedForModel, archiveId: nil,
                         libraryFileId: file.id, initialPlateId: plate) { request in
                try await APIClient.shared.addToQueue(QueueCreateBody(archiveId: nil, libraryFileId: file.id, request: request))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Added to the queue."
            }
        }
        .sheet(isPresented: $moving) {
            LibraryFolderPicker(tree: tree, title: "Move \(name)", allowRoot: true) { destination in
                let moved = try await APIClient.shared.libMoveFiles([file.id], to: destination)
                if moved == 0 { throw APIError.http(403, "{\"detail\":\"The server skipped the file. You may only move your own files.\"}") }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onChange()
                await load()
            }
        }
        .sheet(isPresented: $editingNotes) {
            NavigationStack {
                Form { TextEditor(text: $notesText).frame(minHeight: 160) }
                    .navigationTitle("Notes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingNotes = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Save") { saveNotes() } }
                    }
            }
            .presentationDetents([.medium])
        }
        .alert("Rename file", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Keep the extension. Bambu printers store files on FAT32, so avoid characters like / \\ : * ? \" < > |.") }
        .confirmationDialog("Delete this file?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) { delete() }
        } message: {
            Text("\(name) goes to the trash and can be restored until it is purged. Files in linked external folders are removed immediately.")
        }
    }

    // MARK: Sections

    private var platesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Plates", trailing: farm.canQueue && file.isSliced ? "Tap to queue just one" : nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(plates) { p in
                        Button { plate = plate == p.index ? nil : p.index } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RemoteImage(path: p.hasThumbnail == true ? "library/files/\(file.id)/plate-thumbnail/\(p.index)" : nil)
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(plate == p.index ? Color.accentTeal : .clear, lineWidth: 2))
                                Text(p.title).font(.caption).lineLimit(1).frame(width: 96, alignment: .leading)
                                if let s = p.printTimeSeconds, s > 0 {
                                    Text(formatMinutes(Int(s) / 60)).font(.caption2).foregroundStyle(Color.textMuted)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(p.title + (plate == p.index ? ", selected for queue" : ""))
                    }
                }
            }
        }
    }

    @ViewBuilder private var tagsSection: some View {
        if !fileTags.isEmpty || (canEdit && !tags.isEmpty) {
            SectionHeader(title: "Tags")
            HStack {
                ForEach(fileTags) { Pill(text: $0.name, tint: .accentTeal, systemImage: "tag") }
                if canEdit, !tags.isEmpty {
                    Menu {
                        ForEach(tags) { tag in
                            let on = fileTags.contains { $0.id == tag.id }
                            Button { toggleTag(tag, on: !on) } label: { Label(tag.name, systemImage: on ? "checkmark" : "tag") }
                        }
                    } label: { Pill(text: "Edit", tint: .textSecondary, systemImage: "plus") }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var manageButtons: some View {
        VStack(spacing: 10) {
            if canEdit {
                HStack(spacing: 10) {
                    Button { renameText = name; renaming = true } label: { Label("Rename", systemImage: "pencil").frame(maxWidth: .infinity) }
                    Button { moving = true } label: { Label("Move", systemImage: "folder").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            if canDelete {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var filamentText: String? {
        var parts: [String] = []
        if let g = detail?.filamentUsedGrams ?? file.filamentUsedGrams, g > 0 { parts.append(formatGrams(g)) }
        if let type = meta.str("filamentType") { parts.append(type) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder private func fact(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(Color.textMuted)
                Text(value).font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            detail = try await APIClient.shared.libFile(file.id)
            if detail?.filename.lowercased().hasSuffix(".3mf") == true {
                plates = (try? await APIClient.shared.libPlates(file.id)) ?? []
            }
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func rename() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != name else { return }
        run {
            var patch = LibPatch()
            patch["filename"] = .string(text)
            detail = try await APIClient.shared.libUpdateFile(file.id, patch)
            onChange()
        }
    }

    private func saveNotes() {
        editingNotes = false
        run {
            var patch = LibPatch()
            patch["notes"] = .string(notesText)
            detail = try await APIClient.shared.libUpdateFile(file.id, patch)
            onChange()
        }
    }

    private func toggleTag(_ tag: LibTag, on: Bool) {
        run {
            try await APIClient.shared.libAssignTags(fileIds: [file.id], tagIds: [tag.id], action: on ? "add" : "remove")
            if on { fileTags.append(LibTagRef(id: tag.id, name: tag.name)) } else { fileTags.removeAll { $0.id == tag.id } }
            onChange()
        }
    }

    private func delete() {
        run {
            _ = try await APIClient.shared.libDeleteFile(file.id)
            onChange()
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
