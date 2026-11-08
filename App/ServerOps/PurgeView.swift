import SwiftUI

/// Bulk cleanup (archive purge needs archives:purge; library trash purge needs library:purge).
/// Both are destructive, so each purge previews the exact count first and then needs a typed word.
struct PurgeView: View {
    var body: some View {
        AdminGate(title: "Purge tools", permission: nil) { PurgeContent() }
    }
}

private struct PurgeContent: View {
    @ObservedObject private var session = AdminSession.shared

    var body: some View {
        List {
            if session.can("archives:purge") { ArchivePurgeSections() }
            if session.can("library:purge") { LibraryPurgeSections() }
            if !session.can("archives:purge"), !session.can("library:purge") {
                Section { OpsBanner(kind: .warning, text: "Your account needs archives:purge or library:purge.") }
            }
        }
        .farmBackground()
    }
}

/// Number field clamped to the range the server accepts.
private struct DaysField: View {
    let title: String
    @Binding var days: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Days", value: $days, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                .onChange(of: days) { _, new in
                    let clamped = min(max(new, range.lowerBound), range.upperBound)
                    if clamped != new { days = clamped }
                }
            Text("days").foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Archives

private struct ArchivePurgeSections: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var days = 365
    @State private var purgeStats = false
    @State private var preview: OpsPurgePreview?
    @State private var previewKey = ""
    @State private var previewing = false
    @State private var confirming = false
    @State private var running = false
    @State private var settings = OpsArchivePurgeSettings()
    @State private var saved = OpsArchivePurgeSettings()
    @State private var settingsLoaded = false
    @State private var confirmAuto = false
    @State private var error: String?
    @State private var notice: String?

    private var key: String { "\(days)-\(purgeStats)" }
    private var previewFresh: Bool { preview != nil && previewKey == key }

    var body: some View {
        Group {
            Section {
                DaysField(title: "Older than", days: $days, range: 1 ... 3650)
                Toggle("Also remove from statistics", isOn: $purgeStats)
                OpsActionButton(title: "Preview", systemImage: "eye", busy: previewing) { Task { await runPreview() } }
                if let preview, previewFresh {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(preview.count) archive\(preview.count == 1 ? "" : "s") · \(opsBytes(preview.totalBytes))").font(.headline)
                        if !preview.samples.isEmpty {
                            Text(preview.samples.prefix(5).joined(separator: "\n")).font(.caption).foregroundStyle(Color.textMuted).lineLimit(6)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Button("Delete these archives…", role: .destructive) { OpsHaptics.warning(); confirming = true }
                        .disabled(preview.count == 0 || running)
                }
                if let error { OpsBanner(kind: .error, text: error) }
                if let notice { OpsBanner(kind: .success, text: notice) }
            } header: {
                Text("Purge old archives")
            } footer: {
                Text(purgeStats
                    ? "Deletes the print files and photos and also removes these prints from your statistics. This can't be undone."
                    : "Deletes the print files and photos from the server and hides the archive entries. Your statistics keep counting them. This can't be undone.")
            }

            Section {
                Toggle("Purge automatically", isOn: $settings.enabled)
                if settings.enabled {
                    DaysField(title: "Older than", days: $settings.days, range: 7 ... 3650)
                    Toggle("Also remove from statistics", isOn: $settings.purgeStats)
                }
                if settings != saved {
                    OpsActionButton(title: "Save", systemImage: "checkmark") {
                        if settings.enabled { confirmAuto = true } else { Task { await saveSettings() } }
                    }
                }
            } header: {
                Text("Automatic archive purge")
            } footer: {
                Text("Bambuddy runs this on a schedule. Minimum 7 days.")
            }
            .disabled(!settingsLoaded)
        }
        .sheet(isPresented: $confirming) {
            TypedConfirmSheet(
                title: "Delete archives",
                consequence: "\(preview?.count ?? 0) archives older than \(days) days (\(opsBytes(preview?.totalBytes ?? 0))) will be deleted from the server\(purgeStats ? " and removed from statistics" : ""). This can't be undone.",
                word: "DELETE", actionTitle: "Delete \(preview?.count ?? 0) archives") { Task { await run() } }
        }
        .confirmationDialog("Turn on automatic purge?", isPresented: $confirmAuto, titleVisibility: .visible) {
            Button("Save and enable", role: .destructive) { Task { await saveSettings() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bambuddy will delete archives older than \(settings.days) days on its own\(settings.purgeStats ? " and remove them from statistics" : "").")
        }
        .task { await loadSettings() }
    }

    private func runPreview() async {
        previewing = true
        error = nil
        notice = nil
        defer { previewing = false }
        do {
            let d = days, p = purgeStats
            preview = try await session.perform { try await APIClient.shared.archivePurgePreview(days: d, purgeStats: p, bearer: $0) }
            previewKey = key
            OpsHaptics.tap()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        do {
            let d = days, p = purgeStats
            let n = try await session.perform { try await APIClient.shared.archivePurge(days: d, purgeStats: p, bearer: $0) }
            notice = "Deleted \(n) archive\(n == 1 ? "" : "s")."
            preview = nil
            OpsHaptics.success()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func loadSettings() async {
        if let s = try? await session.perform({ try await APIClient.shared.archivePurgeSettings(bearer: $0) }) {
            settings = s
            saved = s
            settingsLoaded = true
        }
    }

    private func saveSettings() async {
        error = nil
        do {
            let s = settings
            try await session.perform { try await APIClient.shared.saveArchivePurgeSettings(s, bearer: $0) }
            saved = s
            notice = "Automatic purge settings saved."
            OpsHaptics.success()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }
}

// MARK: - Library

private struct LibraryPurgeSections: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var days = 180
    @State private var includeNever = true
    @State private var preview: OpsPurgePreview?
    @State private var previewKey = ""
    @State private var previewing = false
    @State private var confirming = false
    @State private var running = false
    @State private var settings = OpsTrashSettings()
    @State private var saved = OpsTrashSettings()
    @State private var settingsLoaded = false
    @State private var confirmAuto = false
    @State private var error: String?
    @State private var notice: String?

    private var key: String { "\(days)-\(includeNever)" }
    private var previewFresh: Bool { preview != nil && previewKey == key }

    var body: some View {
        Group {
            Section {
                DaysField(title: "Not used in", days: $days, range: 1 ... 3650)
                Toggle("Include files never printed", isOn: $includeNever)
                OpsActionButton(title: "Preview", systemImage: "eye", busy: previewing) { Task { await runPreview() } }
                if let preview, previewFresh {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(preview.count) file\(preview.count == 1 ? "" : "s") · \(opsBytes(preview.totalBytes))").font(.headline)
                        if !preview.samples.isEmpty {
                            Text(preview.samples.prefix(5).joined(separator: "\n")).font(.caption).foregroundStyle(Color.textMuted).lineLimit(6)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Button("Move these files to trash…", role: .destructive) { OpsHaptics.warning(); confirming = true }
                        .disabled(preview.count == 0 || running)
                }
                if let error { OpsBanner(kind: .error, text: error) }
                if let notice { OpsBanner(kind: .success, text: notice) }
            } header: {
                Text("Purge old library files")
            } footer: {
                Text("Moves files to the library trash, where they can be restored until the retention period below ends. After that they are deleted for good.")
            }

            Section {
                Stepper("Keep trash \(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")", value: $settings.retentionDays, in: 1 ... 365)
                Toggle("Purge automatically", isOn: $settings.autoPurgeEnabled)
                if settings.autoPurgeEnabled {
                    DaysField(title: "Older than", days: $settings.autoPurgeDays, range: 7 ... 3650)
                    Toggle("Include files never printed", isOn: $settings.autoPurgeIncludeNeverPrinted)
                }
                if settings != saved {
                    OpsActionButton(title: "Save", systemImage: "checkmark") {
                        if settings.autoPurgeEnabled, !saved.autoPurgeEnabled || settings.autoPurgeDays != saved.autoPurgeDays { confirmAuto = true }
                        else { Task { await saveSettings() } }
                    }
                }
            } header: {
                Text("Trash and automatic purge")
            } footer: {
                Text("Retention applies to everything in the trash, including files people delete by hand.")
            }
            .disabled(!settingsLoaded)
        }
        .sheet(isPresented: $confirming) {
            TypedConfirmSheet(
                title: "Purge library files",
                consequence: "\(preview?.count ?? 0) library files (\(opsBytes(preview?.totalBytes ?? 0))) go to the trash. They're deleted for good after \(saved.retentionDays) days unless restored.",
                word: "PURGE", actionTitle: "Move \(preview?.count ?? 0) files to trash") { Task { await run() } }
        }
        .confirmationDialog("Turn on automatic library purge?", isPresented: $confirmAuto, titleVisibility: .visible) {
            Button("Save", role: .destructive) { Task { await saveSettings() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bambuddy will move library files older than \(settings.autoPurgeDays) days to the trash on its own.")
        }
        .task { await loadSettings() }
    }

    private func runPreview() async {
        previewing = true
        error = nil
        notice = nil
        defer { previewing = false }
        do {
            let d = days, n = includeNever
            preview = try await session.perform { try await APIClient.shared.libraryPurgePreview(days: d, includeNeverPrinted: n, bearer: $0) }
            previewKey = key
            OpsHaptics.tap()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        do {
            let d = days, n = includeNever
            let moved = try await session.perform { try await APIClient.shared.libraryPurge(days: d, includeNeverPrinted: n, bearer: $0) }
            notice = "Moved \(moved) file\(moved == 1 ? "" : "s") to the trash."
            preview = nil
            OpsHaptics.success()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func loadSettings() async {
        if let s = try? await session.perform({ try await APIClient.shared.libraryTrashSettings(bearer: $0) }) {
            settings = s
            saved = s
            settingsLoaded = true
        }
    }

    private func saveSettings() async {
        error = nil
        do {
            let s = settings
            try await session.perform { try await APIClient.shared.saveLibraryTrashSettings(s, bearer: $0) }
            saved = s
            notice = "Trash settings saved."
            OpsHaptics.success()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }
}
