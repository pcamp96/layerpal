import SwiftUI

/// Network discovery for Add Printer (discovery:scan). The server reports whether it can use SSDP;
/// a Docker install can't receive multicast, so it scans a subnet instead.
struct DiscoverySheet: View {
    var onPick: (OpsDiscoveredPrinter) -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var info: OpsDiscoveryInfo?
    @State private var found: [OpsDiscoveredPrinter] = []
    @State private var existingSerials: Set<String> = []
    @State private var running = false
    @State private var progress: (scanned: Int, total: Int)?
    @State private var subnet = ""
    @State private var finished = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    private var newPrinters: [OpsDiscoveredPrinter] { found.filter { !existingSerials.contains($0.serial) } }
    private var alreadyAdded: Int { found.count - newPrinters.count }

    var body: some View {
        NavigationStack {
            List {
                if let info {
                    Section {
                        OpsValueRow(label: "Method", value: info.isDocker ? "Subnet scan (Docker)" : "SSDP broadcast")
                        if info.isDocker {
                            TextField("Subnet, e.g. 192.168.1.0/24", text: $subnet)
                                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !info.subnets.isEmpty {
                                Picker("Detected networks", selection: $subnet) {
                                    ForEach(info.subnets, id: \.self) { Text($0).tag($0) }
                                }
                            }
                        }
                    } footer: {
                        Text(info.isDocker
                            ? "Bambuddy is running in Docker, where multicast discovery doesn't work. It will probe each address on the subnet."
                            : "Bambuddy listens for printers announcing themselves for 10 seconds. Printers must be on the same network as the server, with LAN mode on.")
                    }
                }
                Section {
                    if running {
                        HStack {
                            ProgressView()
                            Text(progress.map { "Scanning \($0.scanned) of \($0.total)…" } ?? "Listening for printers…")
                                .font(.subheadline).foregroundStyle(Color.textSecondary)
                            Spacer()
                            Button("Stop") { Task { await stop() } }
                        }
                    } else {
                        Button { Task { await start() } } label: {
                            Label(finished ? "Search again" : "Start search", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .disabled(info == nil || (info?.isDocker == true && subnet.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                    if let error { OpsBanner(kind: .error, text: error) }
                }
                if !newPrinters.isEmpty {
                    Section {
                        ForEach(newPrinters) { printer in
                            Button {
                                OpsHaptics.tap()
                                onPick(printer)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(printer.name.isEmpty ? "Bambu printer" : printer.name).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        if let model = printer.model, !model.isEmpty {
                                            Pill(text: Printer.modelNames[model] ?? model, tint: .accentTeal)
                                        }
                                    }
                                    Text(printer.ipAddress).font(.caption).foregroundStyle(Color.textSecondary)
                                    Text(printer.serial).font(.caption2.monospaced()).foregroundStyle(Color.textMuted)
                                    if printer.realSerial.isEmpty {
                                        Text("Serial wasn't announced; you'll need to enter it.").font(.caption2).foregroundStyle(Color.statusWarning)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityHint("Fills the add printer form with this printer")
                        }
                    } header: { Text("Found") } footer: {
                        Text("Tap a printer to fill in its name, serial, address and model. You still need its access code.")
                    }
                } else if finished, !running {
                    Section {
                        Text(found.isEmpty ? "No printers found." : "Every printer found is already added.")
                            .font(.subheadline).foregroundStyle(Color.textMuted)
                    }
                }
                if alreadyAdded > 0, !newPrinters.isEmpty {
                    Section { Text("\(alreadyAdded) already added, hidden.").font(.footnote).foregroundStyle(Color.textMuted) }
                }
            }
            .farmBackground()
            .navigationTitle("Find printers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await loadInfo() }
            .onDisappear {
                pollTask?.cancel()
                // Leave nothing running on the server.
                Task { try? await stopQuietly() }
            }
        }
        .presentationDetents([.large])
    }

    private func loadInfo() async {
        do {
            let loaded = try await session.perform { try await APIClient.shared.discoveryInfo(bearer: $0) }
            info = loaded
            if subnet.isEmpty { subnet = UserDefaults.standard.string(forKey: "layerpal.discovery.subnet") ?? loaded.subnets.first ?? "" }
            let printers = try? await session.perform { try await APIClient.shared.adminPrinters(bearer: $0) }
            existingSerials = Set((printers ?? []).compactMap(\.serialNumber))
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func start() async {
        error = nil
        found = []
        finished = false
        progress = nil
        OpsHaptics.tap()
        do {
            if info?.isDocker == true {
                let cidr = subnet.trimmingCharacters(in: .whitespaces)
                UserDefaults.standard.set(cidr, forKey: "layerpal.discovery.subnet")
                try await session.perform { try await APIClient.shared.startSubnetScan(subnet: cidr, bearer: $0) }
            } else {
                try await session.perform { try await APIClient.shared.startDiscovery(duration: 10, bearer: $0) }
            }
            running = true
            pollTask?.cancel()
            pollTask = Task { await poll() }
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    /// Polls the scan status once a second until the server says it's done (cap 5 minutes).
    private func poll() async {
        let isScan = info?.isDocker == true
        let deadline = Date().addingTimeInterval(isScan ? 300 : 15)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            do {
                found = try await session.perform { try await APIClient.shared.discoveredPrinters(bearer: $0) }
                if isScan {
                    let s = try await session.perform { try await APIClient.shared.subnetScanStatus(bearer: $0) }
                    progress = s.total > 0 ? (s.scanned, s.total) : nil
                    if !s.running, s.total > 0 { break }
                }
            } catch {
                self.error = AdminError.friendly(error)
                break
            }
        }
        if Task.isCancelled { return }
        if !isScan { try? await stopQuietly() }
        found = (try? await session.perform { try await APIClient.shared.discoveredPrinters(bearer: $0) }) ?? found
        running = false
        finished = true
        if !newPrinters.isEmpty { OpsHaptics.success() }
    }

    private func stop() async {
        pollTask?.cancel()
        try? await stopQuietly()
        found = (try? await session.perform { try await APIClient.shared.discoveredPrinters(bearer: $0) }) ?? found
        running = false
        finished = true
    }

    private func stopQuietly() async throws {
        let docker = info?.isDocker == true
        try await session.perform { bearer in
            if docker { try await APIClient.shared.stopSubnetScan(bearer: bearer) } else { try await APIClient.shared.stopDiscovery(bearer: bearer) }
        }
    }
}
