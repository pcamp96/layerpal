import PhotosUI
import SwiftUI
import UIKit

/// Support tools (Bambuddy Settings > Support): debug logging,
/// server logs, the redacted support bundle, and the guided bug report. Reading the debug flag
/// needs settings:read; everything that changes or exports needs settings:update.
struct SupportView: View {
    var body: some View {
        AdminGate(title: "Support", permission: "settings:read") { SupportContent() }
    }
}

private struct SupportContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var debugOn = false
    @State private var since: Date?
    @State private var loaded = false
    @State private var togglingDebug = false
    @State private var error: String?
    @State private var notice: String?
    @State private var bundleBusy = false
    @State private var share: OpsShareItem?

    private var canChange: Bool { session.can("settings:update") }

    var body: some View {
        List {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            if let notice { Section { OpsBanner(kind: .success, text: notice) } }
            debugSection
            Section {
                NavigationLink { SupportLogsView() } label: { IconLabel(title: "Server logs", symbol: "doc.text.magnifyingglass", tint: .gray) }
                    .disabled(!canChange)
                OpsActionButton(title: "Download support bundle", systemImage: "archivebox", busy: bundleBusy, disabled: !canChange || !debugOn) {
                    downloadBundle()
                }
            } header: {
                Text("Logs")
            } footer: {
                Text(debugOn
                    ? "The support bundle is a ZIP with system info and recent logs, with passwords, tokens and access codes redacted. Share it when asking for help."
                    : "Turn on debug logging, reproduce the problem, then download the support bundle. Bambuddy won't build one without it.")
            }
            Section {
                NavigationLink { BugReportView(onDebugChanged: { Task { await load() } }) } label: {
                    IconLabel(title: "Report a bug", symbol: "ladybug.fill", tint: .orange)
                }
                .disabled(!canChange)
            } footer: {
                Text("Records logs while you reproduce the problem, then sends a report to Bambuddy's developers.")
            }
            if !canChange {
                Section { OpsBanner(kind: .warning, text: "Your account needs settings:update for logs, bundles and bug reports.") }
            }
        }
        .farmBackground()
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $share) { OpsShareSheet(url: $0.url) }
    }

    private var debugSection: some View {
        Section {
            HStack {
                Toggle("Debug logging", isOn: Binding(get: { debugOn }, set: { set($0) }))
                    .disabled(!canChange || togglingDebug || !loaded)
                if togglingDebug { ProgressView() }
            }
            if debugOn, let since {
                OpsValueRow(label: "On since", value: since.opsShort)
            }
        } header: {
            Text("Debug logging")
        } footer: {
            Text("Records much more detail on the server and can grow its log quickly. Turn it off when you're done. It stays on across restarts.")
        }
    }

    private func load() async {
        do {
            let s = try await session.perform { try await APIClient.shared.debugLogging(bearer: $0) }
            debugOn = s.enabled
            since = s.since
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func set(_ on: Bool) {
        Task {
            togglingDebug = true
            error = nil
            defer { togglingDebug = false }
            do {
                try await session.perform { try await APIClient.shared.setDebugLogging(on, bearer: $0) }
                OpsHaptics.tap()
                await load()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }

    private func downloadBundle() {
        Task {
            bundleBusy = true
            error = nil
            defer { bundleBusy = false }
            do {
                let url = try await session.perform { try await APIClient.shared.downloadSupportBundle(bearer: $0) }
                share = OpsShareItem(url: url)
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }
}

// MARK: - Logs

private struct SupportLogsView: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var page: OpsLogPage?
    @State private var level = "ALL"
    @State private var search = ""
    @State private var limit = 200
    @State private var loading = false
    @State private var error: String?
    @State private var share: OpsShareItem?
    @State private var confirmClear = false
    @State private var notice: String?

    private let levels = ["ALL", "DEBUG", "INFO", "WARNING", "ERROR"]

    var body: some View {
        List {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            if let notice { Section { OpsBanner(kind: .success, text: notice) } }
            Section {
                Picker("Level", selection: $level) { ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) } }
                TextField("Search messages", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { Task { await load() } }
                Picker("Entries", selection: $limit) { ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0)").tag($0) } }
                OpsActionButton(title: page == nil ? "Load logs" : "Reload", systemImage: "arrow.clockwise", busy: loading) { Task { await load() } }
            }
            if let page {
                Section {
                    if page.entries.isEmpty { Text("No matching entries.").font(.subheadline).foregroundStyle(Color.textMuted) }
                    ForEach(page.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.level).font(.caption2.weight(.bold)).foregroundStyle(color(entry.level))
                                Text(entry.timestamp).font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
                            }
                            Text(entry.message).font(.caption.monospaced()).lineLimit(8)
                            Text(entry.logger).font(.caption2).foregroundStyle(Color.textMuted).lineLimit(1)
                        }
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Newest first")
                } footer: {
                    Text("Showing \(page.entries.count) of \(page.totalInFile) lines in the log file.")
                }
                Section {
                    Button { exportLog(page) } label: { Label("Share these entries", systemImage: "square.and.arrow.up") }
                        .disabled(page.entries.isEmpty)
                    Button("Clear the server log…", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Raw log text can include IP addresses and names. The support bundle redacts secrets; this export doesn't.")
                }
            }
        }
        .farmBackground()
        .navigationTitle("Server logs")
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
        .onChange(of: level) { _, _ in Task { await load() } }
        .sheet(item: $share) { OpsShareSheet(url: $0.url) }
        .sheet(isPresented: $confirmClear) {
            TypedConfirmSheet(title: "Clear server log",
                              consequence: "This empties Bambuddy's log file on the server. The entries can't be recovered, and any problem you were about to report loses its evidence.",
                              word: "CLEAR", actionTitle: "Clear log") { Task { await clear() } }
        }
    }

    private func color(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR", "CRITICAL": .statusError
        case "WARNING": .statusWarning
        case "DEBUG": .textMuted
        default: .accentTeal
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let lvl = level == "ALL" ? nil : level
            let q = search
            let n = limit
            page = try await session.perform { try await APIClient.shared.supportLogs(limit: n, level: lvl, search: q, bearer: $0) }
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func exportLog(_ page: OpsLogPage) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        if let url = opsTempTextFile(page.asText, name: "bambuddy-log-\(stamp).txt") { share = OpsShareItem(url: url) }
    }

    private func clear() async {
        do {
            try await session.perform { try await APIClient.shared.clearSupportLogs(bearer: $0) }
            OpsHaptics.warning()
            notice = "Server log cleared."
            await load()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}

// MARK: - Bug report

private struct BugReportView: View {
    var onDebugChanged: () -> Void
    @ObservedObject private var session = AdminSession.shared

    private enum Step { case intro, recording, compose, sent(OpsBugReportResult) }

    @State private var step: Step = .intro
    @State private var wasDebug = false
    @State private var logs = ""
    @State private var description = ""
    @State private var email = ""
    @State private var includeSupport = true
    @State private var includeLogs = true
    @State private var busy = false
    @State private var error: String?
    @State private var confirmSend = false
    @State private var confirmDiscard = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var screenshot: BugScreenshot?
    @State private var loadingShot = false

    var body: some View {
        Form {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            switch step {
            case .intro: intro
            case .recording: recording
            case .compose: compose
            case let .sent(result): sent(result)
            }
        }
        .farmBackground()
        .navigationTitle("Report a bug")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Send this bug report?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send report") { Task { await submit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bambuddy forwards it to its developers as a public GitHub issue. Check the text\(screenshot == nil ? "" : " and screenshot") for anything private. Limited to 5 reports per hour.")
        }
        .confirmationDialog("Discard this report?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep editing", role: .cancel) {}
        }
        .onDisappear {
            // Leaving mid-recording would leave debug logging on without anyone watching it.
            if case .recording = step { Task { await stopRecording(silent: true) } }
        }
    }

    @ViewBuilder private var intro: some View {
        Section {
            Label("1. Start recording", systemImage: "record.circle")
            Label("2. Reproduce the problem", systemImage: "hand.tap")
            Label("3. Stop and describe what happened", systemImage: "square.and.pencil")
        } header: {
            Text("How it works")
        } footer: {
            Text("Starting turns on debug logging and asks every printer for fresh data, so the report carries useful detail. Debug logging goes back to how it was when you stop.")
        }
        Section {
            OpsActionButton(title: "Start recording", systemImage: "record.circle", busy: busy) { Task { await start() } }
        }
    }

    @ViewBuilder private var recording: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill").foregroundStyle(Color.statusError)
                Text("Recording. Go reproduce the problem, then come back here.").font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text("Debug logging is on until you stop.")
        }
        Section {
            OpsActionButton(title: "Stop recording", systemImage: "stop.circle.fill", busy: busy) { Task { await stopRecording(silent: false) } }
        }
    }

    @ViewBuilder private var compose: some View {
        Section {
            TextEditor(text: $description).frame(minHeight: 140)
        } header: {
            Text("What happened?")
        } footer: {
            Text("Say what you did, what you expected and what you saw instead.")
        }
        Section {
            TextField("Email (optional)", text: $email)
                .keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Include system info", isOn: $includeSupport)
            Toggle("Include recorded logs", isOn: $includeLogs).disabled(!includeSupport || logs.isEmpty)
        } footer: {
            Text(logs.isEmpty ? "No log lines were captured." : "\(logs.split(separator: "\n").count) recent log lines captured, with known secrets redacted by the server. Your email goes to the developers so they can reply.")
        }
        Section {
            if let screenshot {
                Image(uiImage: screenshot.preview)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Attached screenshot")
                Button("Remove screenshot", role: .destructive) {
                    self.screenshot = nil
                    pickerItem = nil
                    OpsHaptics.tap()
                }
            }
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                HStack {
                    Label(screenshot == nil ? "Attach a screenshot" : "Choose a different screenshot", systemImage: "photo.badge.plus")
                    Spacer()
                    if loadingShot { ProgressView() }
                }
            }
            .disabled(loadingShot)
        } header: {
            Text("Screenshot (optional)")
        } footer: {
            Text("Shrunk to \(Int(BugScreenshot.maxDimension)) px and sent as a JPEG. It's posted publicly with the issue, so check it for anything private.")
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadScreenshot(item) }
        }
        Section {
            OpsActionButton(title: "Send report…", systemImage: "paperplane.fill", busy: busy,
                            disabled: description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10) { confirmSend = true }
            Button("Discard", role: .destructive) { confirmDiscard = true }
        }
    }

    @ViewBuilder private func sent(_ r: OpsBugReportResult) -> some View {
        Section {
            OpsBanner(kind: r.success ? .success : .error, text: r.message.isEmpty ? (r.success ? "Report sent." : "The report wasn't sent.") : r.message)
            if let url = r.issueURL {
                Link(destination: url) { Label(r.issueNumber.map { "Open issue #\($0)" } ?? "Open issue", systemImage: "safari") }
            }
        }
        Section {
            if !r.success { Button("Back to the report") { step = .compose } }
            Button("Start another report") { reset() }
        }
    }

    // MARK: Logic

    private func start() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            wasDebug = try await session.perform { try await APIClient.shared.startBugLogging(bearer: $0) }
            step = .recording
            OpsHaptics.success()
            onDebugChanged()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func stopRecording(silent: Bool) async {
        if !silent { busy = true; error = nil }
        defer { if !silent { busy = false } }
        do {
            let was = wasDebug
            logs = try await session.perform { try await APIClient.shared.stopBugLogging(wasDebug: was, bearer: $0) }
            onDebugChanged()
            if !silent { step = .compose; OpsHaptics.tap() }
        } catch {
            if !silent { self.error = AdminError.friendly(error); OpsHaptics.error() }
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let mail = email.trimmingCharacters(in: .whitespaces)
            let support = includeSupport
            let attached = includeSupport && includeLogs ? logs : nil
            let shot = screenshot?.base64
            let result = try await session.perform {
                try await APIClient.shared.submitBugReport(description: text, email: mail, includeSupportInfo: support, debugLogs: attached,
                                                           screenshotBase64: shot, bearer: $0)
            }
            step = .sent(result)
            result.success ? OpsHaptics.success() : OpsHaptics.error()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }

    private func discard() { reset() }

    private func reset() {
        step = .intro
        description = ""
        email = ""
        logs = ""
        error = nil
        screenshot = nil
        pickerItem = nil
    }

    private func loadScreenshot(_ item: PhotosPickerItem) async {
        loadingShot = true
        error = nil
        defer { loadingShot = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw AdminError.message("That photo couldn't be read.") }
            guard let shot = await Task.detached(priority: .userInitiated, operation: { BugScreenshot(data: data) }).value else {
                throw AdminError.message("That image couldn't be prepared. Try a different one.")
            }
            screenshot = shot
            OpsHaptics.tap()
        } catch {
            self.error = AdminError.friendly(error)
            OpsHaptics.error()
        }
    }
}

/// A picked image downscaled and JPEG-encoded so the bug report's JSON body stays small. Tries
/// smaller sizes and lower quality until the JPEG fits `maxBytes`, and gives up after that.
struct BugScreenshot {
    /// Longest side of the first attempt, in pixels. Smaller images are never enlarged.
    static let maxDimension: CGFloat = 1600
    static let maxBytes = 3_000_000
    private static let attempts: [(side: CGFloat, quality: CGFloat)] = [
        (maxDimension, 0.75), (maxDimension, 0.55), (1200, 0.55), (900, 0.5), (640, 0.4),
    ]

    let preview: UIImage
    let base64: String

    init?(data: Data) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        for attempt in Self.attempts {
            let factor = min(1, attempt.side / longest)
            let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let jpeg = resized.jpegData(compressionQuality: attempt.quality), jpeg.count <= Self.maxBytes {
                preview = resized
                base64 = jpeg.base64EncodedString()
                return
            }
        }
        return nil
    }
}
