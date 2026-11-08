import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var admin = AdminSession.shared
    @State private var maintenanceDue = 0
    @State private var lowSpools = 0
    @State private var pendingUploads = 0

    /// Before sign-in every admin row shows (the screen asks for a login);
    /// afterwards rows the account has no permission for are hidden.
    private func adminShows(_ permission: String) -> Bool { !admin.isSignedIn || admin.can(permission) }

    var body: some View {
        NavigationStack {
            List {
                Section("Farm") {
                    if farm.can("camera:view") {
                        NavigationLink { CamWallView() } label: { IconLabel(title: "Camera wall", symbol: "video.fill", tint: .teal) }
                    }
                    NavigationLink { LocationsView() } label: {
                        IconLabel(title: "Locations", symbol: "mappin.and.ellipse", tint: .statusFinished)
                    }
                    if farm.can("smart_plugs:read") {
                        NavigationLink { SmartPlugsView() } label: {
                            IconLabel(title: "Smart plugs", symbol: "powerplug.fill", tint: .statusWarning)
                        }
                    }
                    if farm.can("firmware:read") {
                        NavigationLink { FirmwareView() } label: { IconLabel(title: "Firmware", symbol: "cpu.fill", tint: .indigo) }
                    }
                }
                Section("Work") {
                    if farm.can("projects:read") {
                        NavigationLink { ProjectsView() } label: {
                            IconLabel(title: "Projects", symbol: "square.stack.3d.up.fill", tint: .pink)
                        }
                    }
                    NavigationLink { LibraryHomeView() } label: {
                        IconLabel(title: "Library", symbol: "folder.fill", tint: .statusFinished)
                    }
                    NavigationLink { InventoryHomeView() } label: {
                        badgeLabel("Inventory", "cylinder.split.1x2.fill", iconTint: .purple, count: lowSpools, tint: .statusWarning)
                    }
                    NavigationLink { MaintenanceHomeView() } label: {
                        badgeLabel("Maintenance", "wrench.and.screwdriver.fill", iconTint: .orange, count: maintenanceDue, tint: .statusError)
                    }
                    NavigationLink { StatsDashboardView() } label: { IconLabel(title: "Stats", symbol: "chart.bar.fill") }
                    NavigationLink { PrintLogView() } label: { IconLabel(title: "Print log", symbol: "list.bullet.rectangle.fill", tint: .teal) }
                    if farm.can("queue:read_all") || farm.can("queue:read_own") {
                        NavigationLink { PendingUploadsView() } label: {
                            badgeLabel("Pending uploads", "tray.and.arrow.down.fill", iconTint: .indigo, count: pendingUploads, tint: .statusFinished)
                        }
                    }
                    NavigationLink { ActivityView() } label: { IconLabel(title: "Activity", symbol: "bell.badge.fill", tint: .statusError) }
                    NavigationLink { ProfilesView() } label: { IconLabel(title: "Profiles & K-values", symbol: "slider.vertical.3", tint: .cyan) }
                    if farm.can("pipelines:read") {
                        NavigationLink { PipelinesView() } label: { IconLabel(title: "Pipelines", symbol: "arrow.triangle.branch", tint: .mint) }
                    }
                    NavigationLink { ModelSourcesView() } label: { IconLabel(title: "Model sources", symbol: "shippingbox.fill", tint: .brown) }
                    NavigationLink { FinanceView() } label: { IconLabel(title: "Finance", symbol: "dollarsign.circle.fill", tint: .green) }
                    NavigationLink { FilamentCatalogView() } label: { IconLabel(title: "Filament catalog", symbol: "books.vertical.fill", tint: .purple) }
                    NavigationLink { LabelTemplatesView() } label: { IconLabel(title: "Spool labels", symbol: "tag.fill", tint: .orange) }
                    NavigationLink { IntegrationsView() } label: { IconLabel(title: "Integrations", symbol: "puzzlepiece.extension.fill", tint: .blue) }
                    if farm.can("external_links:read") {
                        NavigationLink { ExternalLinksView() } label: { IconLabel(title: "Links", symbol: "link", tint: .blue) }
                    }
                }
                Section {
                    AdminSessionRow()
                    if adminShows("printers:read") {
                        NavigationLink { PrintersAdminView() } label: { IconLabel(title: "Printers", symbol: "printer.fill", tint: .accentTeal) }
                    }
                    if adminShows("notifications:read") {
                        NavigationLink { NotificationsAdminView() } label: { IconLabel(title: "Notifications", symbol: "bell.fill", tint: .orange) }
                    }
                    if adminShows("users:read") {
                        NavigationLink { UsersAdminView() } label: { IconLabel(title: "Users & groups", symbol: "person.2.fill", tint: .blue) }
                    }
                    if adminShows("api_keys:read") {
                        NavigationLink { APIKeysAdminView() } label: { IconLabel(title: "API keys", symbol: "key.fill", tint: .purple) }
                    }
                    if adminShows("settings:read") {
                        NavigationLink { SettingsAdminView() } label: { IconLabel(title: "Bambuddy settings", symbol: "slider.horizontal.3", tint: .gray) }
                    }
                    if adminShows("settings:read") {
                        NavigationLink { VirtualPrintersView() } label: { IconLabel(title: "Virtual printers", symbol: "printer.dotmatrix.fill", tint: .indigo) }
                    }
                    if adminShows("camera:view") {
                        NavigationLink { TokensView() } label: { IconLabel(title: "Access tokens", symbol: "key.horizontal.fill", tint: .yellow) }
                    }
                    NavigationLink { BackupsView() } label: { IconLabel(title: "Backups", symbol: "externaldrive.fill.badge.timemachine", tint: .blue) }
                    NavigationLink { UpdatesView() } label: { IconLabel(title: "Bambuddy updates", symbol: "arrow.down.circle.fill", tint: .accentTeal) }
                    NavigationLink { SupportView() } label: { IconLabel(title: "Support & logs", symbol: "stethoscope", tint: .red) }
                    NavigationLink { PurgeView() } label: { IconLabel(title: "Purge", symbol: "trash.fill", tint: .gray) }
                    if adminShows("system:read") {
                        NavigationLink { SystemInfoView() } label: { IconLabel(title: "System", symbol: "server.rack", tint: .teal) }
                    }
                } header: { Text("Admin") }
                Section("You") {
                    NavigationLink { AccountView() } label: { IconLabel(title: "Account & security", symbol: "person.crop.circle.fill", tint: .blue) }
                }
                Section("App") {
                    NavigationLink { SettingsView(onSaved: { farm.restart() }) } label: {
                        IconLabel(title: "LayerPal settings", symbol: "gearshape.fill", tint: .gray)
                    }
                    if let url = ServerConfig.serverURL {
                        Link(destination: url) { IconLabel(title: "Open Bambuddy on the web", symbol: "safari", tint: .blue) }.foregroundStyle(.primary)
                    }
                }
            }
            .farmBackground()
            .navigationTitle("More")
            .task {
                await admin.refreshStatus()
                maintenanceDue = ((try? await APIClient.shared.maintenanceOverview()) ?? []).reduce(0) { $0 + ($1.dueCount ?? 0) }
                lowSpools = ((try? await APIClient.shared.spools()) ?? []).filter { $0.remainingFraction < 0.2 }.count
                pendingUploads = await PendingUploadsBadge.count()
            }
        }
    }

    private func badgeLabel(_ title: String, _ symbol: String, iconTint: Color, count: Int, tint: Color) -> some View {
        HStack {
            IconLabel(title: title, symbol: symbol, tint: iconTint)
            Spacer()
            if count > 0 {
                Text("\(count)").font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tint, in: Capsule()).foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Stats

struct StatsView: View {
    @State private var range = 7
    @State private var stats: ArchiveStats?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Range", selection: $range) {
                    Text("Today").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Year").tag(365)
                }
                .pickerStyle(.segmented)
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if let s = stats {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        tile("Prints", "\(s.totalPrints ?? 0)", "printer.fill")
                        tile("Success rate", s.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "checkmark.seal.fill",
                             tint: (s.successRate ?? 1) < 0.85 ? .statusWarning : .accentTeal)
                        tile("Print time", formatHours(s.totalPrintTimeHours ?? 0), "clock.fill")
                        tile("Filament", formatGrams(s.totalFilamentGrams ?? 0), "scribble.variable")
                        tile("Failed", "\(s.failedPrints ?? 0)", "xmark.octagon.fill", tint: (s.failedPrints ?? 0) > 0 ? .statusError : .textSecondary)
                        tile("Cancelled", "\(s.cancelledPrints ?? 0)", "stop.circle.fill", tint: .textSecondary)
                        if let cost = s.totalCost, cost > 0 {
                            tile("Cost", cost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")), "dollarsign.circle.fill")
                        }
                        if let kwh = s.totalEnergyKwh, kwh > 0 {
                            tile("Energy", String(format: "%.1f kWh", kwh), "bolt.fill")
                        }
                    }
                } else if error == nil {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("Stats")
        .task(id: range) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            stats = try await APIClient.shared.stats(days: range)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func tile(_ label: String, _ value: String, _ symbol: String, tint: Color = .accentTeal) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(value).font(.title2.weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.caption).foregroundStyle(Color.textMuted)
            }
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @State private var entries: [NotificationLogEntry] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(e.title ?? e.eventType ?? "Event").font(.subheadline.weight(.medium))
                        Spacer()
                        if let d = e.createdAt { Text(d, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(Color.textMuted) }
                    }
                    if let m = e.message, !m.isEmpty { Text(m).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(3) }
                    if let p = e.printerName { Text(p).font(.caption2).foregroundStyle(Color.textMuted) }
                }
            }
        }
        .farmBackground()
        .navigationTitle("Activity")
        .overlay { if entries.isEmpty, error == nil { ContentUnavailableView("No recent activity", systemImage: "bell") } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            // One event per print, not one per notification provider.
            let all = try await APIClient.shared.activity()
            // Same event, one row per provider, seconds apart: keep the first within a minute.
            var kept: [NotificationLogEntry] = []
            for e in all {
                let dup = kept.contains { k in
                    k.eventType == e.eventType && k.title == e.title && k.message == e.message
                        && abs((k.createdAt ?? .distantPast).timeIntervalSince(e.createdAt ?? .distantPast)) < 60
                }
                if !dup { kept.append(e) }
            }
            entries = kept
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Library

struct LibraryBrowser: View {
    let folder: LibraryFolder?
    var onPick: ((LibraryFile) -> Void)?
    @EnvironmentObject private var farm: FarmStore
    @State private var folders: [LibraryFolder] = []
    @State private var files: [LibraryFile] = []
    @State private var queuing: LibraryFile?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            let subfolders = flatten(folders).filter { $0.parentId == folder?.id }
            if !subfolders.isEmpty {
                Section {
                    ForEach(subfolders) { f in
                        NavigationLink { LibraryBrowser(folder: f, onPick: onPick).navigationTitle(f.name) } label: {
                            HStack {
                                Label(f.name, systemImage: "folder.fill").foregroundStyle(.primary)
                                Spacer()
                                if let n = f.fileCount, n > 0 { Text("\(n)").font(.caption).foregroundStyle(Color.textMuted) }
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(files) { file in
                    Button { pick(file) } label: { fileRow(file) }
                        .buttonStyle(.plain)
                        .disabled(!file.isSliced && onPick != nil)
                }
            }
        }
        .farmBackground()
        .overlay { if files.isEmpty, folders.isEmpty, error == nil { ContentUnavailableView("Empty folder", systemImage: "folder") } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $queuing) { file in
            TargetPicker(title: file.name, slicedFor: file.slicedForModel, archiveId: nil, libraryFileId: file.id) { request in
                try await APIClient.shared.addToQueue(QueueCreateBody(archiveId: nil, libraryFileId: file.id, request: request))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func fileRow(_ file: LibraryFile) -> some View {
        HStack(spacing: 12) {
            RemoteImage(path: "library/files/\(file.id)/thumbnail")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    if let model = file.slicedForModel { Text(Printer.modelNames[model] ?? model) }
                    if let s = file.printTimeSeconds, s > 0 { Text(formatMinutes(s / 60)) }
                    if !file.isSliced { Text("Not sliced") }
                }
                .font(.caption).foregroundStyle(Color.textMuted)
            }
            Spacer()
            if file.isSliced, farm.canQueue { Image(systemName: "plus.circle").foregroundStyle(Color.accentTeal) }
        }
        .contentShape(Rectangle())
    }

    /// /library/folders may come back as a tree or flat; normalize to flat.
    private func flatten(_ list: [LibraryFolder]) -> [LibraryFolder] {
        list.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func pick(_ file: LibraryFile) {
        guard file.isSliced else { return }
        if let onPick { onPick(file) } else if farm.canQueue { queuing = file }
    }

    private func load() async {
        do {
            folders = try await APIClient.shared.libraryFolders()
            files = try await APIClient.shared.libraryFiles(folderId: folder?.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
