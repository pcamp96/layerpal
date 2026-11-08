import SwiftUI

/// Users and groups (Bambuddy: Settings > Users / Groups). Needs an admin session.
struct UsersAdminView: View {
    var body: some View {
        AdminGate(title: "Users & groups", permission: "users:read") { UsersAdminList() }
    }
}

private struct UsersAdminList: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var users: [AdminUser] = []
    @State private var groups: [AdminGroup] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false
    @State private var addingGroup = false

    private var canAddUser: Bool { session.can("users:create") }
    private var canAddGroup: Bool { session.can("groups:create") && (session.authEnabled == false || session.me?.isAdmin != false) }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            Section("Users") {
                ForEach(users) { user in
                    NavigationLink {
                        UserFormView(mode: .edit(user), groups: groups) { await load() }
                    } label: { row(user) }
                }
            }
            if !groups.isEmpty || canAddGroup {
                Section("Groups") {
                    if groups.isEmpty { Text("No groups yet.").font(.subheadline).foregroundStyle(Color.textMuted) }
                    ForEach(groups) { group in
                        NavigationLink { GroupEditorView(group: group) { await load() } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name).font(.subheadline.weight(.medium))
                                    Text("\(group.permissions.count) permissions · \(group.userCount ?? 0) users")
                                        .font(.caption).foregroundStyle(Color.textMuted)
                                }
                                Spacer()
                                if group.isSystem == true { Pill(text: "Built in", tint: .textSecondary) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .farmBackground()
        .overlay { if !loaded, error == nil { ProgressView() } }
        .toolbar {
            if canAddUser || canAddGroup {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canAddUser { Button { adding = true } label: { Label("Add user", systemImage: "person.badge.plus") } }
                        if canAddGroup { Button { addingGroup = true } label: { Label("Add group", systemImage: "person.3.fill") } }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add user or group")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { UserFormView(mode: .add, groups: groups) { await load() } }
        }
        .sheet(isPresented: $addingGroup) {
            NavigationStack { GroupEditorView(group: nil) { await load() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ u: AdminUser) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(u.username).font(.subheadline.weight(.semibold))
                if u.isAdmin { Pill(text: "Admin", tint: .accentTeal) }
                if !u.isActive { Pill(text: "Inactive", tint: .statusWarning) }
                if let src = u.authSource, src != "local" { Pill(text: src.uppercased(), tint: .textSecondary) }
            }
            let detail = [u.email, u.groups.map(\.name).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.textMuted).lineLimit(2) }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            users = try await session.perform { try await APIClient.shared.adminUsers(bearer: $0) }
            groups = (try? await session.perform { try await APIClient.shared.adminGroups(bearer: $0) }) ?? []
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}

// MARK: - Add / edit user

private struct UserFormView: View {
    enum Mode { case add, edit(AdminUser) }

    let mode: Mode
    let groups: [AdminGroup]
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var role = "user"
    @State private var active = true
    @State private var groupIds: Set<Int> = []
    @State private var advancedAuth = false
    @State private var smtpConfigured = false
    @State private var saving = false
    @State private var error: String?
    @State private var info: String?
    @State private var confirmDelete = false
    @State private var populated = false

    private var editing: AdminUser? { if case let .edit(u) = mode { u } else { nil } }
    private var isSelf: Bool { editing?.username == session.username }
    private var isLocal: Bool { (editing?.authSource ?? "local") == "local" }

    private var canSave: Bool {
        guard editing != nil else {
            if username.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            return advancedAuth ? !email.isEmpty : !password.isEmpty
        }
        return true
    }

    var body: some View {
        Form {
            Section {
                if let u = editing { LabeledContent("Username", value: u.username) } else {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField(advancedAuth ? "Email (required)" : "Email (optional)", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                if isLocal {
                    if editing == nil {
                        if advancedAuth {
                            Text("Bambuddy generates a password and emails it to the user.").font(.footnote).foregroundStyle(Color.textSecondary)
                        } else {
                            SecureField("Password", text: $password).textContentType(.newPassword)
                        }
                    } else if !advancedAuth, session.can("users:update") {
                        SecureField("New password (blank keeps current)", text: $password).textContentType(.newPassword)
                    }
                }
            } footer: {
                if !advancedAuth, isLocal { Text("Passwords need 8+ characters with upper and lower case, a number and a symbol.") }
            }
            Section("Access") {
                Picker("Role", selection: $role) {
                    Text("User").tag("user")
                    Text("Admin").tag("admin")
                }
                if editing != nil { Toggle("Active", isOn: $active).disabled(isSelf) }
            }
            if !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups) { g in
                        Toggle(g.name, isOn: Binding(get: { groupIds.contains(g.id) },
                                                     set: { if $0 { groupIds.insert(g.id) } else { groupIds.remove(g.id) } }))
                    }
                }
            }
            if editing != nil, advancedAuth, smtpConfigured, isLocal, session.can("users:update") {
                Section {
                    Button("Email a password reset link") { Task { await sendReset() } }.disabled(saving || (editing?.email ?? "").isEmpty)
                } footer: { Text("Sends the user a one-hour link to choose a new password.") }
            }
            if let info { Section { Text(info).font(.footnote).foregroundStyle(Color.textSecondary) } }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if editing != nil, session.can("users:delete") {
                Section {
                    Button("Delete user", role: .destructive) { confirmDelete = true }.disabled(isSelf)
                } footer: { Text(isSelf ? "You can't delete the account you're signed in with." : "Bambuddy won't delete the last admin.") }
            }
        }
        .farmBackground()
        .navigationTitle(editing?.username ?? "Add user")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button(editing == nil ? "Add" : "Save") { Task { await save() } }.disabled(!canSave) }
            }
        }
        .confirmationDialog("Delete \(editing?.username ?? "user")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete user, keep their items", role: .destructive) { Task { await delete(items: false) } }
            Button("Delete user and everything they created", role: .destructive) { Task { await delete(items: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Their archives, queue jobs and library files are kept (ownerless) or deleted with them.")
        }
        .task {
            if let s = try? await APIClient.shared.advancedAuthStatus() { advancedAuth = s.advancedAuthEnabled; smtpConfigured = s.smtpConfigured }
        }
        .onAppear(perform: populate)
    }

    private func populate() {
        guard !populated, let u = editing else { return }
        populated = true
        email = u.email ?? ""
        role = u.role
        active = u.isActive
        groupIds = Set(u.groups.map(\.id))
    }

    private func save() async {
        saving = true
        error = nil
        info = nil
        defer { saving = false }
        do {
            if let u = editing {
                var patch: [String: AdminJSON] = [:]
                if email != (u.email ?? "") { patch["email"] = .string(email) }
                if role != u.role { patch["role"] = .string(role) }
                if active != u.isActive { patch["is_active"] = .bool(active) }
                if groupIds != Set(u.groups.map(\.id)) { patch["group_ids"] = .array(groupIds.sorted().map { .int($0) }) }
                if !password.isEmpty { patch["password"] = .string(password) }
                guard !patch.isEmpty else { dismiss(); return }
                try await session.perform { try await APIClient.shared.updateUser(u.id, patch: .object(patch), bearer: $0) }
            } else {
                try await session.perform {
                    try await APIClient.shared.createUser(username: username.trimmingCharacters(in: .whitespaces),
                                                          password: advancedAuth ? nil : password,
                                                          email: email, role: role, groupIds: groupIds.sorted(), bearer: $0)
                }
            }
            password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func sendReset() async {
        guard let u = editing else { return }
        saving = true
        defer { saving = false }
        do {
            info = try await session.perform { try await APIClient.shared.sendPasswordResetLink(userId: u.id, bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func delete(items: Bool) async {
        guard let u = editing else { return }
        saving = true
        defer { saving = false }
        do {
            try await session.perform { try await APIClient.shared.deleteUser(u.id, deleteItems: items, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}
