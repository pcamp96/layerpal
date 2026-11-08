import SwiftUI

/// Firmware per printer, with updates available first. Needs `firmware:read`. For printers with an update,
/// an admin with `firmware:update` can copy the firmware to the printer's SD card (Bambuddy's LAN helper).
struct FirmwareView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var items: [FarmFirmware] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var search = ""

    private var filtered: [FarmFirmware] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? items : items.filter { "\($0.printerName) \($0.model ?? "") \($0.currentVersion ?? "")".lowercased().contains(q) }
        return list.sorted {
            if $0.updateAvailable != $1.updateAvailable { return $0.updateAvailable }
            return $0.printerName.localizedStandardCompare($1.printerName) == .orderedAscending
        }
    }

    private var updateCount: Int { items.filter(\.updateAvailable).count }
    private var checksOff: Bool { loaded && !items.isEmpty && items.allSatisfy { $0.latestVersion == nil } }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if checksOff {
                Label("No update information. Firmware checks may be turned off in Bambuddy's settings, or the printers are offline.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(Color.textMuted)
            }
            let list = filtered
            let pending = list.filter(\.updateAvailable)
            if !pending.isEmpty {
                Section("Updates available") { ForEach(pending) { FirmwareRow(info: $0) } }
            }
            let current = list.filter { !$0.updateAvailable }
            if !current.isEmpty {
                Section(pending.isEmpty ? "Printers" : "Up to date") { ForEach(current) { FirmwareRow(info: $0) } }
            }
        }
        .farmBackground()
        .navigationTitle("Firmware")
        .searchable(text: $search, prompt: "Printer, model, version")
        .overlay {
            if loaded, items.isEmpty, error == nil {
                ContentUnavailableView("No printers", systemImage: "cpu")
            } else if !loaded, error == nil {
                ProgressView()
            }
        }
        .toolbar {
            if updateCount > 0 {
                ToolbarItem(placement: .topBarTrailing) { Pill(text: "\(updateCount) update\(updateCount == 1 ? "" : "s")", tint: .statusWarning) }
            }
        }
        // Re-run once the farm has loaded its printer list (opening this screen first thing would otherwise see none).
        .task(id: farm.activePrinters.map { $0.id }) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let ids = farm.activePrinters.map(\.id)
        guard !ids.isEmpty else { loaded = true; return }
        do {
            items = try await APIClient.shared.firmwareUpdates(ids: ids)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

private struct FirmwareRow: View {
    let info: FarmFirmware

    var body: some View {
        if info.updateAvailable {
            NavigationLink { FirmwareDetail(info: info) } label: { content }
        } else {
            content
        }
    }


    private var notes: String? {
        let direct = info.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        let fromList = info.availableVersions?.first { $0.version == info.latestVersion }?.releaseNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fromList?.isEmpty == false ? fromList : nil
    }

    private var content: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.printerName).font(.subheadline.weight(.medium))
                    if let model = info.model, model != "Unknown" {
                        Text(Printer.modelNames[model] ?? model).font(.caption2).foregroundStyle(Color.textMuted)
                    }
                }
                Text(versionLine).font(.caption.monospacedDigit()).foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 8)
            if info.updateAvailable { Pill(text: "Update", tint: .statusWarning, systemImage: "arrow.up.circle") }
        }
        .accessibilityElement(children: .combine)
    }

    private var versionLine: String {
        let current = info.currentVersion ?? "Unknown version"
        if info.updateAvailable, let latest = info.latestVersion { return "\(current) → \(latest)" }
        return current
    }
}

private struct FirmwareDetail: View {
    let info: FarmFirmware
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var session = AdminSession.shared
    @State private var installing = false

