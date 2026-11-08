import SwiftUI

/// Server updates (Bambuddy Settings > Updates). Checking needs system:read; applying
/// needs settings:update. Only git installs can update in place: Docker, Home Assistant add-on and
/// Windows installer installs get the server's instructions instead. Bambuddy does NOT restart
/// itself after an update ("Please restart the application"), so this screen says so.
struct UpdatesView: View {
    var body: some View {
        AdminGate(title: "Updates", permission: "system:read") { UpdatesContent() }
    }
}

private struct UpdatesContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var version: String?
    @State private var check: OpsUpdateCheck?
    @State private var checking = false
    @State private var error: String?
    @State private var autoCheck = true
    @State private var beta = false
    @State private var settingsLoaded = false
    @State private var confirming = false
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case applying(progress: Int, message: String, reconnecting: Bool)
        case finished(message: String)
        case failed(String)
    }

    private var canApply: Bool { session.can("settings:update") }
    private var gitInstall: Bool { (check?.updateMethod ?? "git") == "git" }
    private var busy: Bool { if case .applying = phase { true } else { false } }

    var body: some View {
        List {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            versionSection
            if let check { resultSection(check) }
            progressSection
            settingsSection
        }
        .farmBackground()
        .task { await loadVersion(); await loadSettings() }
        .refreshable { await loadVersion() }
        .sheet(isPresented: $confirming) {
            TypedConfirmSheet(
                title: "Update Bambuddy",
                consequence: "Bambuddy will download \(check?.latestVersion.map { "version \($0)" } ?? "the latest release") and replace its own code on the server. The web interface and this app may be unreachable while it installs, and Bambuddy must be restarted on the server afterwards, so only continue if you can do that. Make a backup first.",
                word: "UPDATE", actionTitle: "Install update") { Task { await apply() } }
        }
    }

    // MARK: Sections

    private var versionSection: some View {
        Section {
            OpsValueRow(label: "Installed version", value: version.map { "v\($0)" } ?? "…")
            OpsActionButton(title: "Check for updates", systemImage: "arrow.triangle.2.circlepath", busy: checking, disabled: busy) {
                Task { await runCheck() }
            }
        } footer: {
            Text("The check runs on your Bambuddy server, which asks GitHub for the latest release.")
        }
    }

    @ViewBuilder private func resultSection(_ c: OpsUpdateCheck) -> some View {
        Section {
            if let err = c.error {
                OpsBanner(kind: .error, text: c.retryAfter.map { "\(err) Try again in about \(max(1, $0 / 60)) min." } ?? err)
            } else if c.updateAvailable {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentTeal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.releaseName ?? "Version \(c.latestVersion ?? "")").font(.subheadline.weight(.semibold))
                        Text("v\(c.currentVersion) to v\(c.latestVersion ?? "?")" + (c.publishedAt.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                            .font(.caption).foregroundStyle(Color.textMuted)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                OpsBanner(kind: .success, text: c.message ?? "You're on the latest version (v\(c.currentVersion)).")
            }
            if let notes = c.releaseNotes, !notes.isEmpty, c.updateAvailable {
                DisclosureGroup("Release notes") {
                    Text(notesText(notes)).font(.footnote).foregroundStyle(Color.textSecondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let url = c.releaseURL, c.updateAvailable { Link(destination: url) { Label("Open release on GitHub", systemImage: "safari") } }
            if c.updateAvailable { applyControls(c) }
        } header: {
            Text(c.updateAvailable ? "Update available" : "Status")
        }
    }

    @ViewBuilder private func applyControls(_ c: OpsUpdateCheck) -> some View {
        switch c.updateMethod ?? "git" {
        case "docker":
            OpsBanner(kind: .info, text: "This Bambuddy runs in Docker, which can't update itself. On the server run: git pull && docker compose build --pull && docker compose up -d")
        case "windows_installer":
            OpsBanner(kind: .info, text: "Windows installs update by re-running the installer.")
            if let url = c.installerDownloadURL { Link(destination: url) { Label("Download installer", systemImage: "arrow.down.to.line") } }
        case "ha_addon":
            OpsBanner(kind: .info, text: "This is a Home Assistant add-on. Update it in Home Assistant under Settings, Add-ons, Bambuddy.")
        default:
            if canApply {
                Button(role: .destructive) { OpsHaptics.warning(); confirming = true } label: {
                    Label("Install update…", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(busy)
            } else {
                OpsBanner(kind: .warning, text: "Your account needs settings:update to install updates.")
            }
        }
    }

    @ViewBuilder private var progressSection: some View {
        switch phase {
        case .idle: EmptyView()
        case let .applying(progress, message, reconnecting):
            Section("Installing") {
                VStack(alignment: .leading, spacing: 8) {
                    FarmProgressBar(value: Double(progress))
                    Text(reconnecting ? "Bambuddy isn't answering. It is likely installing or restarting; still waiting…" : (message.isEmpty ? "Working…" : message))
                        .font(.subheadline).foregroundStyle(Color.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        case let .finished(message):
            Section {
                OpsBanner(kind: .success, text: message)
                OpsBanner(kind: .warning, text: "Restart Bambuddy on the server to run the new version (for example `sudo systemctl restart bambuddy`). This app can't restart it.")
                OpsActionButton(title: "Check version again", systemImage: "arrow.clockwise") { Task { await loadVersion() } }
            }
        case let .failed(text):
            Section { OpsBanner(kind: .error, text: text) }
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(get: { autoCheck }, set: { new in save("check_updates", new, revert: { autoCheck = !new }); autoCheck = new }))
            Toggle("Include beta versions", isOn: Binding(get: { beta }, set: { new in save("include_beta_updates", new, revert: { beta = !new }); beta = new }))
        } header: {
            Text("Preferences")
        } footer: {
            Text(canApply ? "Beta releases can be less stable. This also decides which release Bambuddy installs." : "Your account can't change settings (settings:update).")
        }
        .disabled(!canApply || !settingsLoaded)
    }

    // MARK: Logic

    private func notesText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }

    private func loadVersion() async {
        do {
            version = try await session.perform { try await APIClient.shared.serverVersion(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func loadSettings() async {
        if let s = try? await session.perform({ try await APIClient.shared.adminSettings(bearer: $0) }) {
            autoCheck = s["check_updates"]?.bool ?? true
            beta = s["include_beta_updates"]?.bool ?? false
            settingsLoaded = true
        }
    }

    private func save(_ key: String, _ value: Bool, revert: @escaping () -> Void) {
        Task {
            do {
                _ = try await session.perform { try await APIClient.shared.patchSettings([key: .bool(value)], bearer: $0) }
                OpsHaptics.tap()
            } catch {
                self.error = AdminError.friendly(error)
                revert()
            }
        }
    }

    private func runCheck() async {
        checking = true
        error = nil
        defer { checking = false }
        do {
            check = try await session.perform { try await APIClient.shared.checkForUpdates(bearer: $0) }
            if check?.updateAvailable == true { OpsHaptics.success() } else { OpsHaptics.tap() }
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    /// Starts the update, then polls /updates/status until it reports complete or error. The
    /// server can stop answering mid-install; that is treated as "still going", not as failure.
    private func apply() async {
        let before = version
        phase = .applying(progress: 5, message: "Starting…", reconnecting: false)
        do {
            let r = try await session.perform { try await APIClient.shared.applyUpdate(bearer: $0) }
            guard r.success else {
                phase = .failed(r.message.isEmpty ? "Bambuddy declined to start the update." : r.message)
                OpsHaptics.error()
                return
            }
        } catch {
            phase = .failed(AdminError.friendly(error))
            OpsHaptics.error()
            return
        }
        let deadline = Date().addingTimeInterval(20 * 60)
        var lost = false
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            do {
                let s = try await session.perform { try await APIClient.shared.updateStatus(bearer: $0) }
                if lost {
                    // Back after a gap: a restarted server reports idle with the new version.
                    lost = false
                    if let now = try? await session.perform({ try await APIClient.shared.serverVersion(bearer: $0) }) {
                        version = now
                        if now != before, s.status == "idle" || s.status == "complete" {
                            phase = .finished(message: "Bambuddy is back on v\(now).")
                            OpsHaptics.success()
                            return
                        }
                    }
                }
                switch s.status {
                case "complete":
                    phase = .finished(message: s.message.isEmpty ? "Update installed." : s.message)
                    OpsHaptics.success()
                    return
                case "error":
                    phase = .failed(s.error ?? s.message)
                    OpsHaptics.error()
                    return
                default:
                    phase = .applying(progress: s.progress, message: s.message, reconnecting: false)
                }
            } catch AdminError.signInRequired {
                phase = .failed("Your admin session ended. Sign in again and check the version to see whether the update finished.")
                return
            } catch {
                lost = true
                if case let .applying(p, m, _) = phase { phase = .applying(progress: p, message: m, reconnecting: true) }
            }
        }
        phase = .failed("Timed out waiting for Bambuddy. Check the server directly; the update may still have finished.")
    }
}
