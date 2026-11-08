import SwiftUI
import UIKit

/// Virtual printers (Bambuddy: Settings > Virtual printer). Listing needs `settings:read`; every change
/// needs `settings:update`, which Bambuddy never grants to API keys, so the screen runs on the admin session.
/// Create, edit (including access code and bind addresses), delete and the slicer CA certificate live here too.
struct VirtualPrintersView: View {
    var body: some View {
        AdminGate(title: "Virtual printers", permission: "settings:read") { VirtualPrinterList() }
    }
}

private struct VirtualPrinterList: View {
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var session = AdminSession.shared
    @State private var printers: [VPrinter] = []
    @State private var tailscale: VPTailscale?
    @State private var loaded = false
    @State private var error: String?
    @State private var diagnostic: (VPrinter, VPDiagnostic)?
    @State private var diagnosing: Int?
    @State private var pendingDisable: VPrinter?
    @State private var pendingDelete: VPrinter?
    @State private var creating = false
    @State private var editingPrinter: VPrinter?

    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError).padding(.horizontal, 4) }
                if let tailscale { tailscaleCard(tailscale) }
                if printers.isEmpty, loaded, error == nil {
                    ContentUnavailableView("No virtual printers", systemImage: "printer.dotmatrix",
                                           description: Text(canEdit ? "Tap + to create one so slicers can send prints straight to it."
                                                                     : "Ask an admin to create one so slicers can send prints straight to it."))
                }
                ForEach(printers) { vp in card(vp) }
                if loaded { VirtualPrinterCACard() }
            }
            .padding()
        }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New virtual printer")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { VirtualPrinterForm(mode: .create) { await load() } }
        }
        .sheet(item: $editingPrinter) { vp in
            NavigationStack { VirtualPrinterForm(mode: .edit(vp)) { await load() } }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "virtual printer")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete virtual printer", role: .destructive) { if let vp = pendingDelete { delete(vp) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops, and files it received that you haven't archived yet are discarded. Slicers that were using it lose it.")
        }
        .background(Color.bgPrimary)
        .overlay { if !loaded, error == nil { ProgressView() } }
        .sheet(isPresented: Binding(get: { diagnostic != nil }, set: { if !$0 { diagnostic = nil } })) {
            if let diagnostic { NavigationStack { DiagnosticSheet(printer: diagnostic.0, result: diagnostic.1) } }
        }
        .confirmationDialog("Turn off \(pendingDisable?.name ?? "virtual printer")?",
                            isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
                            titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { if let vp = pendingDisable { patch(vp, "enabled", .bool(false)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Slicers stop seeing it and any upload in progress is dropped.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Cards

    private func tailscaleCard(_ ts: VPTailscale) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Label(ts.available ? "Tailscale connected" : "Tailscale not available", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ts.available ? Color.accentTeal : Color.textSecondary)
                if ts.available {
                    if let fqdn = ts.fqdn, !fqdn.isEmpty { Text(fqdn).font(.caption.monospaced()).textSelection(.enabled) }
                    if let ips = ts.tailscaleIps, !ips.isEmpty {
                        Text(ips.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(Color.textSecondary).textSelection(.enabled)
                    }
                    Text("Virtual printers use a trusted certificate over Tailscale.").font(.caption).foregroundStyle(Color.textMuted)
                } else if let message = ts.error, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(Color.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func card(_ vp: VPrinter) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(vp.name).font(.headline).lineLimit(1)
                    Spacer()
                    Pill(text: vp.status?.running == true ? "Running" : (vp.enabled ? "Starting" : "Off"),
                         tint: vp.status?.running == true ? .accentTeal : (vp.enabled ? .statusWarning : .textMuted))
                }
                HStack(spacing: 6) {
                    Pill(text: vp.modeLabel, tint: .statusFinished)
                    if let model = vp.modelName ?? vp.model { Pill(text: model, tint: .textSecondary) }
                    if let pending = vp.status?.pendingFiles, pending > 0 { Pill(text: "\(pending) pending", tint: .statusWarning) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let serial = vp.serial { detail("Serial", serial) }
                    if let target = vp.targetPrinterId { detail("Target", farm.printers.first { $0.id == target }?.name ?? "Printer #\(target)") }
                    if let ip = vp.bindIp, !ip.isEmpty { detail("Bind IP", ip) }
                    if let ip = vp.remoteInterfaceIp, !ip.isEmpty { detail("Remote IP", ip) }
                    if vp.accessCodeSet == false { detail("Access code", "Not set") }
                }
                Divider()
                toggle("Enabled", vp.enabled) { on in
                    if on { patch(vp, "enabled", .bool(true)) } else { pendingDisable = vp }
                }
                toggle("Auto-dispatch", vp.autoDispatch ?? false) { patch(vp, "auto_dispatch", .bool($0)) }
                toggle("Force color match", vp.queueForceColorMatch ?? false) { patch(vp, "queue_force_color_match", .bool($0)) }
                toggle("Save AMS mapping", vp.saveAmsMapping ?? false) { patch(vp, "save_ams_mapping", .bool($0)) }
                toggle("G-code injection", vp.gcodeInjection ?? false) { patch(vp, "gcode_injection", .bool($0)) }
                toggle("Tailscale", vp.tailscaleDisabled != true) { patch(vp, "tailscale_disabled", .bool(!$0)) }
                Button { runDiagnostic(vp) } label: {
                    HStack { if diagnosing == vp.id { ProgressView() }; Label("Run diagnostics", systemImage: "stethoscope") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(diagnosing != nil)
                if canEdit {
                    HStack {
                        Button { editingPrinter = vp } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                        Button(role: .destructive) { pendingDelete = vp } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(Color.textMuted)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(Color.textSecondary).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func toggle(_ title: String, _ value: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: set)).font(.subheadline).disabled(!canEdit)
    }

    // MARK: Actions

    private func load() async {
        do {
            printers = try await session.perform { try await APIClient.shared.vpList(bearer: $0) }
            tailscale = try? await session.perform { try await APIClient.shared.vpTailscale(bearer: $0) }
            error = canEdit ? nil : "Read-only: your account doesn't have settings:update."
        } catch { self.error = AdminError.friendly(error) }
        loaded = true
    }

    private func patch(_ vp: VPrinter, _ key: String, _ value: AdminJSON) {
        pendingDisable = nil
        Task {
            do {
                try await session.perform { try await APIClient.shared.vpUpdate(vp.id, patch: .object([key: value]), bearer: $0) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                error = nil
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await load()
        }
    }

    private func delete(_ vp: VPrinter) {
        pendingDelete = nil
        Task {
            do {
                try await session.perform { try await APIClient.shared.vpDelete(vp.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                error = nil
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await load()
        }
    }

    private func runDiagnostic(_ vp: VPrinter) {
        diagnosing = vp.id
        Task {
            defer { diagnosing = nil }
            do {
                let result = try await session.perform { try await APIClient.shared.vpDiagnostic(vp.id, bearer: $0) }
                diagnostic = (vp, result)
            } catch { self.error = AdminError.friendly(error) }
        }
    }
}

private struct DiagnosticSheet: View {
    let printer: VPrinter
    let result: VPDiagnostic
    @Environment(\.dismiss) private var dismiss

    private static let titles = [
        "enabled": "Enabled", "running": "Service running", "bind_interface": "Network interface", "access_code": "Access code",
        "target_printer": "Target printer", "port_ftps": "FTPS port", "port_mqtt": "MQTT port", "port_bind": "Port binding",
        "certificate": "Certificate",
    ]

    var body: some View {
        List {
            Section {
                Label(result.overall == "ok" ? "All checks passed" : (result.overall == "warnings" ? "Works, with warnings" : "Problems found"),
                      systemImage: result.overall == "ok" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.overall == "ok" ? Color.accentTeal : (result.overall == "warnings" ? Color.statusWarning : Color.statusError))
            }
            Section("Checks") {
                ForEach(result.checks) { check in
                    HStack {
                        Text(Self.titles[check.id] ?? check.id.replacingOccurrences(of: "_", with: " ").capitalized)
                        Spacer()
                        Pill(text: check.status.capitalized, tint: tint(check.status))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .farmBackground()
        .navigationTitle(printer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func tint(_ status: String) -> Color {
        switch status {
        case "pass": .accentTeal
        case "warn": .statusWarning
        case "fail": .statusError
        default: .textMuted
        }
    }
}
