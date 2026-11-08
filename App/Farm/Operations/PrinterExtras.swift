import SwiftUI

/// Read-only "Update available" row (firmware:read). Hidden when there's no update
/// or the account can't read firmware info.
struct FirmwareBadge: View {
    let printerId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var info: APIClient.OpsFirmwareInfo?

    var body: some View {
        Group {
            if let info, info.updateAvailable, let latest = info.latestVersion {
                Card(padding: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.statusFinished)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available \(latest)").font(.subheadline.weight(.semibold))
                            if let current = info.currentVersion {
                                Text("Installed \(current)").font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .task(id: printerId) {
            guard farm.can("firmware:read") else { return }
            info = try? await APIClient.shared.firmwareUpdate(printerId: printerId)
        }
    }
}

/// The printer's main power plug: state, power draw, and on/off with a confirmation
/// (smart_plugs:read to see it, smart_plugs:control to switch it).
struct SmartPlugCard: View {
    let printerId: Int
    let printerName: String
    let printing: Bool
    let run: OpsRun
    @EnvironmentObject private var farm: FarmStore

    @State private var plug: APIClient.OpsPlugInfo?
    @State private var status: APIClient.OpsPlugStatus?
    @State private var confirmOff = false

    private var isOn: Bool? {
        guard let state = (status?.state ?? plug?.lastState)?.uppercased() else { return nil }
        return state == "ON" ? true : (state == "OFF" ? false : nil)
    }

    var body: some View {
        Group {
            if let plug, farm.can("smart_plugs:read") { card(plug) }
        }
        .task(id: printerId) { await load() }
    }

    private func card(_ plug: APIClient.OpsPlugInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Power")
            Card(padding: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "powerplug.fill")
                        .foregroundStyle(isOn == true ? Color.accentTeal : Color.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plug.name).font(.subheadline.weight(.semibold))
                        Text(stateText).font(.caption).foregroundStyle(Color.textMuted)
                    }
                    Spacer(minLength: 8)
                    if farm.can("smart_plugs:control"), plug.canSwitch, plug.enabled != false, status?.reachable != false {
                        if isOn == true {
                            Button("Turn off", role: .destructive) { confirmOff = true }
                                .buttonStyle(.bordered).tint(.statusError)
                        } else {
                            Button("Turn on") { switchPlug(plug, "on") }
                                .buttonStyle(.borderedProminent).tint(.accentTeal)
                        }
                    }
                }
                .confirmationDialog(printing ? "Cut power during a print?" : "Turn off \(plug.name)?", isPresented: $confirmOff,
                                    titleVisibility: .visible) {
                    Button(printing ? "Cut power now" : "Turn off", role: .destructive) { switchPlug(plug, "off") }
                } message: {
                    Text(printing
                        ? "\(printerName) is printing. Cutting power will ruin the print and can damage the printer or leave filament in the hotend."
                        : "This switches off power to \(printerName).")
                }
            }
        }
    }

    private var stateText: String {
        if status?.reachable == false { return "Unreachable" }
        var text = isOn.map { $0 ? "On" : "Off" } ?? "Unknown"
        if isOn == true, let watts = status?.energy?.power { text += " · \(Int(watts.rounded())) W" }
        return text
    }

    private func load() async {
        guard farm.can("smart_plugs:read") else { return }
        plug = try? await APIClient.shared.cardPlug(printerId: printerId)
        if let plug { status = try? await APIClient.shared.plugStatus(plug.id) }
    }

    private func switchPlug(_ plug: APIClient.OpsPlugInfo, _ action: String) {
        run {
            try await APIClient.shared.controlPlug(plug.id, action: action)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            status = try? await APIClient.shared.plugStatus(plug.id)
        }
    }
}
