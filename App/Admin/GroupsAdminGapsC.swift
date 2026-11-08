import SwiftUI
import UIKit

/// Create, edit, delete and manage the members of a Bambuddy group (Settings > Groups).
/// Routes under /groups. Writes need the matching `groups:*` permission AND an admin account.
struct GroupEditorView: View {
    /// nil = create a new group.
    let group: AdminGroup?
    var onChanged: () async -> Void

    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var details = ""
    @State private var selected: Set<String> = []
    @State private var original: Set<String> = []
    @State private var categories: [APIClient.PermissionCategory] = []
    @State private var detail: APIClient.GroupDetail?
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var pendingRemove: APIClient.GroupMember?
    @State private var addingMember = false
    @State private var populated = false

    private var isSystem: Bool { group?.isSystem == true }
    /// Server rule: group writes need the permission and an admin account.
    private func allowed(_ permission: String) -> Bool {
        session.can(permission) && (session.authEnabled == false || session.me?.isAdmin != false)
    }

    private var canSave: Bool { allowed(group == nil ? "groups:create" : "groups:update") }
    private var canEditPermissions: Bool { canSave && !isSystem }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).disabled(isSystem || !canSave)
                TextField("Description", text: $details, axis: .vertical).lineLimit(1 ... 4).disabled(!canSave)
            } footer: {
                if isSystem { Text("Built-in groups can't be renamed, deleted or have their permissions changed. You can still manage who belongs to them.") }
            }
            if group?.restrictPrinters == true {
                Section { Label("Limited to specific printers or locations", systemImage: "lock.fill").font(.subheadline) } footer: {
                    Text("Printer limits are set in Bambuddy's web settings.")
                }
            }
            if group != nil { membersSection }
            permissionsSections
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if let group, !isSystem, allowed("groups:delete") {
                Section {
                    Button("Delete group", role: .destructive) { confirmDelete = true }.disabled(saving)
                } footer: { Text("Members stay, but lose what \(group.name) gave them.") }
            }
        }
        .farmBackground()
        .navigationTitle(group?.name ?? "New group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if group == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            if canSave {
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button(group == nil ? "Create" : "Save") { Task { await save() } }.disabled(!valid)
                    }
                }
            }
        }
        .confirmationDialog("Delete \(group?.name ?? "group")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Remove \(pendingRemove?.username ?? "user")?", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from group", role: .destructive) { if let m = pendingRemove { Task { await remove(m) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isSystem ? "They lose everything this built-in group gives them. Bambuddy doesn't check that an admin remains." : "They lose what this group gave them.")
        }
        .sheet(isPresented: $addingMember) {
            NavigationStack {
                MemberPickerView(groupId: group?.id ?? 0, memberIds: Set(detail?.users.map(\.id) ?? [])) { await reloadDetail(); await onChanged() }
            }
        }
        .task { await load() }
        .onAppear(perform: populate)
    }

    // MARK: Sections

    @ViewBuilder private var membersSection: some View {
        Section {
            if let detail {
                ForEach(detail.users) { member in
                    HStack {
                        Text(member.username).font(.subheadline)
                        if !member.isActive { Pill(text: "Inactive", tint: .statusWarning) }
                        Spacer()
                        if allowed("groups:update") {
                            Button { pendingRemove = member } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.statusError) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(member.username)")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Remove from group") { if allowed("groups:update") { pendingRemove = member } }
                }
                if detail.users.isEmpty { Text("No members yet.").font(.subheadline).foregroundStyle(Color.textMuted) }
            } else if error == nil {
                ProgressView()
            }
            if allowed("groups:update"), session.can("users:read") {
                Button { addingMember = true } label: { Label("Add member", systemImage: "person.badge.plus") }
            }
        } header: { Text("Members\(detail.map { " (\($0.users.count))" } ?? "")") }
    }

    @ViewBuilder private var permissionsSections: some View {
        if categories.isEmpty, error == nil {
            Section("Permissions") { ProgressView() }
        }
        ForEach(categories) { category in
            Section {
                ForEach(category.permissions) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item.value) },
                                         set: { if $0 { selected.insert(item.value) } else { selected.remove(item.value) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.subheadline)
                            Text(item.value).font(.caption2.monospaced()).foregroundStyle(Color.textMuted)
                        }
                    }
                    .disabled(!canEditPermissions)
                }
            } header: {
                HStack {
                    Text(category.name)
                    Spacer()
                    if canEditPermissions {
                        let all = Set(category.permissions.map(\.value))
                        let allOn = all.isSubset(of: selected)
                        Button(allOn ? "None" : "All") { if allOn { selected.subtract(all) } else { selected.formUnion(all) } }
                            .font(.caption).textCase(nil)
                            .accessibilityLabel(allOn ? "Clear all \(category.name) permissions" : "Select all \(category.name) permissions")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func populate() {
        guard !populated else { return }
        populated = true
        if let group {
            name = group.name
            details = group.description ?? ""
            selected = Set(group.permissions)
            original = selected
        }
    }

    private func load() async {
        do {
            categories = try await session.perform { try await APIClient.shared.groupPermissionCategories(bearer: $0) }
            if group != nil { await reloadDetail() }
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func reloadDetail() async {
        guard let group else { return }
        do {
            detail = try await session.perform { try await APIClient.shared.groupDetail(group.id, bearer: $0) }
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let group {
                var patch: [String: AdminJSON] = [:]
                if !isSystem, trimmed != group.name { patch["name"] = .string(trimmed) }
                if details != (group.description ?? "") { patch["description"] = .string(details) }
                if !isSystem, selected != original { patch["permissions"] = .array(selected.sorted().map { .string($0) }) }
                guard !patch.isEmpty else { dismiss(); return }
                try await session.perform { try await APIClient.shared.updateGroup(group.id, patch: .object(patch), bearer: $0) }
            } else {
                try await session.perform {
                    try await APIClient.shared.createGroup(name: trimmed, description: details, permissions: selected.sorted(), bearer: $0)
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onChanged()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func delete() async {
        guard let group else { return }
        saving = true
        defer { saving = false }
        do {
            try await session.perform { try await APIClient.shared.deleteGroup(group.id, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await onChanged()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func remove(_ member: APIClient.GroupMember) async {
        guard let group else { return }
        pendingRemove = nil
        do {
            try await session.perform { try await APIClient.shared.removeUserFromGroup(group.id, userId: member.id, bearer: $0) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            error = nil
            await reloadDetail()
            await onChanged()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}

// MARK: - Add members

private struct MemberPickerView: View {
    let groupId: Int
    let memberIds: Set<Int>
    var onAdded: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var users: [AdminUser] = []
    @State private var loaded = false
    @State private var busyId: Int?
    @State private var error: String?
    @State private var added: Set<Int> = []
    @State private var search = ""

    private var candidates: [AdminUser] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return users.filter { !memberIds.contains($0.id) && !added.contains($0.id) && (q.isEmpty || $0.username.lowercased().contains(q)) }
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(candidates) { user in
                Button {
                    Task { await add(user) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.username).foregroundStyle(.primary)
                            if let email = user.email, !email.isEmpty { Text(email).font(.caption).foregroundStyle(Color.textMuted) }
                        }
                        Spacer()
                        if busyId == user.id { ProgressView() } else { Image(systemName: "plus.circle").foregroundStyle(Color.accentTeal) }
                    }
                }
                .disabled(busyId != nil)
                .accessibilityLabel("Add \(user.username)")
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Users")
        .overlay {
            if !loaded, error == nil { ProgressView() }
            else if loaded, candidates.isEmpty, error == nil { ContentUnavailableView("Everyone is already in", systemImage: "person.2.fill") }
        }
        .navigationTitle("Add member")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            do { users = try await session.perform { try await APIClient.shared.adminUsers(bearer: $0) } }
            catch { self.error = AdminError.friendly(error) }
            loaded = true
        }
    }

    private func add(_ user: AdminUser) async {
        busyId = user.id
        defer { busyId = nil }
        do {
            try await session.perform { try await APIClient.shared.addUserToGroup(groupId, userId: user.id, bearer: $0) }
            added.insert(user.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            error = nil
            await onAdded()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
