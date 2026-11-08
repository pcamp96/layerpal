import SwiftUI

// MARK: File detail section

/// Variant group of one library file: the job sliced for several printer models. View needs
/// library:read_*; group, ungroup and reorder need library:update_*; queueing needs queue:create.
struct VariantSection: View {
    let file: LibFileItem
    let canEdit: Bool
    var onChange: () -> Void = {}
    @EnvironmentObject private var farm: FarmStore
    @State private var group: VariantGroup?
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false
    @State private var managing = false
    @State private var queuing = false

    var body: some View {
        Group {
            if let group {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Printer variants", trailing: "\(group.members.count) files")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.name).font(.subheadline.weight(.semibold))
                            ForEach(group.members) { member in
                                HStack(spacing: 8) {
                                    Text("\(member.position + 1)").font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(member.modelName).font(.subheadline)
                                        Text(member.filename).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if member.libraryFileId == file.id { Pill(text: "This file", tint: .accentTeal) }
                                }
                                .accessibilityElement(children: .combine)
                            }
                            Text("When several printers are free, the higher one in the list gets the job.")
                                .font(.caption).foregroundStyle(Color.textMuted)
                            HStack(spacing: 10) {
                                if farm.canQueue {
                                    Button { queuing = true } label: { Label("Queue any variant", systemImage: "plus.circle") }
                                        .buttonStyle(.borderedProminent).tint(.accentTeal)
                                }
                                if canEdit {
                                    Button { managing = true } label: { Label("Manage", systemImage: "slider.horizontal.3") }.buttonStyle(.bordered)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else if canEdit, file.isSliced, loaded {
                Button { creating = true } label: { Label("Group with other slices of this job", systemImage: "square.on.square") }
                    .buttonStyle(.bordered).controlSize(.regular)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
        }
        .task { await load() }
        .sheet(isPresented: $creating) {
            VariantCreateSheet(file: file) { created in
                group = created
                onChange()
            }
        }
        .sheet(isPresented: $managing) {
            if let group {
                VariantManageSheet(group: group, currentFileId: file.id) { updated in
                    self.group = updated
                    onChange()
                    if updated == nil { Task { await load() } }
                }
            }
        }
        .sheet(isPresented: $queuing) {
            if let group { VariantQueueSheet(group: group) }
        }
    }

    private func load() async {
        guard farm.can("library:read_all") || farm.can("library:read_own") else { loaded = true; return }
        if file.variantGroupId != nil || group != nil {
            do {
                group = try await APIClient.shared.variantGroup(forFile: file.id)
                error = nil
            } catch {
                self.error = FriendlyError.message(error)
            }
        }
        loaded = true
    }
}

// MARK: Queue

/// Queue one job that any variant can fill: whichever printer frees up first runs the file sliced for it.
struct VariantQueueSheet: View {
    let group: VariantGroup
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var quantity = 1
    @State private var saving = false
    @State private var error: String?
    @State private var done = false

    init(group: VariantGroup) {
        self.group = group
        _selected = State(initialValue: Set(group.members.map(\.libraryFileId)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(group.members) { member in
                        Button {
                            if selected.contains(member.id) { selected.remove(member.id) } else { selected.insert(member.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(member.id) ? Color.accentTeal : Color.textMuted)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.modelName).foregroundStyle(.primary)
                                    Text(member.filename).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                                }
                            }
                        }
                        .accessibilityAddTraits(selected.contains(member.id) ? .isSelected : [])
                    }
                } header: { Text("Which variants may print it") } footer: {
                    Text("The job goes to the first printer that is free and matches one of the chosen files.")
                }
                Section { Stepper("Copies: \(quantity)", value: $quantity, in: 1 ... 50) }
                if done { Label("Added to the queue.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Queue any variant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue") { queue() }.disabled(saving || done || selected.count < 1)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func queue() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let ids = group.members.map(\.libraryFileId).filter(selected.contains)
                try await APIClient.shared.queueVariants(fileIds: ids, quantity: quantity)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                done = true
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: Create

/// Pick the other slices of the same job, one per printer model (two files minimum).
struct VariantCreateSheet: View {
    let file: LibFileItem
    let onCreated: (VariantGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LibFileItem] = []
    @State private var picked: [Int] = []
    @State private var models: [Int: String] = [:]
    @State private var name = ""
    @State private var search = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    private var shown: [LibFileItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.filename.localizedCaseInsensitiveContains(q) }
    }

    private var needsModel: [LibFileItem] {
        ([file] + candidates.filter { picked.contains($0.id) }).filter { ($0.slicedForModel ?? "").isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name (optional)", text: $name)
                    Label(file.filename, systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal).font(.subheadline)
                } header: { Text("This file") } footer: {
                    Text("Each file must be sliced for a different printer model. Pick the other slices of this job.")
                }
                Section("Other slices") {
                    if !loaded { ProgressView() }
                    ForEach(shown) { candidate in
                        Button {
                            if let i = picked.firstIndex(of: candidate.id) { picked.remove(at: i) } else { picked.append(candidate.id) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(candidate.id) ? Color.accentTeal : Color.textMuted)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.filename).foregroundStyle(.primary).lineLimit(2)
                                    if let model = candidate.slicedForModel, !model.isEmpty {
                                        Text(Printer.modelNames[model] ?? model).font(.caption).foregroundStyle(Color.textMuted)
                                    }
                                }
                            }
                        }
                        .accessibilityAddTraits(picked.contains(candidate.id) ? .isSelected : [])
                    }
                    if loaded, shown.isEmpty { Text("No other sliced files that aren't already in a group.").font(.footnote).foregroundStyle(Color.textMuted) }
                }
                if !needsModel.isEmpty, !picked.isEmpty {
                    Section {
                        ForEach(needsModel) { f in
                            TextField("Model for \(f.filename)", text: Binding(get: { models[f.id] ?? "" }, set: { models[f.id] = $0 }))
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        }
                    } header: { Text("Printer model") } footer: {
                        Text("These files don't say which printer they were sliced for. Enter the model, such as H2S or X1C.")
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .searchable(text: $search, prompt: "Search files")
            .navigationTitle("Group variants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Group") { create() }.disabled(saving || picked.isEmpty) }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    private func load() async {
        do {
            let all = try await APIClient.shared.libFiles(folderId: nil, includeRoot: false)
            candidates = all.filter { $0.id != file.id && $0.isSliced && $0.variantGroupId == nil }
                .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func create() {
        for f in needsModel where (models[f.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            error = "Enter the printer model for \(f.filename)."
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let explicit = models.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
                let group = try await APIClient.shared.createVariantGroup(fileIds: [file.id] + picked, targetModels: explicit,
                                                                          name: name.trimmingCharacters(in: .whitespaces))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCreated(group)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: Manage

/// Rename, reorder, add, remove or ungroup. `onChange(nil)` means the group no longer exists.
struct VariantManageSheet: View {
    @State var group: VariantGroup
    let currentFileId: Int
    let onChange: (VariantGroup?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmUngroup = false
    @State private var removing: VariantMember?
    @State private var adding = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.members) { member in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.modelName).font(.subheadline)
                            Text(member.filename).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                        }
                        .swipeActions {
                            Button(role: .destructive) { removing = member } label: { Label("Remove", systemImage: "minus.circle") }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onMove(perform: move)
                } header: { Text("Priority order") } footer: {
                    Text("Drag to reorder. Swipe a file to take it out of the group; the file itself stays in the library.")
                }
                Section {
                    Button { newName = group.name; renaming = true } label: { Label("Rename group", systemImage: "pencil") }
                    Button { adding = true } label: { Label("Add another slice", systemImage: "plus.circle") }
                    Button(role: .destructive) { confirmUngroup = true } label: { Label("Ungroup", systemImage: "square.on.square.dashed") }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .environment(\.editMode, .constant(.active))
            .farmBackground()
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(busy)
            .alert("Rename group", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Ungroup these files?", isPresented: $confirmUngroup, titleVisibility: .visible) {
                Button("Ungroup", role: .destructive) { ungroup() }
            } message: { Text("Every file stays in the library and can still be printed on its own.") }
            .confirmationDialog("Remove from group?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { member in
                Button("Remove \(member.filename)", role: .destructive) { remove(member) }
            } message: { _ in Text("A group left with one file is dissolved.") }
            .sheet(isPresented: $adding) {
                VariantAddSheet(group: group) { updated in
                    group = updated
                    onChange(updated)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func move(from: IndexSet, to: Int) {
        var order = group.members.map(\.libraryFileId)
        order.move(fromOffsets: from, toOffset: to)
        run {
            group = try await APIClient.shared.updateVariantGroup(group.id, name: nil, memberFileIds: order)
            onChange(group)
        }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != group.name else { return }
        run {
            group = try await APIClient.shared.updateVariantGroup(group.id, name: name, memberFileIds: nil)
            onChange(group)
        }
    }

    private func remove(_ member: VariantMember) {
        run {
            try await APIClient.shared.removeVariantMember(group.id, fileId: member.libraryFileId)
            if group.members.count <= 2 {
                onChange(nil)
                dismiss()
            } else if let refreshed = try await APIClient.shared.variantGroup(forFile: group.members.first { $0.libraryFileId != member.libraryFileId }?.libraryFileId ?? 0) {
                group = refreshed
                onChange(refreshed)
            }
        }
    }

    private func ungroup() {
        run {
            try await APIClient.shared.deleteVariantGroup(group.id)
            onChange(nil)
            dismiss()
        }
    }
}

/// Add one more sliced file to an existing group.
struct VariantAddSheet: View {
    let group: VariantGroup
    let onAdded: (VariantGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LibFileItem] = []
    @State private var search = ""
    @State private var model = ""
    @State private var chosen: LibFileItem?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    private var shown: [LibFileItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.filename.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !loaded { ProgressView() }
                ForEach(shown) { file in
                    Button { chosen = file } label: {
                        HStack {
                            Image(systemName: chosen?.id == file.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen?.id == file.id ? Color.accentTeal : Color.textMuted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.filename).foregroundStyle(.primary).lineLimit(2)
                                if let m = file.slicedForModel, !m.isEmpty { Text(Printer.modelNames[m] ?? m).font(.caption).foregroundStyle(Color.textMuted) }
                            }
                        }
                    }
                }
                if let chosen, (chosen.slicedForModel ?? "").isEmpty {
                    Section {
                        TextField("Printer model, such as H2S", text: $model).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    } footer: { Text("This file doesn't say which printer it was sliced for.") }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .searchable(text: $search, prompt: "Search files")
            .farmBackground()
            .navigationTitle("Add a slice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(chosen == nil || saving) }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    private func load() async {
        do {
            let all = try await APIClient.shared.libFiles(folderId: nil, includeRoot: false)
            candidates = all.filter { $0.isSliced && $0.variantGroupId == nil }
                .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func add() {
        guard let chosen else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let explicit = model.trimmingCharacters(in: .whitespaces)
                let updated = try await APIClient.shared.addVariantMember(group.id, fileId: chosen.id, targetModel: explicit.isEmpty ? nil : explicit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onAdded(updated)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
