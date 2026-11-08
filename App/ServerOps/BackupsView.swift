import SwiftUI

/// Backups (Bambuddy Settings > Backup): scheduled local backups on the server and the
/// Git-hosted (GitHub, GitLab, Gitea, Forgejo) backup. Needs an admin session; each half
/// needs its own permission (settings:backup, github:backup). No NavigationStack inside.
struct BackupsView: View {
    var body: some View {
        AdminGate(title: "Backups", permission: nil) { BackupsContent() }
    }
}

private struct BackupsContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var tab = 0

    private var canLocal: Bool { session.can("settings:backup") }
    private var canGit: Bool { session.can("github:backup") }

    var body: some View {
        VStack(spacing: 0) {
            if canLocal, canGit {
                Picker("Backup type", selection: $tab) {
                    Text("Local").tag(0)
                    Text("Git").tag(1)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .padding(.bottom, 6)
            }
            if canLocal, !canGit || tab == 0 {
                LocalBackupSection()
            } else if canGit {
                GitBackupSection()
            } else {
                ContentUnavailableView("Not available for your account", systemImage: "lock.fill",
                                       description: Text("Your Bambuddy account needs settings:backup or github:backup."))
            }
        }
        .background(Color.bgPrimary)
    }
}

// MARK: - Local

