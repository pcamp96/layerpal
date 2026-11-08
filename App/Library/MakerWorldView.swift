import SwiftUI
import UIKit

/// Loads a MakerWorld CDN image through Bambuddy's proxy (GET /makerworld/thumbnail, no auth needed).
private struct MWImage: View {
    let cdnURL: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.bgRaised
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(Color.textMuted)
            }
        }
        .clipped()
        .task(id: cdnURL) {
            image = nil
            guard let cdnURL, let url = APIClient.shared.makerWorldImageURL(cdnURL),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }
}

/// Paste a MakerWorld link, look up the model and its plates, import one into the library.
/// Resolve needs makerworld:view; import needs makerworld:import and a Bambu Cloud sign-in on the server.
struct MakerWorldView: View {
    let tree: [LibFolderNode]
    var canImport = true

    @EnvironmentObject private var farm: FarmStore
    @State private var urlText = ""
    @State private var resolved: MWResolved?
    @State private var status: MWStatus?
    @State private var recent: [MWRecentImport] = []
    @State private var folderId: Int?
    @State private var pickingFolder = false
    @State private var resolving = false
    @State private var importingId: Int?
    @State private var error: String?
    @State private var notice: String?

    private var design: [String: LibJSON] { resolved?.design ?? [:] }
    private var plates: [MWPlate] { (resolved?.instances ?? []).compactMap(MWPlate.init) }
    private var importable: Bool { canImport && farm.can("makerworld:import") }
    private var folderName: String { folderId.flatMap { tree.find($0)?.name } ?? "MakerWorld (default folder)" }

    var body: some View {
        List {
            Section {
                TextField("https://makerworld.com/models/...", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { resolve() }
                HStack {
                    Button { if let s = UIPasteboard.general.string { urlText = s; resolve() } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    Spacer()
                    Button { resolve() } label: {
                        if resolving { ProgressView() } else { Text("Look up") }
                    }
                    .buttonStyle(.borderedProminent).tint(.accentTeal)
                    .disabled(resolving || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .buttonStyle(.borderless)
            } footer: { Text("Paste any MakerWorld model link. The Bambuddy server downloads the file, not this phone.") }

            if let status, importable, !status.canDownload {
                Section {
                    Label(status.signInExpired == true
                          ? "Bambuddy's Bambu Cloud sign-in expired. Sign in again in Bambuddy's settings before importing."
                          : "Bambuddy has no Bambu Cloud sign-in, so imports will fail. Sign in to Bambu Cloud in Bambuddy's settings first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Color.statusWarning)
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            if let notice { Section { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) } }

            if resolved != nil { modelSection }
            if !recent.isEmpty { recentSection }
        }
        .farmBackground()
        .navigationTitle("MakerWorld")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAux() }
        .sheet(isPresented: $pickingFolder) {
            LibraryFolderPicker(tree: tree, title: "Import into", allowRoot: true, rootLabel: "MakerWorld (default folder)") { id in
                folderId = id
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var modelSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                MWImage(cdnURL: design.str("coverUrl"))
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(design.str("title") ?? "Model \(resolved?.modelId ?? 0)").font(.headline)
                    if let creator = design["designCreator"]?.object?.str("name") {
                        Text("by \(creator)").font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                    HStack(spacing: 6) {
                        if let license = design.str("license") { Pill(text: license) }
                        if let n = design.num("downloadCount") { Pill(text: "\(Int(n)) downloads", systemImage: "arrow.down.circle") }
                    }
                    if !(resolved?.alreadyImportedLibraryIds ?? []).isEmpty {
                        Pill(text: "Already in library", tint: .statusFinished, systemImage: "checkmark")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        if importable {
            Section {
                Button { pickingFolder = true } label: {
                    HStack {
                        Label("Import into", systemImage: "folder")
                        Spacer()
                        Text(folderName).foregroundStyle(Color.textMuted)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        Section(plates.count == 1 ? "Plate" : "Plates (\(plates.count))") {
            ForEach(plates) { plate in
                HStack(spacing: 12) {
                    MWImage(cdnURL: plate.cover)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plate.title ?? "Plate").font(.subheadline).lineLimit(2)
                        HStack(spacing: 6) {
                            if let p = plate.primaryPrinter { Text("Sliced for \(p)") }
                            if let m = plate.materialCount { Text("\(m) filament\(m == 1 ? "" : "s")") }
                            if plate.needsAms { Text("AMS") }
                        }
                        .font(.caption).foregroundStyle(Color.textMuted)
                    }
                    Spacer(minLength: 0)
                    if importable {
                        if importingId == plate.instanceId {
                            ProgressView()
                        } else {
                            Button("Import") { importPlate(plate) }
                                .buttonStyle(.bordered)
                                .disabled(importingId != nil)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var recentSection: some View {
        Section("Recent imports") {
            ForEach(recent) { item in
                HStack(spacing: 12) {
                    RemoteImage(path: "library/files/\(item.libraryFileId)/thumbnail")
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(item.filename).font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                    if let source = item.sourceUrl, let url = URL(string: source) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .accessibilityLabel("Open \(item.filename) on MakerWorld")
                    }
                }
                .accessibilityElement(children: .combine)
                .onTapGesture {
                    if let source = item.sourceUrl { urlText = source; resolve() }
                }
            }
        }
    }

    // MARK: Actions

    private func loadAux() async {
        status = try? await APIClient.shared.makerWorldStatus()
        recent = (try? await APIClient.shared.makerWorldRecent()) ?? []
    }

    private func resolve() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !resolving else { return }
        resolving = true
        error = nil
        notice = nil
        Task {
            defer { resolving = false }
            do {
                resolved = try await APIClient.shared.makerWorldResolve(url: text)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                resolved = nil
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func importPlate(_ plate: MWPlate) {
        guard let modelId = resolved?.modelId else { return }
        importingId = plate.instanceId
        error = nil
        Task {
            defer { importingId = nil }
            do {
                let result = try await APIClient.shared.makerWorldImport(modelId: modelId, instanceId: plate.instanceId,
                                                                         profileId: plate.profileId, folderId: folderId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = result.wasExisting ? "\(result.filename) was already in your library." : "Imported \(result.filename)."
                recent = (try? await APIClient.shared.makerWorldRecent()) ?? recent
                if let again = try? await APIClient.shared.makerWorldResolve(url: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    resolved = again
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
