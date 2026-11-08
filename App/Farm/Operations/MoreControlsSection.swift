import SwiftUI

/// Rarely used controls (fans, airduct mode, AI detection / print options),
/// collapsed behind a disclosure so the printer screen stays scannable.
struct MoreControlsSection: View {
    let printerId: Int
    let model: String
    let status: PrinterStatus
    let run: OpsRun

    @State private var expanded = false
    @State private var fanEdit: FanItem?
    @State private var pendingAirduct: String?
    @State private var pendingOff: OptionItem?

    // Which models have which fans and controls, by display name. The server sends no capability
    // flags for these, so they come from the hardware.
    /// Models with a chamber fan (`big_fan2`).
    private static let chamberFanModels: Set<String> = ["X1C", "X1", "X1E", "X2D", "P1S", "P2S", "H2D", "H2D Pro", "H2C", "H2S", "H3C"]
    /// On these the chamber fan is an exhaust fan, present only when the status says so.
    private static let exhaustModels: Set<String> = ["P2S", "X2D"]
    /// `big_fan1` is the left auxiliary fan on these.
    private static let leftAuxFirstModels: Set<String> = ["X2D"]
    /// Models with an airduct mode switch.
    private static let airductModels: Set<String> = ["P2S", "X2D", "H2D", "H2D Pro", "H2C", "H2S"]

    struct FanItem: Identifiable {
        let key: String // part | aux | aux2 | chamber
        let label: String
        let symbol: String
        let value: Int
        var id: String { key }
    }

    struct OptionItem: Identifiable {
        let module: String
        let label: String
        let enabled: Bool
        let sensitivity: String?
        /// Module that carries the sensitivity (pile-up shares the spaghetti detector's).
        let sensitivityModule: String?
        var id: String { module }
    }

    private var fans: [FanItem] {
        var items: [FanItem] = []
        let leftFirst = Self.leftAuxFirstModels.contains(model)
        if let v = status.coolingFanSpeed { items.append(FanItem(key: "part", label: "Part cooling fan", symbol: "fanblades", value: v)) }
        let aux = status.bigFan1Speed.map { FanItem(key: "aux", label: leftFirst ? "Left auxiliary fan" : "Auxiliary fan", symbol: "wind", value: $0) }
        let aux2 = status.leftAuxFanSpeed.map { FanItem(key: "aux2", label: leftFirst ? "Right auxiliary fan" : "Left auxiliary fan", symbol: "wind", value: $0) }
        items += (leftFirst ? [aux, aux2] : [aux2, aux]).compactMap { $0 }
        let exhaust = Self.exhaustModels.contains(model)
        let hasChamber = Self.chamberFanModels.contains(model) && (!exhaust || status.exhaustFanPresent == true)
        if hasChamber, let v = status.bigFan2Speed {
            items.append(FanItem(key: "chamber", label: exhaust ? "Exhaust fan" : "Chamber fan", symbol: "fan", value: v))
        }
        return items
    }

    private var options: [OptionItem] {
        guard let o = status.printOptions else { return [] }
        let halt = o.haltPrintSensitivity
        let all: [OptionItem?] = [
            o.spaghettiDetector.map { OptionItem(module: "spaghetti_detector", label: "Spaghetti detection", enabled: $0, sensitivity: halt, sensitivityModule: "spaghetti_detector") },
            o.pileupDetector.map { OptionItem(module: "pileup_detector", label: "Pile-up detection", enabled: $0, sensitivity: halt, sensitivityModule: nil) },
            o.nozzleClumpingDetector.map { OptionItem(module: "clump_detector", label: "Nozzle clumping detection", enabled: $0, sensitivity: o.nozzleClumpingSensitivity, sensitivityModule: "clump_detector") },
            o.airprintDetector.map { OptionItem(module: "airprint_detector", label: "Air printing detection", enabled: $0, sensitivity: o.airprintSensitivity, sensitivityModule: "airprint_detector") },
            o.firstLayerInspector.map { OptionItem(module: "first_layer_inspector", label: "First layer inspection", enabled: $0, sensitivity: nil, sensitivityModule: nil) },
            o.printingMonitor.map { OptionItem(module: "printing_monitor", label: "Print quality monitoring", enabled: $0, sensitivity: nil, sensitivityModule: nil) },
            o.buildplateMarkerDetector.map { OptionItem(module: "buildplate_marker_detector", label: "Build plate marker detection", enabled: $0, sensitivity: nil, sensitivityModule: nil) },
            o.allowSkipParts.map { OptionItem(module: "allow_skip_parts", label: "Allow skipping parts", enabled: $0, sensitivity: nil, sensitivityModule: nil) },
            o.autoRecoveryStepLoss.map { OptionItem(module: "auto_recovery_step_loss", label: "Auto-recovery from step loss", enabled: $0, sensitivity: nil, sensitivityModule: nil) },
        ]
        return all.compactMap { $0 }
    }

    private var showsAirduct: Bool { Self.airductModels.contains(model) && status.airductMode != nil }

