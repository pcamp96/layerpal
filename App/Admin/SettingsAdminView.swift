import SwiftUI

/// Bambuddy settings (GET/PATCH /settings/, settings:read / settings:update).
/// Only keys the server's settings schema accepts (PATCH /settings/) are used.
struct SettingsAdminView: View {
    var body: some View {
        AdminGate(title: "Bambuddy settings", permission: "settings:read") { SettingsAdminForm() }
    }
}

private struct SettingsAdminForm: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var original: [String: AdminJSON] = [:]
    @State private var draft: [String: AdminJSON] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var savedNote: String?

    private var dirtyKeys: [String] {
        draft.keys.filter { !Self.same(draft[$0], original[$0]) }.sorted()
    }

    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        Form {
            if !loaded {
                Section { HStack { ProgressView(); Text("Loading settings").foregroundStyle(Color.textMuted) } }
            } else {
                general
                archiving
                queue
                inventory
                camera
                alerts
                updates
                security
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if let savedNote { Section { Text(savedNote).font(.footnote).foregroundStyle(Color.textSecondary) } }
        }
        .farmBackground()
        .disabled(!canEdit && loaded)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") { Task { await save() } }.disabled(dirtyKeys.isEmpty || !canEdit)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Groups

    private var general: some View {
        Section("General") {
            LabeledTextField(title: "External URL", text: text("external_url"), placeholder: "https://bambuddy.example.com", url: true)
            Picker("Date format", selection: choice("date_format", "system")) {
                Text("System").tag("system")
                Text("US").tag("us")
                Text("EU").tag("eu")
                Text("ISO").tag("iso")
            }
            Picker("Time format", selection: choice("time_format", "system")) {
                Text("System").tag("system")
                Text("12 hour").tag("12h")
                Text("24 hour").tag("24h")
            }
            LabeledTextField(title: "Currency", text: text("currency"), placeholder: "USD", url: false)
            LabeledNumberField(title: "Filament cost per kg", text: number("default_filament_cost"))
            LabeledNumberField(title: "Electricity price per kWh", text: number("energy_cost_per_kwh"))
            Picker("Energy on stats", selection: choice("energy_tracking_mode", "total")) {
                Text("Lifetime plug total").tag("total")
                Text("Sum of prints").tag("print")
            }
        }
    }

    private var archiving: some View {
        Section("Archiving") {
            Toggle("Auto-archive finished prints", isOn: bool("auto_archive"))
            Toggle("Save 3MF preview images", isOn: bool("save_thumbnails"))
            Toggle("Photo when a print finishes", isOn: bool("capture_finish_photo"))
            Toggle("Raise plate for finish photo", isOn: bool("finish_photo_restore_plate"))
        }
    }

    private var queue: some View {
        Section("Queue and scheduler") {
            Toggle("Require plate clear between prints", isOn: bool("require_plate_clear"))
            Toggle("Shortest job first", isOn: bool("queue_shortest_first"))
            Stepper("Concurrent uploads: \(int("queue_max_concurrent_uploads", 4))", value: intBinding("queue_max_concurrent_uploads", 4), in: 1 ... 16)
            Stepper("Stagger group size: \(int("stagger_group_size", 2))", value: intBinding("stagger_group_size", 2), in: 1 ... 50)
            Stepper("Stagger interval: \(int("stagger_interval_minutes", 5)) min", value: intBinding("stagger_interval_minutes", 5), in: 1 ... 60)
            Toggle("Keep bed warm for chamber-heated prints", isOn: bool("queue_keep_bed_warm"))
            Toggle("Preheat before queued prints", isOn: bool("preheat_enabled"))
            Toggle("Dry filament between queued prints", isOn: bool("queue_drying_enabled"))
            if flag("queue_drying_enabled") { Toggle("Wait for drying to finish", isOn: bool("queue_drying_block")) }
            Toggle("Dry idle printers when humid", isOn: bool("ambient_drying_enabled"))
        }
    }

    private var inventory: some View {
        Section("Inventory") {
            LabeledNumberField(title: "Low stock threshold (%)", text: number("low_stock_threshold"))
            Toggle("Warn when filament is short", isOn: Binding(get: { !flag("disable_filament_warnings") }, set: { draft["disable_filament_warnings"] = .bool(!$0) }))
            Toggle("Prefer the emptiest matching spool", isOn: bool("prefer_lowest_filament"))
            Toggle("Add unknown RFID spools automatically", isOn: bool("auto_add_unknown_rfid"))
        }
    }

    private var camera: some View {
        Section {
            Picker("Chamber light with camera", selection: choice("camera_light_mode", "off")) {
                Text("Off").tag("off")
                Text("All printers").tag("all")
                Text("Selected printers").tag("selected")
            }
            VStack(alignment: .leading) {
                Text("Snapshot delay after light: \(String(format: "%.1f", draft["camera_light_delay"]?.double ?? 2)) s").font(.subheadline)
                Slider(value: Binding(get: { draft["camera_light_delay"]?.double ?? 2 },
                                      set: { draft["camera_light_delay"] = .double(($0 * 2).rounded() / 2) }), in: 0 ... 5, step: 0.5)
            }
        } header: {
            Text("Camera")
        } footer: {
            Text("Plate detection is per printer: turn it on under Printers, then the printer.")
        }
    }

    private var alerts: some View {
        Section("Alert thresholds") {
            LabeledNumberField(title: "Bed cooled at (°C)", text: number("bed_cooled_threshold"))
            Stepper("Pause warning: \(int("pause_warning_minutes", 5)) min", value: intBinding("pause_warning_minutes", 5), in: 0 ... 120)
        }
    }

    private var updates: some View {
        Section("Updates") {
            Toggle("Check for Bambuddy updates", isOn: bool("check_updates"))
            Toggle("Check printer firmware", isOn: bool("check_printer_firmware"))
            Toggle("Include beta releases", isOn: bool("include_beta_updates"))
        }
    }

    private var security: some View {
        Section {
            Stepper("Session length: \(int("session_max_hours", 24)) h", value: intBinding("session_max_hours", 24), in: 1 ... 720)
        } header: {
            Text("Sessions")
        } footer: {
            Text("Applies to new sign-ins, including this app's admin session.")
        }
    }

    // MARK: Bindings

    private func flag(_ key: String) -> Bool { draft[key]?.bool ?? false }
    private func int(_ key: String, _ fallback: Int) -> Int { draft[key]?.int ?? fallback }

    private func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { draft[key]?.bool ?? false }, set: { draft[key] = .bool($0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft[key]?.string ?? "" }, set: { draft[key] = .string($0) })
    }

    private func choice(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { draft[key]?.string ?? fallback }, set: { draft[key] = .string($0) })
    }

    private func intBinding(_ key: String, _ fallback: Int) -> Binding<Int> {
        Binding(get: { draft[key]?.int ?? fallback }, set: { draft[key] = .int($0) })
    }

    /// Edited as text so a half-typed "0." doesn't fight the user; a valid number is stored.
    private func number(_ key: String) -> Binding<String> {
        Binding(get: {
            guard let v = draft[key] else { return "" }
            if case let .double(d) = v { return d == d.rounded() ? String(Int(d)) : String(d) }
            return v.string ?? ""
        }, set: {
            if let d = Double($0.replacingOccurrences(of: ",", with: ".")) { draft[key] = .double(d) }
        })
    }

    private static func same(_ a: AdminJSON?, _ b: AdminJSON?) -> Bool {
        if a == b { return true }
        func number(_ v: AdminJSON?) -> Double? {
            switch v {
            case let .int(i)?: Double(i)
            case let .double(d)?: d
            default: nil
            }
        }
        if let x = number(a), let y = number(b) { return x == y }
        return false
    }

    // MARK: Network

    private func load() async {
        do {
            let settings = try await session.perform { try await APIClient.shared.adminSettings(bearer: $0) }
            original = settings
            draft = settings
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func save() async {
        saving = true
        error = nil
        savedNote = nil
        defer { saving = false }
        var patch: [String: AdminJSON] = [:]
        for key in dirtyKeys { patch[key] = draft[key] }
        do {
            let updated = try await session.perform { try await APIClient.shared.patchSettings(patch, bearer: $0) }
            original = updated
            draft = updated
            savedNote = "Saved \(patch.count) setting\(patch.count == 1 ? "" : "s")."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

private struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var url: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Color.textMuted)
            TextField(title, text: $text, prompt: Text(placeholder))
                .keyboardType(url ? .URL : .default).textInputAutocapitalization(url ? .never : .characters).autocorrectionDisabled()
        }
    }
}

private struct LabeledNumberField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
        }
    }
}