private struct LocalBackupSection: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var status: OpsLocalBackupStatus?
    @State private var files: [OpsBackupFile] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var running = false
    @State private var pathCheck: OpsPathCheck?
    @State private var checkingPath = false
    @State private var busyFile: String?
    @State private var share: OpsShareItem?
    @State private var deleting: OpsBackupFile?
    @State private var restoring: OpsBackupFile?
    @State private var restoreResult: String?
    // schedule draft
    @State private var enabled = false
    @State private var schedule = "daily"
    @State private var time = Date()
    @State private var retention = 5
    @State private var path = ""
    @State private var saving = false

    private var canEditSchedule: Bool { session.can("settings:update") }
    private var isAdmin: Bool { session.authEnabled == false || session.me?.isAdmin == true }

    var body: some View {
        List {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            if let notice { Section { OpsBanner(kind: .success, text: notice) } }
            if let restoreResult {
                Section {
                    OpsBanner(kind: .warning, text: restoreResult)
                } footer: {
                    Text("Restart Bambuddy on the server so it loads the restored data. You may need to sign in again.")
                }
            }
            if let status { statusSection(status) }
            actionsSection
            scheduleSection
            filesSection
        }
        .farmBackground()
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $share) { OpsShareSheet(url: $0.url) }
        .sheet(item: $restoring) { file in
            TypedConfirmSheet(
                title: "Restore backup",
                consequence: "This replaces Bambuddy's whole database and data folders (printers, archives, settings, users, library) with the contents of \(file.filename). Anything newer than the backup is lost, and Bambuddy needs a restart afterwards. Run a fresh backup first if you aren't sure.",
                word: "RESTORE", actionTitle: "Restore \(file.filename)") { restore(file) }
        }
        .confirmationDialog("Delete this backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { file in
            Button("Delete \(file.filename)", role: .destructive) { delete(file) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The backup file is removed from the server for good.")
        }
    }

    // MARK: Sections

    private func statusSection(_ s: OpsLocalBackupStatus) -> some View {
        Section("Status") {
            if s.isRunning { HStack { ProgressView(); Text("A backup is running…").font(.subheadline) } }
            OpsValueRow(label: "Last backup", value: s.lastBackupAt?.opsShort ?? "Never")
            if let last = s.lastStatus {
                HStack {
                    Text("Result").font(.subheadline).foregroundStyle(Color.textSecondary)
                    Spacer()
                    Pill(text: last.capitalized, tint: last == "success" ? .accentTeal : .statusError)
                }
            }
            if let message = s.lastMessage, !message.isEmpty { Text(message).font(.footnote).foregroundStyle(Color.textMuted) }
            if s.enabled { OpsValueRow(label: "Next run", value: s.nextRun?.opsShort ?? "Not scheduled") }
            OpsValueRow(label: "Folder", value: s.path.isEmpty ? s.defaultPath : s.path, mono: true)
        }
    }

    private var actionsSection: some View {
        Section {
            OpsActionButton(title: "Back up now", systemImage: "externaldrive.badge.plus", busy: running) { runBackup() }
            OpsActionButton(title: "Check folder is writable", systemImage: "checkmark.shield", busy: checkingPath) { checkPath() }
            if let pathCheck {
                OpsBanner(kind: pathCheck.writable ? (pathCheck.warning == nil ? .success : .warning) : .error,
                          text: pathCheck.warning ?? pathCheck.message)
                if let detail = pathCheck.detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(Color.textMuted) }
                if let remedy = pathCheck.remedy, !remedy.isEmpty {
                    Text(remedy).font(.footnote.monospaced()).foregroundStyle(Color.textSecondary).textSelection(.enabled)
                }
            }
        } footer: {
            Text("A full backup includes the database, archives and settings. A folder the server can't write to otherwise only fails hours later.")
        }
    }

    private var scheduleSection: some View {
        Section {
            Toggle("Scheduled backups", isOn: $enabled)
            if enabled {
                Picker("Frequency", selection: $schedule) {
                    Text("Hourly").tag("hourly")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                }
                if schedule != "hourly" {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
                Stepper("Keep \(retention) backup\(retention == 1 ? "" : "s")", value: $retention, in: 1 ... 100)
            }
            TextField("Folder (blank = Bambuddy default)", text: $path)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.subheadline.monospaced())
            if draftChanged {
                Button { Task { await saveSchedule() } } label: {
                    HStack { Text("Save schedule"); if saving { Spacer(); ProgressView() } }
                }
                .disabled(saving)
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text(canEditSchedule
                ? "Time is in the server's zone\(status.map { $0.timezone.isEmpty ? "" : " (\($0.timezone))" } ?? ""). Older backups beyond the limit are deleted automatically."
                : "Your account can't change settings (settings:update), so the schedule is read-only.")
        }
        .disabled(!canEditSchedule)
    }

    private var filesSection: some View {
        Section {
            if files.isEmpty, loaded { Text("No backups on the server yet.").font(.subheadline).foregroundStyle(Color.textMuted) }
            ForEach(files) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename).font(.subheadline).lineLimit(2)
                        Text([file.createdAt?.opsShort, opsBytes(file.size)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    if busyFile == file.filename { ProgressView() }
                }
                .accessibilityElement(children: .combine)
                .contextMenu { fileActions(file) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = file } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    if isAdmin {
                        Button { download(file) } label: { Label("Download", systemImage: "square.and.arrow.down") }.tint(.accentTeal)
                    }
                }
            }
        } header: {
            Text("Backups on the server")
        } footer: {
            if !files.isEmpty { Text("Swipe to download or delete. Press and hold for restore.") }
        }
    }

    @ViewBuilder private func fileActions(_ file: OpsBackupFile) -> some View {
        if isAdmin {
            Button { download(file) } label: { Label("Download", systemImage: "square.and.arrow.down") }
            if session.can("settings:restore") {
                Button(role: .destructive) { restoring = file } label: { Label("Restore…", systemImage: "arrow.counterclockwise") }
            }
        }
        Button(role: .destructive) { deleting = file } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: State

    private var draftChanged: Bool {
        guard let s = status else { return false }
        return enabled != s.enabled || schedule != s.schedule || timeString != s.time || retention != s.retention || path != s.path
    }

    private var timeString: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func adopt(_ s: OpsLocalBackupStatus) {
        status = s
        enabled = s.enabled
        schedule = s.schedule
        retention = s.retention
        path = s.path
        let parts = s.time.split(separator: ":").compactMap { Int($0) }
        if parts.count >= 2 {
            time = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) ?? Date()
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let s = try await session.perform { try await APIClient.shared.localBackupStatus(bearer: $0) }
            if !draftChanged { adopt(s) } else { status = s }
            files = try await session.perform { try await APIClient.shared.localBackups(bearer: $0) }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func runBackup() {
        Task {
            running = true
            error = nil
            notice = nil
            defer { running = false }
            do {
                let r = try await session.perform { try await APIClient.shared.runLocalBackup(bearer: $0) }
                if r.success {
                    notice = r.filename.map { "Backup created: \($0)" } ?? r.message
                    OpsHaptics.success()
                } else {
                    error = [r.message, r.diagnosisMessage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                    OpsHaptics.error()
                }
                await load()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func checkPath() {
        Task {
            checkingPath = true
            defer { checkingPath = false }
            do {
                pathCheck = try await session.perform { try await APIClient.shared.localBackupPathCheck(bearer: $0) }
                pathCheck?.writable == true ? OpsHaptics.success() : OpsHaptics.error()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }

    private func saveSchedule() async {
        saving = true
        error = nil
        defer { saving = false }
        var patch: [String: AdminJSON] = [
            "local_backup_enabled": .bool(enabled), "local_backup_schedule": .string(schedule),
            "local_backup_time": .string(timeString), "local_backup_retention": .int(retention),
        ]
        if path != status?.path { patch["local_backup_path"] = .string(path.trimmingCharacters(in: .whitespaces)) }
        do {
            _ = try await session.perform { try await APIClient.shared.patchSettings(patch, bearer: $0) }
            OpsHaptics.success()
            notice = "Schedule saved."
            pathCheck = nil
            await load()
            if let s = status { adopt(s) }
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func download(_ file: OpsBackupFile) {
        Task {
            busyFile = file.filename
            error = nil
            defer { busyFile = nil }
            do {
                let url = try await session.perform { try await APIClient.shared.downloadLocalBackup(file.filename, bearer: $0) }
                share = OpsShareItem(url: url)
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func delete(_ file: OpsBackupFile) {
        Task {
            busyFile = file.filename
            error = nil
            defer { busyFile = nil }
            do {
                let r = try await session.perform { try await APIClient.shared.deleteLocalBackup(file.filename, bearer: $0) }
                if r.success { notice = "Deleted \(file.filename)."; OpsHaptics.warning() } else { error = r.message; OpsHaptics.error() }
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }

    private func restore(_ file: OpsBackupFile) {
        Task {
            busyFile = file.filename
            error = nil
            notice = nil
            restoreResult = nil
            defer { busyFile = nil }
            do {
                let r = try await session.perform { try await APIClient.shared.restoreLocalBackup(file.filename, bearer: $0) }
                if r.success {
                    restoreResult = r.message.isEmpty ? "Restored \(file.filename)." : r.message
                    OpsHaptics.success()
                } else {
                    error = r.message
                    OpsHaptics.error()
                }
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }
}

// MARK: - Git

private struct GitBackupSection: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var config: OpsGitConfig?
    @State private var draft = OpsGitConfig()
    @State private var token = ""
    @State private var status: OpsGitStatus?
    @State private var cloud: (bambu: Int, orca: Int) = (0, 0)
    @State private var logs: [OpsGitLog] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var testResult: OpsGitTest?
    @State private var testing = false
    @State private var saving = false
    @State private var running = false
    @State private var progress: String?
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var confirmRun = false
    @State private var showRestore = false

    private var isNew: Bool { config == nil }
    private var cloudAvailable: Bool { cloud.bambu + cloud.orca > 0 }
    private var canSave: Bool {
        !draft.repositoryURL.trimmingCharacters(in: .whitespaces).isEmpty && (!isNew || !token.isEmpty)
    }

    var body: some View {
        List {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            if let notice { Section { OpsBanner(kind: .success, text: notice) } }
            if let config { summarySection(config) }
            configSection
            categoriesSection
            scheduleSection
            actionsSection
            if !logs.isEmpty { logsSection }
            if config != nil {
                Section {
                    Button("Remove Git backup setup", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deletes the saved repository and token from Bambuddy. Commits already pushed stay in your repository.")
                }
            }
        }
        .farmBackground()
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showRestore) { GitRestoreSheet() }
        .confirmationDialog("Remove Git backup setup?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove setup", role: .destructive) { deleteConfig() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Bambuddy forgets the repository, branch, token and schedule.") }
        .confirmationDialog("Clear backup history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all but the last 10", role: .destructive) { clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only the history list in Bambuddy is trimmed. Your repository isn't touched.") }
        .confirmationDialog("Run a backup now?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Back up and push") { runBackup() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Bambuddy commits the selected data to \(draft.repositoryURL) and pushes it.") }
    }

    // MARK: Sections

    private func summarySection(_ c: OpsGitConfig) -> some View {
        Section("Status") {
            if status?.isRunning == true || running {
                HStack { ProgressView(); Text(progress ?? status?.progress ?? "A backup is running…").font(.subheadline) }
            }
            OpsValueRow(label: "Last backup", value: c.lastBackupAt?.opsShort ?? "Never")
            if let s = c.lastStatus {
                HStack {
                    Text("Result").font(.subheadline).foregroundStyle(Color.textSecondary)
                    Spacer()
                    Pill(text: s.capitalized, tint: s == "success" ? .accentTeal : .statusError)
                }
            }
            if let m = c.lastMessage, !m.isEmpty { Text(m).font(.footnote).foregroundStyle(Color.textMuted) }
            if let sha = c.lastCommit { OpsValueRow(label: "Commit", value: String(sha.prefix(8)), mono: true) }
            if c.scheduleEnabled { OpsValueRow(label: "Next run", value: c.nextRun?.opsShort ?? "Not scheduled") }
        }
    }

    private var configSection: some View {
        Section {
            TextField("Repository URL", text: $draft.repositoryURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Provider", selection: $draft.provider) {
                Text("GitHub").tag("github")
                Text("GitLab").tag("gitlab")
                Text("Gitea").tag("gitea")
                Text("Forgejo").tag("forgejo")
            }
            TextField("Branch", text: $draft.branch).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(isNew ? "Access token" : (config?.hasToken == true ? "Access token (blank keeps saved)" : "Access token"), text: $token)
                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Allow insecure HTTP", isOn: $draft.allowInsecureHTTP)
            Toggle("Backups enabled", isOn: $draft.enabled)
        } header: {
            Text("Repository")
        } footer: {
            Text("Use a private repository: backups can include printer access codes and integration tokens, and Bambuddy refuses a public one. The token is sent to your Bambuddy server only and isn't shown again.")
        }
    }

    private var categoriesSection: some View {
        Section {
            Toggle("K-profiles", isOn: $draft.backupKProfiles)
            Toggle("Bambu / Orca Cloud profiles", isOn: $draft.backupCloudProfiles).disabled(!cloudAvailable)
            Toggle("App settings", isOn: $draft.backupSettings)
            Toggle("Spool inventory", isOn: $draft.backupSpools)
            Toggle("Print archive history", isOn: $draft.backupArchives)
        } header: {
            Text("What to back up")
        } footer: {
            Text(cloudAvailable
                ? "Cloud profiles come from \(cloud.bambu) Bambu and \(cloud.orca) Orca account\(cloud.bambu + cloud.orca == 1 ? "" : "s") connected to Bambuddy."
                : "Cloud profiles need a Bambu or Orca Cloud account connected in Bambuddy.")
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Run on a schedule", isOn: $draft.scheduleEnabled)
            if draft.scheduleEnabled {
                Picker("Frequency", selection: $draft.scheduleType) {
                    Text("Hourly").tag("hourly")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            OpsActionButton(title: "Test connection", systemImage: "network", busy: testing,
                            disabled: draft.repositoryURL.isEmpty || (isNew && token.isEmpty)) { test() }
            if let testResult {
                OpsBanner(kind: testResult.success ? (testResult.isPrivate == true ? .success : .warning) : .error, text: testResult.message)
                if testResult.success, testResult.isPrivate != true {
                    OpsBanner(kind: .warning, text: "Couldn't confirm this repository is private. Bambuddy won't save it unless it is.")
                }
            }
            OpsActionButton(title: isNew ? "Save setup" : "Save changes", systemImage: "square.and.arrow.down", busy: saving, disabled: !canSave) {
                Task { await save() }
            }
            if !isNew {
                OpsActionButton(title: "Back up now", systemImage: "arrow.up.circle", busy: running, disabled: !(config?.enabled ?? false)) { confirmRun = true }
                if session.can("github:restore") {
                    OpsActionButton(title: "Restore from a backup…", systemImage: "arrow.counterclockwise") { showRestore = true }
                }
            }
        }
    }

    private var logsSection: some View {
        Section {
            ForEach(logs) { log in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Pill(text: log.status.capitalized, tint: log.status == "success" ? .accentTeal : (log.status == "running" ? .statusFinished : .statusError))
                        Text(log.trigger.capitalized).font(.caption).foregroundStyle(Color.textMuted)
                        Spacer()
                        Text(log.startedAt?.opsShort ?? "").font(.caption).foregroundStyle(Color.textMuted)
                    }
                    if let sha = log.commitSHA { Text("\(String(sha.prefix(8))) · \(log.filesChanged) file\(log.filesChanged == 1 ? "" : "s") changed").font(.caption.monospaced()) }
                    if let err = log.errorMessage, !err.isEmpty { Text(err).font(.caption).foregroundStyle(Color.statusError) }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            HStack { Text("History"); Spacer(); Button("Clear") { confirmClear = true }.font(.footnote) }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let c = try await session.perform { try await APIClient.shared.githubBackupConfig(bearer: $0) }
            config = c
            if let c { draft = c }
            cloud = try await session.perform { try await APIClient.shared.githubCloudAccounts(bearer: $0) }
            status = try? await session.perform { try await APIClient.shared.githubBackupStatus(bearer: $0) }
            logs = c == nil ? [] : ((try? await session.perform { try await APIClient.shared.githubBackupLogs(bearer: $0) }) ?? [])
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func test() {
        Task {
            testing = true
            testResult = nil
            error = nil
            defer { testing = false }
            do {
                let url = draft.repositoryURL.trimmingCharacters(in: .whitespaces)
                let provider = draft.provider
                let tok = token
                testResult = try await session.perform { try await APIClient.shared.testGithub(repoURL: url, token: tok, provider: provider, bearer: $0) }
                testResult?.success == true ? OpsHaptics.success() : OpsHaptics.error()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        var body: [String: AdminJSON] = [
            "repository_url": .string(draft.repositoryURL.trimmingCharacters(in: .whitespaces)),
            "branch": .string(draft.branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : draft.branch),
            "provider": .string(draft.provider),
            "allow_insecure_http": .bool(draft.allowInsecureHTTP),
            "enabled": .bool(draft.enabled),
            "schedule_enabled": .bool(draft.scheduleEnabled),
            "schedule_type": .string(draft.scheduleType),
            "backup_kprofiles": .bool(draft.backupKProfiles),
            "backup_cloud_profiles": .bool(draft.backupCloudProfiles && cloudAvailable),
            "backup_settings": .bool(draft.backupSettings),
            "backup_spools": .bool(draft.backupSpools),
            "backup_archives": .bool(draft.backupArchives),
        ]
        if !token.isEmpty { body["access_token"] = .string(token) }
        let create = isNew
        do {
            let saved = try await session.perform { try await APIClient.shared.saveGithubConfig(body, create: create, bearer: $0) }
            config = saved
            draft = saved
            token = ""
            notice = "Git backup saved."
            OpsHaptics.success()
            await load()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func runBackup() {
        Task {
            running = true
            error = nil
            notice = nil
            progress = nil
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if let s = try? await session.perform({ try await APIClient.shared.githubBackupStatus(bearer: $0) }) { progress = s.progress }
                }
            }
            defer { poller.cancel(); running = false; progress = nil }
            do {
                let r = try await session.perform { try await APIClient.shared.runGithubBackup(bearer: $0) }
                if r.success {
                    notice = r.message.isEmpty ? "Backup pushed." : r.message
                    OpsHaptics.success()
                } else {
                    error = r.message
                    OpsHaptics.error()
                }
                await load()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func deleteConfig() {
        Task {
            do {
                try await session.perform { try await APIClient.shared.deleteGithubConfig(bearer: $0) }
                config = nil
                draft = OpsGitConfig()
                token = ""
                logs = []
                notice = "Git backup setup removed."
                OpsHaptics.warning()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }

    private func clearLogs() {
        Task {
            do {
                let n = try await session.perform { try await APIClient.shared.clearGithubBackupLogs(keepLast: 10, bearer: $0) }
                notice = "Cleared \(n) history entr\(n == 1 ? "y" : "ies")."
                await load()
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }
}
