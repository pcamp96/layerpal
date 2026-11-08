import SwiftUI
import UniformTypeIdentifiers

// Library tools that need more than a menu item: the tag catalog, ZIP extraction, STL combining and linking an
// external server folder. Routes and permissions are documented on the API+GapsB.swift calls they use.

// MARK: - Tag catalog (library:update_all)

/// Create, rename and delete tags in the global catalog. Deleting a tag only removes the label; files stay.
struct LibraryTagsSheet: View {
    var onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [LibTag] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: LibTag?
    @State private var renameText = ""
    @State private var deleting: LibTag?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                ForEach(tags) { tag in
                    HStack {
                        Label(tag.name, systemImage: "tag").foregroundStyle(.primary)
                        Spacer()
                        Text("\(tag.fileCount ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted)
                            .accessibilityLabel("\(tag.fileCount ?? 0) files")
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = tag } label: { Label("Delete", systemImage: "trash") }
                        Button { renaming = tag; renameText = tag.name } label: { Label("Rename", systemImage: "pencil") }.tint(.accentTeal)
                    }
                    .contextMenu {
                        Button { renaming = tag; renameText = tag.name } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = tag } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .farmBackground()
            .overlay {
                if loaded, tags.isEmpty, error == nil {
                    ContentUnavailableView("No tags yet", systemImage: "tag", description: Text("Tap + to create one, then add it to files."))
                } else if !loaded, error == nil { ProgressView() }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New tag")
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("New tag", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Up to 64 characters. Names aren't case-sensitive.") }
            .alert("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this tag?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { tag in
                Button("Delete \(tag.name)", role: .destructive) { delete(tag) }
            } message: { tag in
                Text("It is removed from \(tag.fileCount ?? 0) file\(tag.fileCount == 1 ? "" : "s"). The files themselves are untouched.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            tags = try await APIClient.shared.libTags()
            error = nil
        } catch { self.error = FriendlyError.message(error) }
        loaded = true
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run { _ = try await APIClient.shared.libCreateTag(name: name) }
    }

    private func rename() {
        guard let tag = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != tag.name else { return }
        run { _ = try await APIClient.shared.libRenameTag(tag.id, name: name) }
    }

    private func delete(_ tag: LibTag) {
        run { try await APIClient.shared.libDeleteTag(tag.id) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
                onChanged()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: - ZIP extraction (library:upload)

/// Options for POST /library/files/extract-zip, then the upload. Not available inside external folders.
struct ZipExtractSheet: View {
    let zipURL: URL
    let folderId: Int?
    let folderName: String
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preserve = true
    @State private var wrap = false
    @State private var thumbnails = true
    @State private var progress: Double?
    @State private var result: LibZipResult?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Archive", value: zipURL.lastPathComponent)
                    LabeledContent("Into", value: folderName)
                }
                Section {
                    Toggle("Keep the ZIP's folder structure", isOn: $preserve)
                    Toggle("Put everything in a new folder named after the ZIP", isOn: $wrap)
                    Toggle("Make thumbnails for STL files", isOn: $thumbnails)
                } footer: { Text("Off keeps the structure flat: every file lands directly in the destination.") }
                if let progress {
                    Section {
                        FarmProgressBar(value: progress * 100)
                        Text(progress >= 1 ? "Extracting on the server" : "Uploading").font(.footnote).foregroundStyle(Color.textMuted)
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
                if let result {
                    Section("Result") {
                        Label("Extracted \(result.extracted) file\(result.extracted == 1 ? "" : "s"), \(result.foldersCreated) new folder\(result.foldersCreated == 1 ? "" : "s").",
                              systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal).font(.subheadline)
                        ForEach(result.errors) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.filename).font(.footnote.weight(.medium)).lineLimit(2)
                                Text(failure.error).font(.caption).foregroundStyle(Color.statusError)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .farmBackground()
            .disabled(progress != nil)
            .navigationTitle("Extract ZIP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() }.disabled(progress != nil) }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Extract") { extract() }.disabled(progress != nil) }
                }
            }
        }
        .interactiveDismissDisabled(progress != nil)
        .presentationDetents([.medium, .large])
    }

    private func extract() {
        error = nil
        progress = 0
        Task {
            let scoped = zipURL.startAccessingSecurityScopedResource()
            defer { if scoped { zipURL.stopAccessingSecurityScopedResource() }; progress = nil }
            do {
                result = try await APIClient.shared.libExtractZip(
                    fileURL: zipURL, folderId: folderId, preserveStructure: preserve, createFolderFromZip: wrap, generateThumbnails: thumbnails
                ) { value in Task { @MainActor in progress = value } }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onDone()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: - Combine STL files (library:upload)

/// Pick STL files and copy counts, name the result, and POST /library/files/combine. The new 3MF holds every
/// object on one plate and can then be sliced like any other 3MF; the STLs are left alone.
struct CombineSTLSheet: View {
    let tree: [LibFolderNode]
    let folderId: Int?
    var onDone: (LibUploadResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stls: [LibFileItem] = []
    @State private var copies: [Int: Int] = [:]
    @State private var name = "Combined.3mf"
    @State private var destination: Int?
    @State private var pickingFolder = false
    @State private var search = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    private var chosen: [(fileId: Int, copies: Int)] { copies.filter { $0.value > 0 }.map { (fileId: $0.key, copies: $0.value) }.sorted { $0.fileId < $1.fileId } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var visible: [LibFileItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? stls : stls.filter { $0.filename.localizedCaseInsensitiveContains(q) }
    }
    private var destinationName: String { destination.flatMap { tree.find($0)?.name } ?? "Library root" }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                Section {
                    TextField("New file name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { pickingFolder = true } label: { LabeledContent("Save in", value: destinationName) }.foregroundStyle(.primary)
                } footer: { Text("The result is a 3MF with every chosen object on one plate. Slice it afterward so the slicer can arrange them.") }
                Section {
                    ForEach(visible) { file in
                        let count = copies[file.id] ?? 0
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.filename).font(.subheadline).lineLimit(2)
                                if let size = libFormatBytes(file.fileSize) { Text(size).font(.caption).foregroundStyle(Color.textMuted) }
                            }
                            Spacer()
                            if count > 0 {
                                Stepper("Copies of \(file.filename)", value: Binding(get: { copies[file.id] ?? 0 }, set: { copies[file.id] = max(0, min(100, $0)) }), in: 0 ... 100)
                                    .labelsHidden()
                                Text("\(count)").font(.subheadline.monospacedDigit()).frame(minWidth: 26)
                            } else {
                                Button { copies[file.id] = 1 } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("Add \(file.filename)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                } header: { Text("STL files") } footer: {
                    if !chosen.isEmpty { Text("\(chosen.count) file\(chosen.count == 1 ? "" : "s"), \(chosen.reduce(0) { $0 + $1.copies }) object\(chosen.reduce(0) { $0 + $1.copies } == 1 ? "" : "s") in total.") }
                }
            }
            .farmBackground()
            .searchable(text: $search, prompt: "Search STL files")
            .overlay {
                if loaded, stls.isEmpty, error == nil {
                    ContentUnavailableView("No STL files", systemImage: "cube", description: Text("Upload some STL files to the library first."))
                } else if !loaded, error == nil { ProgressView() }
            }
            .disabled(busy)
            .navigationTitle("Combine STL files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Combine") { combine() }.disabled(chosen.isEmpty || trimmedName.isEmpty) }
                }
            }
            .sheet(isPresented: $pickingFolder) {
                LibraryFolderPicker(tree: tree, title: "Save combined file in", allowRoot: true) { destination = $0 }
            }
            .task {
                destination = folderId
                await load()
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func load() async {
        do {
            let all = try await APIClient.shared.libFiles(folderId: nil, includeRoot: false)
            stls = all.filter { $0.filename.lowercased().hasSuffix(".stl") }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            error = nil
        } catch { self.error = FriendlyError.message(error) }
        loaded = true
    }

    private func combine() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await APIClient.shared.libCombine(items: chosen, filename: trimmedName, folderId: destination)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onDone(result)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: - Link an external folder (admin: settings:update)

/// Links a directory on the Bambuddy host as a library folder. The path must sit under the operator's
/// BAMBUDDY_EXTERNAL_ROOTS allowlist (the server explains when it doesn't), and linking is admin-only because every
/// user can then see the folder. After linking, LayerPal scans it so its files show up.
struct LinkExternalFolderSheet: View {
    let parentId: Int?
    let parentName: String
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionGate(title: "Link server folder", permission: "settings:update") {
                LinkExternalForm(parentId: parentId, parentName: parentName, onDone: onDone)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct LinkExternalForm: View {
    let parentId: Int?
    let parentName: String
    let onDone: () -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var name = ""
    @State private var path = ""
    @State private var readonly = true
    @State private var showHidden = false
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && path.trimmingCharacters(in: .whitespaces).hasPrefix("/") }

    var body: some View {
        Form {
            Section {
                TextField("Name in the library", text: $name)
                TextField("Folder path on the server", text: $path, prompt: Text("/mnt/models"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                if !path.isEmpty, !path.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                    Text("The path must be absolute, starting with /.").font(.footnote).foregroundStyle(Color.statusError)
                }
                LabeledContent("Inside", value: parentName)
            } footer: {
                Text("This is a folder on the machine running Bambuddy (a Docker mount, not a folder on this iPhone). The server operator allows specific roots with BAMBUDDY_EXTERNAL_ROOTS; anything else is refused.")
            }
            Section {
                Toggle("Read-only", isOn: $readonly)
                Toggle("Show hidden files", isOn: $showHidden)
            } footer: { Text("Read-only keeps LayerPal and Bambuddy from adding, changing or deleting files in that folder.") }
            if let message {
                Section {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(isError ? Color.statusError : Color.accentTeal)
                }
            }
            Section {
                Button { Task { await link() } } label: { HStack { Text("Link folder"); if busy { Spacer(); ProgressView() } } }
                    .disabled(!valid || busy)
            }
        }
        .farmBackground()
    }

    private func link() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            let id = try await session.perform {
                try await APIClient.shared.libLinkExternalFolder(name: name.trimmingCharacters(in: .whitespaces), path: path.trimmingCharacters(in: .whitespaces),
                                                                 readonly: readonly, showHidden: showHidden, parentId: parentId, bearer: $0)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            do {
                let scan = try await APIClient.shared.libScanFolder(id)
                show("Linked. Found \(scan.added) file\(scan.added == 1 ? "" : "s").", error: false)
            } catch {
                show("Linked, but the first scan failed: \(FriendlyError.message(error)) Use Rescan folder to try again.", error: true)
            }
            onDone()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            show(AdminError.friendly(error), error: true)
        }
    }

    private func show(_ text: String, error: Bool) { message = text; isError = error }
}
