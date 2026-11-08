import SwiftUI

/// Per-printer camera checks (camera:view): one-frame test, staged diagnosis,
/// external camera test, and the server's USB camera list (printers:read).
/// Pushed from the printer edit screen, which already sits behind AdminGate.
struct CameraDiagnosticsView: View {
    let printer: AdminPrinter
    @ObservedObject private var session = AdminSession.shared

    @State private var test: OpsCameraTest?
    @State private var testing = false
    @State private var diagnosis: OpsCameraDiagnosis?
    @State private var diagnosing = false
    @State private var external: OpsCameraTest?
    @State private var testingExternal = false
    @State private var usb: [OpsUSBCamera]?
    @State private var loadingUSB = false
    @State private var error: String?

    private var allowed: Bool { session.can("camera:view") }
    private var hasExternal: Bool {
        printer.externalCameraEnabled == true && !(printer.externalCameraUrl ?? "").isEmpty
    }

    var body: some View {
        List {
            if !allowed {
                Section { OpsBanner(kind: .warning, text: "Your account doesn't have camera:view, so these checks will be refused.") }
            }
            if let error { Section { OpsBanner(kind: .error, text: error) } }

            Section {
                OpsActionButton(title: "Test camera", systemImage: "camera.metering.center.weighted", busy: testing, disabled: !allowed) { runTest() }
                if let test { testResult(test) }
            } header: {
                Text("Quick test")
            } footer: {
                Text("Captures one frame from the printer's built-in camera. Takes up to 15 seconds. The printer's camera allows one viewer, so close any live view first.")
            }

            Section {
                OpsActionButton(title: "Run diagnostic", systemImage: "stethoscope", busy: diagnosing, disabled: !allowed) { runDiagnose() }
                if let diagnosis { diagnosisView(diagnosis) }
            } header: {
                Text("Diagnose")
            } footer: {
                Text("Checks the network path first, then tries to pull a frame, and tells you which step fails.")
            }

            if hasExternal {
                Section {
                    LabeledContent("Type", value: AdminPrinterModels.cameraTypes.first { $0.value == printer.externalCameraType }?.label ?? (printer.externalCameraType ?? "–"))
                    OpsActionButton(title: "Test external camera", systemImage: "video", busy: testingExternal, disabled: !allowed) { runExternal() }
                    if let external { testResult(external) }
                } header: {
                    Text("External camera")
                } footer: {
                    Text("Tests the stream or snapshot address saved on this printer.")
                }
            }

            Section {
                OpsActionButton(title: usb == nil ? "List USB cameras" : "Refresh", systemImage: "cable.connector", busy: loadingUSB,
                                disabled: !session.can("printers:read")) { loadUSB() }
                if let usb {
                    if usb.isEmpty {
                        Text("No USB cameras found on the Bambuddy server.").font(.subheadline).foregroundStyle(Color.textMuted)
                    }
                    ForEach(usb) { cam in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cam.name).font(.subheadline.weight(.semibold))
                            Text(cam.device).font(.caption.monospaced()).foregroundStyle(Color.textSecondary)
                            let detail = ([cam.driver].compactMap { $0 } + cam.formats).joined(separator: " · ")
                            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Color.textMuted) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("USB cameras on the server")
            } footer: {
                Text("Devices Bambuddy can see (Linux hosts only). Use a device path like /dev/video0 as the stream address with the USB camera type.")
            }
        }
        .farmBackground()
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func testResult(_ r: OpsCameraTest) -> some View {
        if r.success {
            OpsBanner(kind: .success, text: [r.message ?? "Camera connection successful", r.resolution.map { "Resolution \($0)" }]
                .compactMap { $0 }.joined(separator: ". "))
        } else {
            OpsBanner(kind: .error, text: r.error ?? r.message ?? "The camera test failed.")
        }
    }

    private func diagnosisView(_ d: OpsCameraDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OpsBanner(kind: d.overallOK ? .success : .error, text: d.summary)
            ForEach(d.stages) { stage in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: stage.status == "ok" ? "checkmark.circle.fill" : (stage.status == "failed" ? "xmark.circle.fill" : "minus.circle"))
                        .foregroundStyle(stage.status == "ok" ? Color.accentTeal : (stage.status == "failed" ? Color.statusError : Color.textMuted))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.label).font(.subheadline)
                        if let hint = stage.codeHint { Text(hint).font(.caption).foregroundStyle(Color.textMuted) }
                    }
                    Spacer()
                    if stage.status != "skipped" { Text("\(stage.durationMs) ms").font(.caption.monospacedDigit()).foregroundStyle(Color.textMuted) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stage.label), \(stage.status == "ok" ? "passed" : stage.status == "failed" ? "failed" : "skipped")")
            }
            Divider()
            HStack(spacing: 16) {
                meta("Protocol", d.protocolName)
                meta("Port", d.port == 0 ? "–" : String(d.port))
                meta("Profile", d.profile)
            }
        }
    }

    private func meta(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(Color.textMuted)
            Text(value.isEmpty ? "–" : value).font(.caption.weight(.medium))
        }
    }

    private func runTest() {
        Task {
            testing = true
            error = nil
            test = nil
            defer { testing = false }
            do {
                test = try await session.perform { try await APIClient.shared.cameraTest(printer.id, bearer: $0) }
                test?.success == true ? OpsHaptics.success() : OpsHaptics.error()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func runDiagnose() {
        Task {
            diagnosing = true
            error = nil
            diagnosis = nil
            defer { diagnosing = false }
            do {
                diagnosis = try await session.perform { try await APIClient.shared.cameraDiagnose(printer.id, bearer: $0) }
                diagnosis?.overallOK == true ? OpsHaptics.success() : OpsHaptics.error()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func runExternal() {
        guard let url = printer.externalCameraUrl else { return }
        let type = printer.externalCameraType ?? "mjpeg"
        Task {
            testingExternal = true
            error = nil
            external = nil
            defer { testingExternal = false }
            do {
                external = try await session.perform { try await APIClient.shared.externalCameraTest(printer.id, url: url, type: type, bearer: $0) }
                external?.success == true ? OpsHaptics.success() : OpsHaptics.error()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func loadUSB() {
        Task {
            loadingUSB = true
            error = nil
            defer { loadingUSB = false }
            do {
                usb = try await session.perform { try await APIClient.shared.usbCameras(bearer: $0) }
            } catch {
                self.error = AdminError.friendly(error)
            }
        }
    }
}
