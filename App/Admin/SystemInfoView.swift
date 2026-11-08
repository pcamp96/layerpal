import SwiftUI

/// Read-only server health (GET /system/info, system:read). Works with the app's
/// API key, so no admin sign-in is needed.
struct SystemInfoView: View {
    @State private var info: AdminSystemInfo?
    @State private var error: String?
    @State private var health: OpsHealth?
    @State private var healthError: String?
    @State private var storage: OpsStorage?
    @State private var storageError: String?
    @State private var refreshingStorage = false
    @State private var pool: OpsDBPool?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError).frame(maxWidth: .infinity, alignment: .leading) }
                if let i = info {
                    server(i)
                    printers(i)
                    usage(i)
                    library(i)
                    healthCard
                    storageCard
                    poolCard
                } else if error == nil {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle("System")
        .task { await load() }
        .refreshable { await load() }
    }

    private func server(_ i: AdminSystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Server")
            Card {
                VStack(spacing: 8) {
                    SysRow(label: "Bambuddy", value: i.version)
                    SysRow(label: "Uptime", value: i.uptime)
                    SysRow(label: "Host", value: i.hostname)
                    SysRow(label: "Platform", value: i.platform)
                    SysRow(label: "Database", value: i.dbEngine)
                }
            }
        }
    }

    private func printers(_ i: AdminSystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Printers", trailing: "\(i.printersConnected) of \(i.printersTotal) connected")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    if i.connected.isEmpty {
                        Text("No printers connected.").font(.subheadline).foregroundStyle(Color.textMuted)
                    }
                    ForEach(i.connected) { p in
                        HStack {
                            Text(p.name).font(.subheadline)
                            Spacer()
                            Text([p.model, p.state].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.textMuted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func usage(_ i: AdminSystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Resources")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    meter("Disk", "\(i.diskFree) free of \(i.diskTotal)", i.diskUsedPercent)
                    meter("Memory", "\(i.memoryUsed) of \(i.memoryTotal)", i.memoryPercent)
                    meter("CPU", "\(Int(i.cpuPercent.rounded()))%", i.cpuPercent)
                    Divider()
                    SysRow(label: "Archive files", value: i.archiveSize)
                    SysRow(label: "Database size", value: i.dbSize)
                }
            }
        }
    }

    private func library(_ i: AdminSystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Totals")
            Card {
                VStack(spacing: 8) {
                    SysRow(label: "Archives", value: "\(i.archives) (\(i.archivesCompleted) done, \(i.archivesFailed) failed)")
                    SysRow(label: "Print time", value: i.totalPrintTime)
                    SysRow(label: "Filament used", value: String(format: "%.2f kg", i.totalFilamentKg))
                    SysRow(label: "Projects", value: "\(i.projects)")
                    SysRow(label: "Filaments", value: "\(i.filaments)")
                    SysRow(label: "Smart plugs", value: "\(i.smartPlugs)")
                }
            }
        }
    }

    // MARK: Health, storage, database pool (/system, system:read)

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Health", trailing: health.map { "\($0.scanned) log entries scanned" })
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    if let healthError {
                        OpsBanner(kind: .error, text: healthError)
                    } else if let health {
                        if !health.logAvailable {
                            Text("No log file to scan yet.").font(.subheadline).foregroundStyle(Color.textMuted)
                        } else if health.findings.isEmpty {
                            OpsBanner(kind: .success, text: "No known issues found in the recent log.")
                        }
                        ForEach(health.findings) { f in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Pill(text: f.severity.capitalized, tint: f.severity == "error" ? .statusError : .statusWarning)
                                    Text(f.id.replacingOccurrences(of: "-", with: " ").capitalized).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("x\(f.count)").font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted)
                                }
                                if !f.sample.isEmpty { Text(f.sample).font(.caption.monospaced()).foregroundStyle(Color.textSecondary).lineLimit(4) }
                                Text("Last seen \(f.lastSeen)").font(.caption2).foregroundStyle(Color.textMuted)
                            }
                            .accessibilityElement(children: .combine)
                            if f.id != health.findings.last?.id { Divider() }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Storage usage", trailing: storage?.total)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    if let storageError {
                        OpsBanner(kind: .error, text: storageError)
                    } else if let storage {
                        ForEach(storage.categories) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(c.label).font(.subheadline)
                                    Spacer()
                                    Text("\(c.formatted) · \(String(format: "%.1f", c.percent))%").font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted)
                                }
                                FarmProgressBar(value: c.percent)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if !storage.other.isEmpty {
                            DisclosureGroup("Other data") {
                                VStack(spacing: 6) {
                                    ForEach(storage.other) { o in SysRow(label: o.label, value: o.formatted) }
                                }
                                .padding(.top, 4)
                            }
                            .font(.subheadline)
                        }
                        if storage.scanErrors > 0 {
                            Text("\(storage.scanErrors) file\(storage.scanErrors == 1 ? "" : "s") couldn't be read.")
                                .font(.caption).foregroundStyle(Color.statusWarning)
                        }
                        HStack {
                            Text(storage.generatedAt.map { "Measured \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                                .font(.caption).foregroundStyle(Color.textMuted)
                            Spacer()
                            Button { Task { await loadStorage(refresh: true) } } label: {
                                if refreshingStorage { ProgressView() } else { Label("Rescan", systemImage: "arrow.clockwise") }
                            }
                            .font(.footnote).disabled(refreshingStorage)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
    }

    @ViewBuilder private var poolCard: some View {
        if let pool {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Database connections", trailing: pool.dialect.isEmpty ? nil : pool.dialect)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        if let out = pool.checkedOut, let size = pool.poolSize {
                            let ceiling = max(1, size + (pool.maxOverflow ?? 0))
                            meter("In use", "\(out) of \(ceiling)", Double(out) / Double(ceiling) * 100)
                        }
                        if let n = pool.checkedIn { SysRow(label: "Idle", value: "\(n)") }
                        if let n = pool.overflow { SysRow(label: "Overflow", value: "\(n)") }
                        if let n = pool.serverMax { SysRow(label: "Server allows", value: "\(n)") }
                    }
                }
            }
        }
    }

    private func meter(_ title: String, _ detail: String, _ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(Color.textMuted)
            }
            FarmProgressBar(value: percent, tint: percent > 90 ? .statusError : (percent > 75 ? .statusWarning : .accentTeal))
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            info = try await APIClient.shared.systemInfo(bearer: AdminSession.shared.bearer)
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        // Independent of the main info: a failure here only affects its own card.
        async let h: Void = loadHealth()
        async let st: Void = loadStorage(refresh: false)
        async let p: Void = loadPool()
        _ = await (h, st, p)
    }

    private func loadHealth() async {
        do {
            health = try await APIClient.shared.systemHealth(bearer: AdminSession.shared.bearer)
            healthError = nil
        } catch {
            healthError = AdminError.friendly(error)
        }
    }

    private func loadStorage(refresh: Bool) async {
        if refresh { refreshingStorage = true }
        defer { refreshingStorage = false }
        do {
            storage = try await APIClient.shared.storageUsage(refresh: refresh, bearer: AdminSession.shared.bearer)
            storageError = nil
            if refresh { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        } catch {
            storageError = AdminError.friendly(error)
        }
    }

    private func loadPool() async {
        pool = try? await APIClient.shared.dbPool(bearer: AdminSession.shared.bearer)
    }
}

private struct SysRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(Color.textSecondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.monospacedDigit()).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
