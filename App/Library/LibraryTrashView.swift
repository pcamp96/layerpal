import SwiftUI

/// The library trash: restore, delete forever, empty. Needs library:delete_own or delete_all
/// ("own" sees only the user's files). Pushed or presented inside a NavigationStack by the caller.
struct LibraryTrashView: View {
    @State private var page: LibTrashPage?
    @State private var error: String?
    @State private var notice: String?
    @State private var purging: LibTrashFile?
    @State private var confirmEmpty = false

    var body: some View {
        List {
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let page, !page.items.isEmpty {
                Section {
                    ForEach(page.items) { file in
                        HStack(spacing: 12) {
                            RemoteImage(path: file.thumbnailPath == nil ? nil : "library/files/\(file.id)/thumbnail")
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.filename).font(.subheadline).lineLimit(2)
                                HStack(spacing: 6) {
                                    if let size = libFormatBytes(file.fileSize) { Text(size) }
                                    if let folder = file.folderName { Text(folder) }
                                    if let user = file.createdByUsername { Text(user) }
                                }
                                .font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                                if let purge = file.autoPurgeAt {
                                    Text("Auto-deletes \(purge.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2).foregroundStyle(Color.statusWarning)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions(edge: .leading) {
                            Button { restore(file) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.accentTeal)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { purging = file } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { restore(file) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            Button(role: .destructive) { purging = file } label: { Label("Delete forever", systemImage: "trash") }
                        }
                    }
                } footer: {
                    if let days = page.retentionDays { Text("Trashed files are removed for good after \(days) days. Swipe right to restore.") }
                }
            }
        }
        .farmBackground()
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if let page, page.items.isEmpty, error == nil { ContentUnavailableView("Trash is empty", systemImage: "trash") } }
        .toolbar {
            if let page, !page.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete \(purging?.filename ?? "file") forever?", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
                            titleVisibility: .visible, presenting: purging) { file in
            Button("Delete forever", role: .destructive) { purge(file) }
        } message: { _ in Text("The file is removed from the server and cannot be restored.") }
        .confirmationDialog("Empty the trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete everything forever", role: .destructive) { emptyTrash() }
        } message: { Text("Every trashed file you can see is removed from the server for good.") }
    }

    private func load() async {
        do {
            page = try await APIClient.shared.libTrash()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func restore(_ file: LibTrashFile) {
        Task {
            do {
                try await APIClient.shared.libRestore(file.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = "Restored \(file.filename)."
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func purge(_ file: LibTrashFile) {
        Task {
            do {
                try await APIClient.shared.libPurge(file.id)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                notice = nil
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func emptyTrash() {
        Task {
            do {
                let n = try await APIClient.shared.libEmptyTrash()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                notice = "Deleted \(n) file\(n == 1 ? "" : "s") for good."
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }
}
