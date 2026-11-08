import SwiftUI
import UIKit

/// Print spool labels: pick a size (built-in or a saved sheet), choose the lines, preview one label,
/// then AirPrint the PDF or share it (PDF, or PNG for label-printer apps). Needs inventory:read.
struct LabelPrintSheet: View {
    let spoolIds: [Int]
    let spoolman: Bool
    @Environment(\.dismiss) private var dismiss

    private enum Choice: Hashable {
        case builtIn(String)
        case saved(Int)
    }

    @State private var saved: [LabelTemplate] = []
    @State private var choice = Choice.builtIn("avery_5160")
    @State private var fields = LabelFieldOption.defaults
    @State private var monochrome = false
    @State private var startingPosition = 1
    @State private var format = "pdf"
    @State private var dpi = 300
    @State private var previewData: Data?
    @State private var previewError: String?
    @State private var loadingPreview = false
    @State private var working = false
    @State private var error: String?
    @State private var shareURL: URL?

    private var capacity: Int? {
        switch choice {
        case let .builtIn(id): BuiltInLabel.all.first { $0.id == id }?.capacity
        case let .saved(id): saved.first { $0.id == id }?.layout.capacity
        }
    }

    private var layout: SheetLayout? {
        if case let .saved(id) = choice { return saved.first { $0.id == id }?.layout }
        return nil
    }

    private var templateName: String {
        if case let .builtIn(id) = choice { return id }
        return "custom"
    }

    private var orderedFields: [String] { LabelFieldOption.all.map(\.id).filter(fields.contains) }

    /// The server limits PNG export of sheets: pages x dpi must stay at or under 15000.
    private var pngProblem: String? {
        guard format == "png", let capacity else { return nil }
        let pages = Int((Double(startingPosition - 1 + spoolIds.count) / Double(capacity)).rounded(.up))
        guard pages * dpi > 15_000 else { return nil }
        return "This needs \(pages) pages, but PNG export at \(dpi) dpi allows at most \(15_000 / dpi). Switch to PDF, pick a lower dpi, or print fewer spools at a time."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Label", selection: $choice) {
                        Section("Built in") { ForEach(BuiltInLabel.all) { Text($0.title).tag(Choice.builtIn($0.id)) } }
                        if !saved.isEmpty {
                            Section("Saved sheets") { ForEach(saved) { Text($0.name).tag(Choice.saved($0.id)) } }
                        }
                    }
                    if let capacity, capacity > 1 {
                        Stepper("Start at label \(startingPosition) of \(capacity)", value: $startingPosition, in: 1 ... capacity)
                    }
                } header: { Text("\(spoolIds.count) spool\(spoolIds.count == 1 ? "" : "s")") } footer: {
                    Text("Starting part-way through a sheet lets you reuse one with labels already peeled off.")
                }
                Section("Preview") { preview }
                Section("Lines on the label") {
                    ForEach(LabelFieldOption.all) { option in
                        Toggle(option.title, isOn: Binding(get: { fields.contains(option.id) }, set: { on in
                            if on { fields.insert(option.id) } else { fields.remove(option.id) }
                        }))
                    }
                    Toggle("Black and white printer", isOn: $monochrome)
                }
                Section {
                    Picker("Format", selection: $format) {
                        Text("PDF").tag("pdf")
                        Text("PNG image").tag("png")
                    }
                    .pickerStyle(.segmented)
                    if format == "png" {
                        Picker("Resolution", selection: $dpi) {
                            ForEach([203, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                        }
                    }
                } footer: {
                    Text(format == "pdf" ? "PDF can be printed straight to an AirPrint printer or shared."
                         : "PNG is for label-printer apps. Several pages are sent as a ZIP. AirPrint needs PDF.")
                }
                Section {
                    if format == "pdf" {
                        Button { Task { await generate(print: true) } } label: { Label("Print", systemImage: "printer") }
                    }
                    Button { Task { await generate(print: false) } } label: { Label("Share \(format == "pdf" ? "PDF" : "image")", systemImage: "square.and.arrow.up") }
                }
                .disabled(working || fields.isEmpty || pngProblem != nil)
                if let pngProblem { Text(pngProblem).font(.footnote).foregroundStyle(Color.statusWarning) }
                if working { HStack { ProgressView(); Text("Making labels") }.font(.footnote) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Print labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { saved = (try? await APIClient.shared.labelTemplates()) ?? [] }
            .task(id: previewKey) { await loadPreview() }
            .onChange(of: choice) { _, _ in startingPosition = 1 }
            .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { if $0 == nil { shareURL = nil } })) { item in
                AdvShareSheet(items: [item.url])
            }
        }
        .presentationDetents([.large])
    }

    private struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

    private var previewKey: String { "\(choice)-\(orderedFields.joined(separator: ","))-\(monochrome)-\(saved.count)" }

    @ViewBuilder private var preview: some View {
        VStack(spacing: 8) {
            if let previewData, let image = UIImage(data: previewData) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Preview of the first label")
            } else if loadingPreview {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text(previewError ?? "No preview yet.").font(.footnote).foregroundStyle(previewError == nil ? Color.textMuted : Color.statusError)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPreview() async {
        guard let first = spoolIds.first, !fields.isEmpty else { previewData = nil; return }
        if case .saved = choice, layout == nil { return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        loadingPreview = true
        defer { loadingPreview = false }
        do {
            previewData = try await APIClient.shared.previewLabel(
                LabelPreviewRequest(spoolId: first, template: templateName, layout: layout, monochrome: monochrome, fields: orderedFields),
                spoolman: spoolman)
            previewError = nil
        } catch {
            if Task.isCancelled { return }
            previewData = nil
            previewError = FriendlyError.message(error)
        }
    }

    private func generate(print: Bool) async {
        working = true
        defer { working = false }
        do {
            let request = LabelRequest(spoolIds: spoolIds, template: templateName, layout: layout, monochrome: monochrome,
                                       fields: orderedFields, startingPosition: capacity == nil ? 1 : startingPosition,
                                       format: format, dpi: dpi)
            let url = try await APIClient.shared.renderLabels(request, spoolman: spoolman)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            error = nil
            if print { AirPrint.present(url, jobName: "Spool labels") } else { shareURL = url }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = FriendlyError.message(error)
        }
    }
}

/// Hands a PDF to the system print dialog (any AirPrint printer).
enum AirPrint {
    @MainActor static func present(_ url: URL, jobName: String) {
        guard UIPrintInteractionController.isPrintingAvailable else { return }
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true, completionHandler: nil)
    }
}