    var body: some View {
        let fans = fans, options = options
        if !fans.isEmpty || !options.isEmpty || showsAirduct {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "More controls")
                Card(padding: 0) {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 16) {
                            if !fans.isEmpty { fanBlock(fans) }
                            if showsAirduct { airductBlock }
                            if !options.isEmpty { optionsBlock(options) }
                        }
                        .padding(.top, 10)
                    } label: {
                        Label("Fans, airduct and AI detection", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.medium))
                    }
                    .tint(Color.textMuted)
                    .padding(14)
                }
            }
            .sheet(item: $fanEdit) { fan in
                FanSheet(fan: fan) { speed in
                    run { try await APIClient.shared.setFanSpeed(printerId, fan: fan.key, speed: speed) }
                }
                .presentationDetents([.height(300)])
            }
        }
    }

    // MARK: Fans

    private func fanBlock(_ fans: [FanItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fans").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
            ForEach(fans) { fan in
                Button { fanEdit = fan } label: {
                    HStack {
                        Label(fan.label, systemImage: fan.symbol)
                        Spacer()
                        Text("\(fan.value)%").font(.body.monospacedDigit()).foregroundStyle(fan.value > 0 ? Color.accentTeal : Color.textMuted)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Set fan speed")
            }
            if let hb = status.heatbreakFanSpeed {
                HStack {
                    Label("Hotend fan", systemImage: "thermometer.medium")
                    Spacer()
                    Text("\(hb)%").font(.body.monospacedDigit()).foregroundStyle(Color.textMuted)
                }
                .padding(.vertical, 4)
                .foregroundStyle(Color.textSecondary)
            }
        }
    }

    // MARK: Airduct

    private var airductBlock: some View {
        let heating = status.airductMode == 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Airduct mode").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
            Picker("Airduct mode", selection: Binding(
                get: { heating ? "heating" : "cooling" },
                set: { new in
                    guard new != (heating ? "heating" : "cooling") else { return }
                    if status.isPrinting { pendingAirduct = new } else { setAirduct(new) }
                }
            )) {
                Label("Cooling", systemImage: "snowflake").tag("cooling")
                Label("Heating", systemImage: "flame").tag("heating")
            }
            .pickerStyle(.segmented)
            .confirmationDialog("Switch airduct to \(pendingAirduct ?? "")?", isPresented: Binding(
                get: { pendingAirduct != nil }, set: { if !$0 { pendingAirduct = nil } }
            ), titleVisibility: .visible) {
                Button("Switch to \(pendingAirduct ?? "")") { if let mode = pendingAirduct { setAirduct(mode) } }
            } message: {
                Text("A print is running. Changing the airduct mode changes how the chamber is cooled or heated.")
            }
        }
    }

    private func setAirduct(_ mode: String) {
        run { try await APIClient.shared.setAirductMode(printerId, mode: mode) }
    }

    // MARK: Print options

    private func optionsBlock(_ options: [OptionItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI detection and print options").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
            ForEach(options) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(option.label, isOn: Binding(
                        get: { option.enabled },
                        set: { on in
                            if on { send(option, enabled: true) } else { pendingOff = option }
                        }
                    ))
                    .tint(.accentTeal)
                    if option.enabled, let sens = option.sensitivity, let module = option.sensitivityModule {
                        Menu {
                            ForEach(["low", "medium", "high"], id: \.self) { level in
                                Button { sendSensitivity(module, level) } label: {
                                    if sens == level { Label(level.capitalized, systemImage: "checkmark") } else { Text(level.capitalized) }
                                }
                            }
                        } label: {
                            Text("Sensitivity: \(sens.capitalized)").font(.caption).foregroundStyle(Color.textMuted)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .confirmationDialog("Turn off \(pendingOff?.label.lowercased() ?? "this option")?", isPresented: Binding(
            get: { pendingOff != nil }, set: { if !$0 { pendingOff = nil } }
        ), titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { if let o = pendingOff { send(o, enabled: false) } }
        } message: {
            Text("The printer will stop watching for this while the option is off.")
        }
    }

    private func send(_ option: OptionItem, enabled: Bool) {
        // Plain toggles carry no sensitivity of their own; "medium" is the server default.
        // Pile-up reuses the spaghetti detector's level so toggling it doesn't reset that.
        let sensitivity = option.sensitivity ?? "medium"
        run { try await APIClient.shared.setPrintOption(printerId, module: option.module, enabled: enabled, sensitivity: sensitivity) }
    }

    private func sendSensitivity(_ module: String, _ level: String) {
        run { try await APIClient.shared.setPrintOption(printerId, module: module, enabled: true, sensitivity: level) }
    }
}

private struct FanSheet: View {
    let fan: MoreControlsSection.FanItem
    let onSet: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            Text(fan.label).font(.headline)
            Text("\(Int(value))%").font(.system(size: 44, weight: .bold).monospacedDigit())
            Slider(value: $value, in: 0 ... 100, step: 5) { Text("Fan speed") }.tint(.accentTeal)
            HStack {
                Button("Off") { onSet(0); dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Set") { onSet(Int(value)); dismiss() }.buttonStyle(.borderedProminent).tint(.accentTeal)
            }
        }
        .padding()
        .onAppear { value = Double(fan.value) }
    }
}
