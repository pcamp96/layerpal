import SwiftUI

/// Obico and OctoEverywhere AI failure detection (Bambuddy: Settings > Obico / OctoEverywhere). Status and
/// settings need `settings:read`; changing settings and testing need `settings:update`. Settings are the
/// settings keys read and written through PATCH /settings/. API keys are write-only here.
struct AIDetectionView: View {
    var body: some View {
        SessionGate(title: "AI failure detection", permission: "settings:read") { AIDetectionContent() }
    }
}

private struct AIDetectionContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var obico: AdminJSON?
    @State private var octo: AdminJSON?
    @State private var obicoError: String?
    @State private var octoError: String?
    @State private var message: String?
    @State private var testing: String?
    @State private var apiKey = ""
    @State private var savingKey = false

    private var canEdit: Bool { session.can("settings:update") }
    private let actions: [(String, String)] = [("notify", "Notify only"), ("pause", "Pause the print"), ("pause_and_off", "Pause and switch off")]

    var body: some View {
        Form {
            if let message { Section { Text(message).font(.footnote).foregroundStyle(Color.textSecondary) } }
            obicoSection
            octoSection
        }
        .farmBackground()
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Obico

    @ViewBuilder private var obicoSection: some View {
        Section {
            if let obico {
                Toggle("Enabled", isOn: Binding(get: { obico["enabled"]?.bool ?? false }, set: { patch("obico_enabled", .bool($0)) }))
                    .disabled(!canEdit)
                LabeledContent("Server", value: obico["ml_url"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Not set")
                NavigationLink("Server address and token") { ObicoConnectionView() }
                Picker("Sensitivity", selection: Binding(get: { obico["sensitivity"]?.string ?? "medium" }, set: { patch("obico_sensitivity", .string($0)) })) {
                    Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
                }.disabled(!canEdit)
                Picker("When it spots a failure", selection: Binding(get: { obico["action"]?.string ?? "notify" }, set: { patch("obico_action", .string($0)) })) {
                    ForEach(actions, id: \.0) { Text($0.1).tag($0.0) }
                }.disabled(!canEdit)
                LabeledContent("Checks every", value: "\(obico["poll_interval"]?.int ?? 10) s")
                LabeledContent("Detector", value: obico["is_running"]?.bool == true ? "Running" : "Idle")
                if let err = obico["last_error"]?.string, !err.isEmpty {
                    Text("Last error: \(err)").font(.footnote).foregroundStyle(Color.statusError)
                }
                if canEdit {
                    Button { Task { await testObico() } } label: {
                        HStack { Text("Test connection"); if testing == "obico" { Spacer(); ProgressView() } }
                    }
                    .disabled(testing != nil || (obico["ml_url"]?.string ?? "").isEmpty)
                }
            } else if let obicoError { InlineError(message: obicoError) }
            else { HStack { Text("Loading"); Spacer(); ProgressView() } }
        } header: { Text("Obico") } footer: {
            Text("Self-hosted Obico ML server. Edit its address and token under Server address and token.")
        }
    }

    // MARK: OctoEverywhere

    @ViewBuilder private var octoSection: some View {
        Section {
            if let octo {
                Toggle("Enabled", isOn: Binding(get: { octo["enabled"]?.bool ?? false }, set: { patch("octoeverywhere_enabled", .bool($0)) }))
                    .disabled(!canEdit)
                Picker("Confidence needed", selection: Binding(get: { octo["confidence"]?.string ?? "medium" }, set: { patch("octoeverywhere_confidence", .string($0)) })) {
                    ForEach(["lowest", "low", "medium", "high", "highest"], id: \.self) { Text($0.capitalized).tag($0) }
                }.disabled(!canEdit)
                Picker("When it spots a failure", selection: Binding(get: { octo["action"]?.string ?? "notify" }, set: { patch("octoeverywhere_action", .string($0)) })) {
                    ForEach(actions, id: \.0) { Text($0.1).tag($0.0) }
                }.disabled(!canEdit)
                LabeledContent("Checks every", value: "\(octo["poll_interval"]?.int ?? 20) s")
                LabeledContent("Detector", value: octo["is_running"]?.bool == true ? "Running" : "Idle")
                LabeledContent("API key", value: octo["api_key_configured"]?.bool == true ? "Saved" : "Not set")
                if let n = octo["notifications"], n["configured"]?.bool == false {
                    Text("No notification provider is subscribed to AI failure alerts, so you won't hear about detections.")
                        .font(.footnote).foregroundStyle(Color.statusWarning)
                }
                if let err = octo["last_error"]?.string, !err.isEmpty {
                    Text("Last error: \(err)").font(.footnote).foregroundStyle(Color.statusError)
                }
                if canEdit {
                    SecureField("New API key", text: $apiKey).textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { await saveKey() } } label: {
                        HStack { Text("Save API key"); if savingKey { Spacer(); ProgressView() } }
                    }
                    .disabled(savingKey || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { Task { await testOcto() } } label: {
                        HStack { Text("Test saved key"); if testing == "octo" { Spacer(); ProgressView() } }
                    }
                    .disabled(testing != nil || octo["api_key_configured"]?.bool != true)
                }
            } else if let octoError { InlineError(message: octoError) }
            else { HStack { Text("Loading"); Spacer(); ProgressView() } }
        } header: { Text("OctoEverywhere") } footer: {
            Text("OctoEverywhere Gadget. Get an API key from your OctoEverywhere account. The key is never shown again after saving.")
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            obico = try await session.perform { try await APIClient.shared.obicoStatus(bearer: $0) }
            obicoError = nil
        } catch { obicoError = AdminError.friendly(error) }
        do {
            octo = try await session.perform { try await APIClient.shared.octoStatus(bearer: $0) }
            octoError = nil
        } catch { octoError = AdminError.friendly(error) }
    }

    private func patch(_ key: String, _ value: AdminJSON) {
        Task {
            do {
                _ = try await session.perform { try await APIClient.shared.patchSettings([key: value], bearer: $0) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                message = nil
                await load()
            } catch {
                message = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await load()
            }
        }
    }

    private func saveKey() async {
        savingKey = true
        defer { savingKey = false }
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await session.perform { try await APIClient.shared.patchSettings(["octoeverywhere_api_key": .string(key)], bearer: $0) }
            apiKey = ""
            message = "OctoEverywhere key saved."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            message = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func testObico() async {
        testing = "obico"
        defer { testing = nil }
        guard let url = obico?["ml_url"]?.string else { return }
        do {
            let r = try await session.perform { try await APIClient.shared.obicoTest(url: url, bearer: $0) }
            let ok = r["ok"]?.bool == true
            var text = ok ? "Obico answered." : "Obico test failed: \(r["error"]?.string ?? "no answer")."
            if ok, r["auth_ok"]?.bool == false { text = "Obico answered, but it rejected the saved token." }
            message = text
            UINotificationFeedbackGenerator().notificationOccurred(ok && r["auth_ok"]?.bool != false ? .success : .error)
        } catch {
            message = AdminError.friendly(error)
        }
    }

    private func testOcto() async {
        testing = "octo"
        defer { testing = nil }
        do {
            let r = try await session.perform { try await APIClient.shared.octoTest(bearer: $0) }
            let ok = r["ok"]?.bool == true
            message = ok ? "OctoEverywhere accepted the key." : "OctoEverywhere test failed: \(r["error"]?.string ?? "no answer")."
            UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        } catch {
            message = AdminError.friendly(error)
        }
    }
}
