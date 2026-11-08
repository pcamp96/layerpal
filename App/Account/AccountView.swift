import SwiftUI

/// Bambuddy: the signed-in user's own account. Who you are, password, two-factor, email preferences and
/// announcements. Runs on the sign-in session (these routes refuse API keys).
struct AccountView: View {
    var body: some View {
        SessionGate(title: "Account", needsLogin: true) { AccountContent() }
    }
}

private struct AccountContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var profile: AcctProfile?
    @State private var status: AcctTwoFAStatus?
    @State private var unread = 0
    @State private var error: String?
    @State private var confirmSignOut = false

    var body: some View {
        List {
            if let error { Section { InlineError(message: error) } }
            Section {
                if let profile {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(Color.accentTeal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.username).font(.headline)
                            Text(profile.email ?? "No email address").font(.subheadline).foregroundStyle(Color.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    LabeledContent("Role", value: profile.isAdmin == true ? "Administrator" : "User")
                    if let groups = profile.groups, !groups.isEmpty {
                        LabeledContent("Groups", value: groups.map(\.name).joined(separator: ", "))
                    }
                    LabeledContent("Sign-in", value: profile.isLocal ? "Bambuddy password" : "Directory (\(profile.authSource ?? "external"))")
                } else if error == nil {
                    HStack { Text("Loading"); Spacer(); ProgressView() }
                }
            } header: { Text("You") }
            Section("Security") {
                if profile?.isLocal != false {
                    NavigationLink { ChangePasswordView(isLocal: profile?.isLocal ?? true) } label: {
                        IconLabel(title: "Change password", symbol: "key.fill", tint: .orange)
                    }
                }
                NavigationLink { TwoFactorView(username: profile?.username ?? session.username ?? "bambuddy", email: profile?.email) } label: {
                    HStack {
                        IconLabel(title: "Two-factor sign-in", symbol: "lock.shield.fill", tint: .accentTeal)
                        Spacer()
                        if let status {
                            Pill(text: status.totpEnabled || status.emailOtpEnabled ? "On" : "Off",
                                 tint: status.totpEnabled || status.emailOtpEnabled ? .accentTeal : .textMuted)
                        }
                    }
                }
            }
            Section("Messages") {
                if session.can("notifications:user_email") {
                    NavigationLink { EmailPreferencesView(hasEmail: !(profile?.email ?? "").isEmpty) } label: {
                        IconLabel(title: "Email notifications", symbol: "envelope.fill", tint: .blue)
                    }
                }
                NavigationLink { AnnouncementsView { await refreshUnread() } } label: {
                    HStack {
                        IconLabel(title: "Announcements", symbol: "megaphone.fill", tint: .pink)
                        Spacer()
                        if unread > 0 {
                            Text("\(unread)").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.statusError, in: Capsule()).foregroundStyle(.white)
                                .accessibilityLabel("\(unread) unread")
                        }
                    }
                }
            }
            Section {
                Button("Sign out of LayerPal", role: .destructive) { confirmSignOut = true }
            } footer: { Text("Ends the sign-in session stored on this iPhone. Your Bambuddy account is untouched.") }
        }
        .farmBackground()
        .confirmationDialog("Sign out of Bambuddy on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { session.signOut() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            profile = try await session.perform { try await APIClient.shared.acctProfile(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        status = try? await session.perform { try await APIClient.shared.acct2FAStatus(bearer: $0) }
        await refreshUnread()
    }

    private func refreshUnread() async {
        if let result = try? await session.perform({ try await APIClient.shared.acctAnnouncements(bearer: $0) }) {
            unread = result.items.filter { !$0.read && !$0.archived }.count
        }
    }
}

// MARK: - Password

private struct ChangePasswordView: View {
    let isLocal: Bool
    @ObservedObject private var session = AdminSession.shared
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    /// The server rejects new passwords under 8 characters or without an uppercase letter, lowercase
    /// letter, digit and symbol; checked here first to save a round trip.
    private var problem: String? {
        if new.isEmpty { return nil }
        if new.count < 8 { return "Use at least 8 characters." }
        if new.range(of: "[A-Z]", options: .regularExpression) == nil { return "Add an uppercase letter." }
        if new.range(of: "[a-z]", options: .regularExpression) == nil { return "Add a lowercase letter." }
        if new.range(of: "[0-9]", options: .regularExpression) == nil { return "Add a digit." }
        if new.range(of: "[^A-Za-z0-9]", options: .regularExpression) == nil { return "Add a symbol such as ! or #." }
        if !confirm.isEmpty, confirm != new { return "The new passwords don't match." }
        return nil
    }

    private var canSubmit: Bool {
        isLocal && !busy && !current.isEmpty && !new.isEmpty && confirm == new && problem == nil
    }

