import AVKit
import SafariServices
import SwiftUI

/// Browser for the printer's own storage (SD card / internal), over Bambuddy's FTP bridge.
/// `printers:files` for listing, download and delete. Timelapse videos download to a temp
/// file and play in AVKit; other files can be shared. Upload is intentionally not offered.
struct PrinterFilesSheet: View {
    let printerId: Int
    let printerName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PrinterFolderView(printerId: printerId, path: "/", title: printerName, showStorage: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct PrinterFolderView: View {
    let printerId: Int
    let path: String
    let title: String
    var showStorage = false

    @State private var listing: AdvFileListing?
    @State private var storage: AdvStorage?
    @State private var loading = true
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var pendingDelete: AdvFileEntry?
    @State private var opening: String?
    @State private var player: PlayerItem?
    @State private var shareURL: URL?

    struct PlayerItem: Identifiable { let id = UUID(); let url: URL; let title: String }

    private var sorted: [AdvFileEntry] {
        (listing?.files ?? []).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if showStorage, let used = storage?.usedBytes {
                Section {
                    HStack {
                        Label("Used", systemImage: "internaldrive")
                        Spacer()
                        Text(storage?.freeBytes.map { "\(advFormatBytes(used)) used, \(advFormatBytes($0)) free" } ?? advFormatBytes(used))
                            .font(.subheadline).foregroundStyle(Color.textMuted)
                    }
                }
            }
            if let warning = listing?.warnings?.first {
                Section {
                    Label(warning == "listing_timed_out"
                          ? "The printer was slow to answer. This list may be incomplete."
                          : "Bambuddy couldn't reach the printer's storage.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.statusWarning)
                }
            }
            if let loadError {
                Section { Text(loadError).font(.footnote).foregroundStyle(Color.statusError) }
            }
            Section {
                ForEach(sorted) { file in
                    if file.isDirectory {
                        NavigationLink {
                            PrinterFolderView(printerId: printerId, path: file.path, title: file.name)
                        } label: {
                            Label(file.name, systemImage: "folder.fill").foregroundStyle(Color.primary)
                        }
                    } else {
                        Button { open(file) } label: { fileRow(file) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = file } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button { open(file) } label: { Label(file.isPlayable ? "Play" : "Download", systemImage: "arrow.down.circle") }
                                Button(role: .destructive) { pendingDelete = file } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            } footer: {
                if !loading, loadError == nil, sorted.isEmpty { Text("Nothing here.") }
            }
        }
        .farmBackground()
        .overlay { if loading && listing == nil { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) { await load() }
        .refreshable { await load() }
        .alert("Couldn't do that", isPresented: .constant(actionError != nil), presenting: actionError) { _ in
            Button("OK") { actionError = nil }
        } message: { Text($0) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "file")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete from printer", role: .destructive) { if let file = pendingDelete { delete(file) } }
        } message: {
            Text("This removes the file from the printer's storage. It can't be undone.")
        }
        .fullScreenCover(item: $player) { item in
            VideoPlayerCover(url: item.url, title: item.title)
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { AdvShareSheet(items: [shareURL]).presentationDetents([.medium, .large]) }
        }
    }

    private func fileRow(_ file: AdvFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isVideo ? "film" : "doc").foregroundStyle(file.isVideo ? Color.statusFinished : Color.textMuted).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline).lineLimit(2)
                HStack(spacing: 8) {
                    if let size = file.size { Text(advFormatBytes(size)) }
                    if let mtime = file.mtime { Text(mtime) }
                }
                .font(.caption).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 0)
            if opening == file.path { ProgressView() }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(file.isPlayable ? "Downloads and plays the video" : "Downloads the file")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            listing = try await APIClient.shared.printerFiles(printerId, path: path)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        if showStorage { storage = try? await APIClient.shared.printerStorage(printerId) }
    }

    private func open(_ file: AdvFileEntry) {
        guard opening == nil else { return }
        opening = file.path
        Task {
            defer { opening = nil }
            do {
                let url = try await APIClient.shared.downloadPrinterFile(printerId, path: file.path)
                if file.isPlayable { player = PlayerItem(url: url, title: file.name) } else { shareURL = url }
            } catch {
                actionError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func delete(_ file: AdvFileEntry) {
        Task {
            do {
                try await APIClient.shared.deletePrinterFile(printerId, path: file.path)
                listing = listing.map { AdvFileListing(path: $0.path, files: $0.files.filter { $0.path != file.path }, warnings: $0.warnings) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}


private struct VideoPlayerCover: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player { VideoPlayer(player: player) } else { ProgressView() }
            }
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

struct AdvShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// In-app Safari (SFSafariViewController) so the web app keeps its own login.
struct AdvSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct AdvSafariDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
