import SwiftUI
import UIKit

/// Create or edit a virtual printer (Bambuddy: Settings > Virtual printer > Add / the card's fields).
/// POST /virtual-printers and PUT /virtual-printers/{id}, both settings:update (admin session).
/// Access codes are never read back from the server (only `access_code_set`), so editing sends one only when typed.
struct VirtualPrinterForm: View {
    enum Mode { case create, edit(VPrinter) }

    let mode: Mode
    var onSaved: () async -> Void
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var vpMode = "archive"
    @State private var model = ""
    @State private var targetId: Int?
    @State private var accessCode = ""
    @State private var autoDispatch = true
    @State private var bindIP = ""
    @State private var remoteIP = ""
    @State private var enableNow = false
    @State private var models: [VPModelOption] = []
    @State private var interfaces: [VPInterface] = []
    @State private var saving = false
    @State private var error: String?
    @State private var populated = false

    private static let modes: [(value: String, title: String, detail: String)] = [
        ("archive", "Archive", "Archive files immediately"),
        ("review", "Review", "Review before archiving"),
        ("queue", "Queue", "Archive and add to queue"),
        ("proxy", "Proxy", "Relay to a real printer"),
    ]

    private var editing: VPrinter? { if case let .edit(vp) = mode { vp } else { nil } }

    /// Non-proxy printers with a target borrow that printer's access code (server enforces this).
    private var inheritsCode: Bool { vpMode != "proxy" && targetId != nil }

    private var codeValid: Bool { accessCode.isEmpty || accessCode.count == 8 }

    private var enableProblem: String? {
        guard enableNow || (editing?.enabled ?? false) else { return nil }
        if bindIP.isEmpty { return "Pick a bind IP before enabling." }
        if vpMode == "proxy" { return targetId == nil ? "Proxy mode needs a target printer." : nil }
        let hasCode = !accessCode.isEmpty || editing?.accessCodeSet == true || targetId != nil
        return hasCode ? nil : "Set an 8-character access code or pick a target printer."
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && codeValid && (vpMode != "proxy" || targetId != nil) && !saving
            && (editing != nil || enableProblem == nil)
    }