    var body: some View {
        Form {
            if !isLocal {
                Section { Text("This account's password is managed by your directory server, so it can't be changed here.").font(.footnote) }
            }
            Section {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $new).textContentType(.newPassword)
                SecureField("Repeat new password", text: $confirm).textContentType(.newPassword)
            } footer: {
                Text(problem ?? "8 or more characters with an uppercase letter, a lowercase letter, a digit and a symbol.")
                    .foregroundStyle(problem == nil ? Color.textMuted : Color.statusError)
            }
            if let error { Section { InlineError(message: error) } }
            Section {
                Button { Task { await submit() } } label: {
                    HStack { Text("Change password"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(!canSubmit)
            } footer: { Text("Bambuddy signs every device out after a password change, including this one.") }
        }
        .farmBackground()
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Password changed", isPresented: $done) {
            Button("Sign in again") { session.signOut() }
        } message: { Text("Sign in with your new password.") }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let old = current, newer = new
            try await session.performKeepingSession { try await APIClient.shared.acctChangePassword(current: old, new: newer, bearer: $0) }
            current = ""; new = ""; confirm = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            done = true
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Email preferences

private struct EmailPreferencesView: View {
    let hasEmail: Bool
    @ObservedObject private var session = AdminSession.shared
    @State private var prefs: AcctEmailPrefs?
    @State private var saved: AcctEmailPrefs?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if let prefs {
                Section {
                    Toggle("Print started", isOn: bind(\.notifyPrintStart, prefs))
                    Toggle("Print finished", isOn: bind(\.notifyPrintComplete, prefs))
                    Toggle("Print failed", isOn: bind(\.notifyPrintFailed, prefs))
                    Toggle("Print stopped", isOn: bind(\.notifyPrintStopped, prefs))
                } header: { Text("Email me when") } footer: {
                    Text(hasEmail ? "Sent to the address on your Bambuddy account." : "Your account has no email address, so Bambuddy can't save these. Ask an admin to add one.")
                }
            } else if error == nil {
                Section { HStack { Text("Loading"); Spacer(); ProgressView() } }
            }
            if let error { Section { InlineError(message: error) } }
        }
        .farmBackground()
        .navigationTitle("Email notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() } else {
                    Button("Save") { Task { await save() } }.disabled(prefs == nil || prefs == saved || !hasEmail)
                }
            }
        }
        .task { await load() }
    }

    private func bind(_ key: WritableKeyPath<AcctEmailPrefs, Bool>, _ current: AcctEmailPrefs) -> Binding<Bool> {
        Binding(get: { prefs?[keyPath: key] ?? current[keyPath: key] }, set: { prefs?[keyPath: key] = $0 })
    }

    private func load() async {
        do {
            let loaded = try await session.perform { try await APIClient.shared.acctEmailPrefs(bearer: $0) }
            prefs = loaded
            saved = loaded
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func save() async {
        guard let prefs else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await session.perform { try await APIClient.shared.acctSaveEmailPrefs(prefs, bearer: $0) }
            saved = prefs
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Announcements

private struct AnnouncementsView: View {
    var onChange: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var items: [AcctAnnouncement] = []
    @State private var visible = true
    @State private var loaded = false
    @State private var error: String?
    @State private var expanded: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let error { Section { InlineError(message: error) } }
            let current = items.filter { !$0.archived }
            let earlier = items.filter(\.archived)
            if !current.isEmpty { Section { ForEach(current) { row($0) } } }
            if !earlier.isEmpty { Section("Earlier") { ForEach(earlier) { row($0) } } }
        }
        .farmBackground()
        .navigationTitle("Announcements")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !loaded, error == nil { ProgressView() }
            else if loaded, !visible {
                ContentUnavailableView("Not shown to your account", systemImage: "megaphone",
                                       description: Text("Bambuddy only shows announcements to admins, unless an admin turns them on for everyone."))
            } else if loaded, items.isEmpty, error == nil {
                ContentUnavailableView("No announcements", systemImage: "megaphone")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ item: AcctAnnouncement) -> some View {
        let open = expanded == item.id
        return VStack(alignment: .leading, spacing: 8) {
            Button { toggle(item) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(item.level)).foregroundStyle(tint(item.level)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(item.read ? .regular : .semibold)).multilineTextAlignment(.leading)
                        if let date = item.publishedAt {
                            Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                    Spacer()
                    if !item.read { Circle().fill(Color.accentTeal).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
            .foregroundStyle(.primary)
            if open {
                Text(item.body).font(.subheadline).foregroundStyle(Color.textSecondary)
                if let url = item.linkURL {
                    Button(item.linkLabel ?? "Learn more") { openURL(url) }.font(.subheadline)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ level: String) -> String {
        switch level {
        case "critical": "exclamationmark.octagon.fill"
        case "important": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    private func tint(_ level: String) -> Color {
        switch level {
        case "critical": .statusError
        case "important": .statusWarning
        default: .statusFinished
        }
    }

    private func toggle(_ item: AcctAnnouncement) {
        withAnimation { expanded = expanded == item.id ? nil : item.id }
        guard !item.read else { return }
        Task {
            do {
                try await session.perform { try await APIClient.shared.acctMarkAnnouncementRead(item.id, bearer: $0) }
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].read = true }
                await onChange()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }

    private func load() async {
        do {
            let result = try await session.perform { try await APIClient.shared.acctAnnouncements(bearer: $0) }
            visible = result.visible
            items = result.items
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}