    private var notes: String {
        let direct = info.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }
        return info.availableVersions?.first { $0.version == info.latestVersion }?.releaseNotes ?? ""
    }

    private var printerIdle: Bool { FirmwareInstallSheet.idleStates.contains(farm.statuses[info.printerId]?.state?.uppercased() ?? "") }
    private var signedOutNeedsLogin: Bool { session.authEnabled != false && !session.isSignedIn }
    private var canInstall: Bool { session.can("firmware:update") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info.printerName).font(.headline)
                        Text("\(info.currentVersion ?? "Unknown") → \(info.latestVersion ?? "Unknown")")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(Color.textSecondary)
                    }
                }
                installCard
                if !notes.isEmpty {
                    SectionHeader(title: "Release notes")
                    Card { Text(notes).font(.footnote).textSelection(.enabled) }
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle(info.latestVersion ?? "Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.refreshStatus() }
        .sheet(isPresented: $installing) { FirmwareInstallSheet(info: info) }
        .sheet(isPresented: $session.showSignIn) { AdminSignInSheet() }
    }

    @ViewBuilder private var installCard: some View {
        if info.updateAvailable {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Install on the printer", systemImage: "externaldrive.badge.plus").font(.subheadline.weight(.semibold))
                    Text("Bambuddy downloads the firmware and copies it to the printer's SD card. You then finish the update on the printer's screen.")
                        .font(.footnote).foregroundStyle(Color.textSecondary)
                    if signedOutNeedsLogin {
                        Button { session.showSignIn = true } label: { Label("Sign in as admin to install", systemImage: "lock.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    } else if canInstall {
                        Button { installing = true } label: { Label("Prepare update…", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(.accentTeal).disabled(!printerIdle)
                        if !printerIdle {
                            Text(farm.statuses[info.printerId]?.connected == false ? "The printer is offline." : "The printer is busy. Firmware can only be copied while it is idle.")
                                .font(.caption).foregroundStyle(Color.statusWarning)
                        }
                    } else {
                        Text("Your Bambuddy account doesn't have firmware:update, so firmware can't be installed from here.")
                            .font(.caption).foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
    }
}

/// Bambuddy's LAN-only firmware helper: prepare (SD card, space, idle checks), upload to the SD card, poll
/// progress, then the user finishes on the printer. GET .../prepare and .../upload/status need firmware:read;
/// POST .../upload needs firmware:update, which API keys never get, so all of it runs on the admin session.
private struct FirmwareInstallSheet: View {
    static let idleStates: Set<String> = ["IDLE", "FINISH", "FAILED"]

    let info: FarmFirmware
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var version = ""
    @State private var prepare: FirmwarePrepare?
    @State private var checking = false
    @State private var typed = ""
    @State private var starting = false
    @State private var state: FirmwareUploadState?
    @State private var error: String?
    @State private var polling = false
    @FocusState private var focused: Bool

    private static let confirmWord = "UPDATE"

    private var versions: [String] {
        let list = (info.availableVersions ?? []).map(\.version)
        guard let latest = info.latestVersion else { return list }
        return list.contains(latest) ? list : [latest] + list
    }

    private var printerIdle: Bool { Self.idleStates.contains(farm.statuses[info.printerId]?.state?.uppercased() ?? "") }
    private var running: Bool { ["preparing", "downloading", "uploading"].contains(state?.status ?? "") }
    private var finished: Bool { state?.status == "complete" }
    private var chosenVersion: String? { version.isEmpty || version == info.latestVersion ? nil : version }
    private var confirmed: Bool { typed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(Self.confirmWord) == .orderedSame }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { OpsBanner(kind: .error, text: error) } }
                if finished {
                    finishedSection
                } else if running {
                    progressSection
                } else {
                    setupSections
                }
            }
            .farmBackground()
            .navigationTitle("Update \(info.printerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(finished ? "Done" : "Close") { dismiss() } }
            }
            .task { await initialLoad() }
            .interactiveDismissDisabled(starting)
        }
        .presentationDetents([.large])
    }

    // MARK: Sections

    @ViewBuilder private var setupSections: some View {
        Section {
            OpsValueRow(label: "Installed", value: info.currentVersion ?? "Unknown", mono: true)
            if versions.count > 1 {
                Picker("Version to copy", selection: $version) {
                    ForEach(versions, id: \.self) { Text($0 == info.latestVersion ? "\($0) (latest)" : $0).tag($0) }
                }
                .onChange(of: version) { _, _ in
                    prepare = nil
                    typed = ""
                    Task { await runPrepare() }
                }
            } else {
                OpsValueRow(label: "Update to", value: info.latestVersion ?? "Latest", mono: true)
            }
        }
        Section {
            if checking { HStack { ProgressView(); Text("Checking the printer…").font(.subheadline) } }
            if let prepare {
                checkRow("Printer is idle", ok: !prepare.errors.contains { $0.localizedCaseInsensitiveContains("busy") } && printerIdle)
                checkRow("SD card inserted", ok: prepare.sdCardPresent)
                checkRow(prepare.freeSpace >= 0 ? "Space on the card (\(opsBytes(prepare.freeSpace)) free)" : "Space on the card (unknown)", ok: prepare.spaceSufficient)
                ForEach(prepare.errors, id: \.self) { OpsBanner(kind: .error, text: $0) }
            }
            Button { Task { await runPrepare() } } label: {
                Label(prepare == nil ? "Check the printer" : "Check again", systemImage: "checklist")
            }
            .disabled(checking || starting)
        } header: {
            Text("Before you start")
        } footer: {
            Text("The printer must be idle with an SD card in it. The firmware file is about 100 MB.")
        }
        if prepare?.canProceed == true {
            Section {
                Label {
                    Text("This copies firmware to \(info.printerName)'s SD card. Nothing is installed until you start the update on the printer, and a firmware update takes 10 to 20 minutes during which the printer can't be used. Don't power it off.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
                }
                .font(.subheadline)
                TextField(Self.confirmWord, text: $typed)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().focused($focused)
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        Text("Copy firmware to SD card").frame(maxWidth: .infinity)
                        if starting { ProgressView() }
                    }
                }
                .disabled(!confirmed || starting || !printerIdle)
            } header: {
                Text("Type \(Self.confirmWord) to confirm")
            }
        }
    }

    private var progressSection: some View {
        Section {
            let s = state
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label(for: s?.status ?? "")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(s?.progress ?? 0)%").font(.subheadline.monospacedDigit())
                }
                ProgressView(value: Double(s?.progress ?? 0), total: 100).tint(.accentTeal)
                if let message = s?.message, !message.isEmpty { Text(message).font(.caption).foregroundStyle(Color.textMuted) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(for: s?.status ?? ""))
            .accessibilityValue("\(s?.progress ?? 0) percent")
        } footer: {
            Text("Bambuddy does this in the background, so you can close this screen. Keep the printer idle and powered on.")
        }
    }

    private var finishedSection: some View {
        Group {
            Section {
                OpsBanner(kind: .success, text: "Firmware copied to the SD card.")
                if let v = state?.version ?? prepare?.targetVersion ?? info.latestVersion { OpsValueRow(label: "Version", value: v, mono: true) }
            }
            Section {
                Label("On the printer's touchscreen, go to Settings.", systemImage: "1.circle")
                Label("Pick Firmware.", systemImage: "2.circle")
                Label("Choose to update from the SD card.", systemImage: "3.circle")
                Label("Wait while it installs. Expect 10 to 20 minutes.", systemImage: "4.circle")
            } header: {
                Text("Install it at the printer")
            } footer: {
                Text("This last step can only be done at the printer.")
            }
        }
    }

    private func checkRow(_ title: String, ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.subheadline).foregroundStyle(ok ? Color.accentTeal : Color.statusError)
            .accessibilityElement(children: .combine)
            .accessibilityValue(ok ? "passed" : "failed")
    }

    private func label(for status: String) -> String {
        switch status {
        case "preparing": "Preparing"
        case "downloading": "Downloading from Bambu Lab"
        case "uploading": "Copying to the SD card"
        default: "Working"
        }
    }

    // MARK: Logic

    private func initialLoad() async {
        if version.isEmpty { version = info.latestVersion ?? "" }
        // A run started earlier (or from the web) may still be going.
        if let current = try? await session.perform({ try await APIClient.shared.firmwareUploadStatus(info.printerId, bearer: $0) }) {
            state = current
            if running { await poll(); return }
            if finished { return }
            state = nil
        }
        await runPrepare()
    }

    private func runPrepare() async {
        checking = true
        error = nil
        defer { checking = false }
        let chosen = chosenVersion
        do {
            prepare = try await session.perform { try await APIClient.shared.firmwarePrepare(info.printerId, version: chosen, bearer: $0) }
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func start() async {
        starting = true
        error = nil
        defer { starting = false }
        let chosen = chosenVersion
        do {
            let r = try await session.perform { try await APIClient.shared.firmwareStartUpload(info.printerId, version: chosen, bearer: $0) }
            OpsHaptics.warning()
            if !r.started, !r.message.localizedCaseInsensitiveContains("already") { error = r.message; return }
            state = FirmwareUploadState(json: .object(["status": .string("preparing"), "progress": .int(0)]))
            await poll()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        var failures = 0
        var idlePolls = 0
        while !Task.isCancelled {
            do {
                let current = try await session.perform { try await APIClient.shared.firmwareUploadStatus(info.printerId, bearer: $0) }
                failures = 0
                state = current
                if current.status == "complete" { OpsHaptics.success(); return }
                if current.status == "idle", idlePolls < 3 { idlePolls += 1; try? await Task.sleep(for: .seconds(1)); continue }
                if current.status == "error" || current.status == "idle" {
                    if current.status == "error" { error = current.error ?? "The upload failed."; OpsHaptics.error() }
                    state = nil
                    return
                }
            } catch {
                failures += 1
                if failures >= 5 { self.error = AdminError.friendly(error); return }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