    var body: some View {
        Form {
            Section("Printer") {
                TextField("Name", text: $name)
                Picker("Model", selection: $model) {
                    if editing == nil { Text("Automatic").tag("") }
                    if !model.isEmpty, !models.contains(where: { $0.code == model }) { Text(model).tag(model) }
                    ForEach(models) { Text($0.name == $0.code ? $0.code : "\($0.name) (\($0.code))").tag($0.code) }
                }
            }
            Section {
                Picker("Mode", selection: $vpMode) {
                    ForEach(Self.modes, id: \.value) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.segmented)
                Text(Self.modes.first { $0.value == vpMode }?.detail ?? "").font(.footnote).foregroundStyle(Color.textSecondary)
                Picker("Target printer", selection: $targetId) {
                    if editing?.targetPrinterId == nil { Text(vpMode == "proxy" ? "Choose a printer" : "None").tag(Int?.none) }
                    ForEach(farm.printers) { Text($0.name).tag(Int?.some($0.id)) }
                }
                if vpMode == "queue" { Toggle("Auto-dispatch", isOn: $autoDispatch) }
            } header: {
                Text("Behavior")
            } footer: {
                Text(vpMode == "proxy"
                    ? "Proxy relays everything to the target printer, so prints start as if the slicer were connected to it."
                    : "A target printer is optional. With one, this virtual printer uses that printer's access code, so the two always match.")
            }
            Section {
                if inheritsCode {
                    LabeledContent("Access code", value: "From target printer")
                } else {
                    SecureField(editing?.accessCodeSet == true ? "New access code (blank keeps current)" : "Access code (8 characters)", text: $accessCode)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: accessCode) { _, value in if value.count > 8 { accessCode = String(value.prefix(8)) } }
                }
            } header: {
                Text("Slicer login")
            } footer: {
                Text(inheritsCode ? "Change the target printer's access code to change this one."
                    : (codeValid ? "Enter this code in the slicer when you add the virtual printer by IP address."
                        : "Access codes are exactly 8 characters (\(accessCode.count)/8)."))
            }
            Section {
                Picker("Bind IP", selection: $bindIP) {
                    Text("Not set").tag("")
                    if !bindIP.isEmpty, !interfaces.contains(where: { $0.ip == bindIP }) { Text(bindIP).tag(bindIP) }
                    ForEach(interfaces) { Text("\($0.ip) (\($0.label))").tag($0.ip) }
                }
                Picker("Remote interface", selection: $remoteIP) {
                    Text("Auto-detect").tag("")
                    if !remoteIP.isEmpty, !interfaces.contains(where: { $0.ip == remoteIP }) { Text(remoteIP).tag(remoteIP) }
                    ForEach(interfaces) { Text("\($0.ip) (\($0.label))").tag($0.ip) }
                }
                if editing == nil { Toggle("Enable now", isOn: $enableNow) }
            } header: {
                Text("Network")
            } footer: {
                Text("The bind IP is the address of this Bambuddy server's network card that slicers connect to. Each running virtual printer needs its own. Override the remote interface only if the auto-detected address is wrong (several network cards, Docker, VPN).")
            }
            if let problem = enableProblem { Section { OpsBanner(kind: .warning, text: problem) } }
            if let error { Section { OpsBanner(kind: .error, text: error) } }
        }
        .farmBackground()
        .navigationTitle(editing == nil ? "New virtual printer" : "Edit virtual printer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button(editing == nil ? "Create" : "Save") { Task { await save() } }.disabled(!canSave) }
            }
        }
        .task { await load() }
    }

    // MARK: Logic

    private func load() async {
        if !populated {
            populated = true
            if let vp = editing {
                name = vp.name
                vpMode = vp.mode ?? "archive"
                model = vp.model ?? ""
                targetId = vp.targetPrinterId
                autoDispatch = vp.autoDispatch ?? true
                bindIP = vp.bindIp ?? ""
                remoteIP = vp.remoteInterfaceIp ?? ""
            }
        }
        models = (try? await session.perform { try await APIClient.shared.vpModels(bearer: $0) }) ?? []
        interfaces = (try? await session.perform { try await APIClient.shared.vpNetworkInterfaces(bearer: $0) }) ?? []
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let vp = editing {
                var patch: [String: AdminJSON] = [:]
                if trimmed != vp.name { patch["name"] = .string(trimmed) }
                if vpMode != (vp.mode ?? "archive") { patch["mode"] = .string(vpMode) }
                if !model.isEmpty, model != (vp.model ?? "") { patch["model"] = .string(model) }
                if let targetId, targetId != vp.targetPrinterId { patch["target_printer_id"] = .int(targetId) }
                if !inheritsCode, !accessCode.isEmpty { patch["access_code"] = .string(accessCode) }
                if autoDispatch != (vp.autoDispatch ?? true) { patch["auto_dispatch"] = .bool(autoDispatch) }
                if bindIP != (vp.bindIp ?? "") { patch["bind_ip"] = .string(bindIP) }
                if remoteIP != (vp.remoteInterfaceIp ?? "") { patch["remote_interface_ip"] = .string(remoteIP) }
                guard !patch.isEmpty else { dismiss(); return }
                try await session.perform { try await APIClient.shared.vpUpdate(vp.id, patch: .object(patch), bearer: $0) }
            } else {
                var body: [String: AdminJSON] = [
                    "name": .string(trimmed), "mode": .string(vpMode), "enabled": .bool(enableNow), "auto_dispatch": .bool(autoDispatch),
                ]
                if !model.isEmpty { body["model"] = .string(model) }
                if let targetId { body["target_printer_id"] = .int(targetId) }
                if !inheritsCode, !accessCode.isEmpty { body["access_code"] = .string(accessCode) }
                if !bindIP.isEmpty { body["bind_ip"] = .string(bindIP) }
                if !remoteIP.isEmpty { body["remote_interface_ip"] = .string(remoteIP) }
                try await session.perform { try await APIClient.shared.vpCreate(body, bearer: $0) }
            }
            accessCode = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// The shared CA the slicer must trust to accept virtual printers' TLS. GET /virtual-printers/ca-certificate (settings:read).
struct VirtualPrinterCACard: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var cert: VPCACertificate?
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var copied = false
    @State private var showHelp = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Slicer certificate", systemImage: "checkmark.shield").font(.subheadline.weight(.semibold))
                Text("Virtual printers use a certificate signed by Bambuddy's own authority. Import it into your slicer's trust store once so the slicer accepts the connection.")
                    .font(.caption).foregroundStyle(Color.textSecondary)
                if let cert {
                    Text("SHA-256 \(cert.fingerprint)").font(.caption2.monospaced()).foregroundStyle(Color.textMuted).textSelection(.enabled)
                    if let expiry = cert.notValidAfter { Text("Valid until \(expiry.prefix(10))").font(.caption2).foregroundStyle(Color.textMuted) }
                    HStack {
                        Button { share(cert) } label: { Label("Share .crt", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(.accentTeal)
                        Button { copy(cert) } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    DisclosureGroup("How to import it", isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Share the .crt file to the computer your slicer (Bambu Studio or OrcaSlicer) runs on, for example with AirDrop or Files.")
                            Text("2. Add it to that computer's trusted root certificates, or to the slicer's own certificate list if it has one.")
                            Text("3. Restart the slicer, then add the virtual printer by its IP address and access code (or let it appear through discovery on the same network).")
                            Text("One import covers every virtual printer on this Bambuddy.").foregroundStyle(Color.textMuted)
                        }
                        .font(.caption).foregroundStyle(Color.textSecondary).padding(.top, 4)
                    }
                    .font(.footnote)
                } else if let error {
                    OpsBanner(kind: .error, text: error)
                } else {
                    ProgressView()
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showShare) { if let shareURL { OpsShareSheet(url: shareURL) } }
    }

    private func load() async {
        do {
            cert = try await session.perform { try await APIClient.shared.vpCACertificate(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func share(_ cert: VPCACertificate) {
        guard let url = opsTempTextFile(cert.pem, name: "bambuddy-virtual-printer-ca.crt") else {
            error = "Couldn't write the certificate file."
            return
        }
        shareURL = url
        showShare = true
        OpsHaptics.tap()
    }

    private func copy(_ cert: VPCACertificate) {
        UIPasteboard.general.string = cert.pem
        copied = true
        OpsHaptics.success()
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
