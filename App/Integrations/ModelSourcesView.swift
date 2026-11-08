import SwiftUI
import UIKit

/// Model sources (Bambuddy: Model Sources). MakerWorld (paste a link; `makerworld:view`/`:import`) and
/// Manyfold (browse a self-hosted library; `manyfold:view`, import needs `manyfold:import`). Each source
/// shows only if the account has its view permission. Connecting Manyfold (address, client ID and secret) is an
/// admin sign-in job: the toolbar's Connection button opens `ManyfoldSetupSheet` for accounts holding settings:update.
struct ModelSourcesView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var source: Source = .manyfold
    @State private var tree: [LibFolderNode] = []
    @State private var showSetup = false
    @State private var reloadToken = 0

    enum Source: String, CaseIterable, Identifiable {
        case manyfold = "Manyfold", makerworld = "MakerWorld"
        var id: String { rawValue }
    }

    private var sources: [Source] {
        var list: [Source] = []
        if farm.can("manyfold:view") { list.append(.manyfold) }
        if farm.can("makerworld:view") { list.append(.makerworld) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            if sources.isEmpty {
                ContentUnavailableView("No model sources", systemImage: "lock.fill",
                                       description: Text("This account has neither manyfold:view nor makerworld:view."))
            } else {
                if sources.count > 1 {
                    Picker("Source", selection: $source) { ForEach(sources) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).padding([.horizontal, .top])
                }
                switch effective {
                case .manyfold: ManyfoldBrowser(onSetup: farm.can("settings:update") ? { showSetup = true } : nil).id(reloadToken)
                case .makerworld: MakerWorldView(tree: tree, canImport: farm.can("makerworld:import"))
                }
            }
        }
        .background(Color.bgPrimary)
        .navigationTitle("Model sources")
        .toolbar {
            if farm.can("settings:update") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Manyfold connection")
                }
            }
        }
        .sheet(isPresented: $showSetup) { ManyfoldSetupSheet { reloadToken += 1 } }
        .task { tree = (try? await APIClient.shared.libFolderTree()) ?? [] }
    }

    private var effective: Source { sources.contains(source) ? source : (sources.first ?? .manyfold) }
}

// MARK: - Manyfold

private struct ManyfoldBrowser: View {
    var onSetup: (() -> Void)?
    @EnvironmentObject private var farm: FarmStore
    @State private var status: MfyStatus?
    @State private var page: MfyModelPage?
    @State private var pageNumber = 1
    @State private var query = ""
    @State private var submitted = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let status, !status.configured {
                ContentUnavailableView {
                    Label("Manyfold isn't connected", systemImage: "link.badge.plus")
                } description: {
                    Text(onSetup == nil ? "An admin connects it in Bambuddy's Settings, then it shows up here."
                                        : "Add your Manyfold address and OAuth client to browse and import its models.")
                } actions: {
                    if let onSetup { Button("Connect Manyfold", action: onSetup).buttonStyle(.borderedProminent).tint(.accentTeal) }
                }
            } else {
                list
            }
        }
        .task { await boot() }
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.textMuted)
                    TextField("Search Manyfold", text: $query).submitLabel(.search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { submitted = query; pageNumber = 1; Task { await load() } }
                    if !query.isEmpty {
                        Button { query = ""; submitted = ""; pageNumber = 1; Task { await load() } } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(Color.textMuted).accessibilityLabel("Clear search")
                    }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            Section {
                ForEach(page?.models ?? []) { model in
                    NavigationLink { ManyfoldModelView(modelId: model.id, title: model.name, baseURL: status?.url) } label: {
                        Text(model.name).lineLimit(2)
                    }
                }
                if let page, page.hasNext || page.hasPrevious {
                    HStack {
                        Button { pageNumber -= 1; Task { await load() } } label: { Label("Previous", systemImage: "chevron.left") }
                            .disabled(!page.hasPrevious)
                        Spacer()
                        Text("Page \(page.page)").font(.footnote).foregroundStyle(Color.textMuted)
                        Spacer()
                        Button { pageNumber += 1; Task { await load() } } label: { Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                            .disabled(!page.hasNext)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                if let page { Text("\(page.total) models") }
            }
        }
        .farmBackground()
        .overlay {
            if loading, page == nil { ProgressView() }
            else if let page, page.models.isEmpty, error == nil {
                ContentUnavailableView(submitted.isEmpty ? "No models" : "No matches", systemImage: "cube")
            }
        }
        .refreshable { await load() }
    }

    private func boot() async {
        guard status == nil else { return }
        do {
            status = try await APIClient.shared.mfyStatus()
            if status?.configured == true { await load() }
        } catch { self.error = AdminError.friendly(error) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            page = try await APIClient.shared.mfyModels(query: submitted, page: pageNumber)
            error = nil
        } catch { self.error = AdminError.friendly(error) }
    }
}

private struct ManyfoldModelView: View {
    let modelId: String
    let title: String
    let baseURL: String?

    @EnvironmentObject private var farm: FarmStore
    @State private var model: MfyModel?
    @State private var preview: UIImage?
    @State private var error: String?
    @State private var importing: String?
    @State private var imported: [String: MfyImportResult] = [:]

    private var canImport: Bool { farm.can("manyfold:import") }

    var body: some View {
        List {
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if let model {
                if let preview {
                    Section {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                            .listRowInsets(EdgeInsets()).accessibilityLabel("Preview of \(model.name)")
                    }
                }
                Section {
                    if let caption = model.caption, !caption.isEmpty { Text(caption).font(.subheadline) }
                    if let description = model.description, !description.isEmpty { Text(description).font(.footnote).foregroundStyle(Color.textSecondary) }
                    if let license = model.license, !license.isEmpty { LabeledContent("License", value: license).font(.footnote) }
                    if let tags = model.tags, !tags.isEmpty {
                        Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(Color.textMuted)
                    }
                    if let url = model.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                        Link(destination: url) { Label("Open in Manyfold", systemImage: "safari") }
                    }
                }
                Section {
                    ForEach(model.files) { file in fileRow(file, model: model) }
                } header: {
                    Text("Files")
                } footer: {
                    Text("Only 3MF, STL and STEP files can be imported. Imports land in the library's Manyfold folder.")
                }
            } else if error == nil {
                Section { ProgressView() }
            }
        }
        .farmBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func fileRow(_ file: MfyFile, model: MfyModel) -> some View {
        let done = imported[file.id]
        let existing = file.libraryFile
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline).lineLimit(2)
                if let name = done?.filename ?? existing?.filename {
                    Pill(text: "In library: \(name)", tint: .accentTeal, systemImage: "checkmark")
                } else if !file.importable {
                    Text("Can't be imported").font(.caption).foregroundStyle(Color.textMuted)
                }
            }
            Spacer()
            if canImport, file.importable, done == nil, existing == nil {
                if importing == file.id { ProgressView() } else {
                    Button("Import") { startImport(file, model: model) }.buttonStyle(.bordered).disabled(importing != nil)
                        .accessibilityLabel("Import \(file.name)")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            let loaded = try await APIClient.shared.mfyModel(modelId)
            model = loaded
            if loaded.hasPreview == true, let data = try? await APIClient.shared.mfyPreview(modelId) { preview = UIImage(data: data) }
        } catch { self.error = AdminError.friendly(error) }
    }

    private func startImport(_ file: MfyFile, model: MfyModel) {
        importing = file.id
        error = nil
        Task {
            defer { importing = nil }
            do {
                imported[file.id] = try await APIClient.shared.mfyImport(modelId: model.id, fileId: file.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
