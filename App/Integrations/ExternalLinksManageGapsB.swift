import SwiftUI

/// Add, edit, delete and reorder the sidebar links (Bambuddy: Settings > External links). Bambuddy refuses these
/// writes for API keys (external_links:create / :update / :delete have no key scope), so this runs on the sign-in
/// session; each button shows only when that session holds the permission. Not offered: uploading a custom icon
/// image (the Lucide icon name below is what the web sidebar falls back to) and the badge count, which the linked
/// app reports itself.
struct ExternalLinksManageView: View {
    var onChanged: () -> Void = {}

    var body: some View {
        SessionGate(title: "Manage links") { ManageContent(onChanged: onChanged) }
    }
}

/// Lucide icon names Bambuddy stores, limited to ones LayerPal can draw as a symbol (see ExtLink.symbol).
private let linkIconNames = ["link", "globe", "home", "server", "camera", "video", "printer", "box", "shopping-cart", "book", "file-text",
                             "settings", "wrench", "bar-chart", "database", "cloud", "github", "mail", "calendar", "image", "music",
                             "cpu", "wifi", "lock", "key", "terminal", "monitor", "layers", "zap", "bell", "star", "heart", "users", "user"]

private struct ManageContent: View {
    let onChanged: () -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var links: [ExtLink] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Editing?
    @State private var deleting: ExtLink?
    @State private var editMode: EditMode = .inactive

    private struct Editing: Identifiable { let link: ExtLink?; var id: Int { link?.id ?? -1 } }

    private var canCreate: Bool { session.can("external_links:create") }
    private var canUpdate: Bool { session.can("external_links:update") }
    private var canDelete: Bool { session.can("external_links:delete") }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            Section {
                ForEach(links) { link in
                    Button { if canUpdate { editing = Editing(link: link) } } label: {
                        HStack {
                            IconLabel(title: link.name, symbol: link.symbol)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(URL(string: link.url)?.host() ?? link.url).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                                if link.openInNewTab == true { Text("New tab").font(.caption2).foregroundStyle(Color.textMuted) }
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if canDelete { Button(role: .destructive) { deleting = link } label: { Label("Delete", systemImage: "trash") } }
                    }
                    .accessibilityHint(canUpdate ? "Opens the editor" : "")
                }
                .onMove(perform: canUpdate ? move : nil)
            } footer: {
                if !links.isEmpty, canUpdate { Text("Tap Edit, then drag the handles to reorder. The order matches Bambuddy's sidebar.") }
            }
        }
        .farmBackground()
        .environment(\.editMode, $editMode)
        .overlay {
            if loaded, links.isEmpty, error == nil {
                ContentUnavailableView("No external links", systemImage: "link", description: Text(canCreate ? "Tap + to add one." : ""))
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            if canUpdate, links.count > 1 { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            if canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Editing(link: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Add external link")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in LinkEditSheet(link: edit.link) { await load(); onChanged() } }
        .confirmationDialog("Delete this link?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { link in
            Button("Delete \(link.name)", role: .destructive) { delete(link) }
        } message: { _ in Text("It disappears from Bambuddy's sidebar for everyone. The page it points to is not affected.") }
    }

    private func load() async {
        do {
            links = try await APIClient.shared.linkList().sorted { ($0.sortOrder ?? 0, $0.id) < ($1.sortOrder ?? 0, $1.id) }
            error = nil
        } catch { self.error = AdminError.friendly(error) }
        loaded = true
    }

    private func move(from source: IndexSet, to destination: Int) {
        links.move(fromOffsets: source, toOffset: destination)
        let ids = links.map(\.id)
        Task {
            do {
                try await session.perform { try await APIClient.shared.linkReorder(ids, bearer: $0) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onChanged()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await load()
            }
        }
    }

    private func delete(_ link: ExtLink) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.linkDelete(link.id, bearer: $0) }
                links.removeAll { $0.id == link.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onChanged()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct LinkEditSheet: View {
    let link: ExtLink?
    let onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var icon: String
    @State private var newTab: Bool
    @State private var saving = false
    @State private var error: String?

    init(link: ExtLink?, onSaved: @escaping () async -> Void) {
        self.link = link
        self.onSaved = onSaved
        _name = State(initialValue: link?.name ?? "")
        _url = State(initialValue: link?.url ?? "https://")
        _icon = State(initialValue: link?.icon ?? "link")
        _newTab = State(initialValue: link?.openInNewTab ?? false)
    }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var urlOK: Bool { (trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://")) && trimmedURL.count <= 500 }
    private var valid: Bool { !trimmedName.isEmpty && trimmedName.count <= 50 && urlOK }
    private var canSave: Bool { session.can(link == nil ? "external_links:create" : "external_links:update") }

    /// Keep an icon name Bambuddy already stores even when it isn't in the picker.
    private var iconChoices: [String] { linkIconNames.contains(icon) ? linkIconNames : [icon] + linkIconNames }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Address", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !url.isEmpty, !urlOK {
                        Text("The address must start with http:// or https://.").font(.footnote).foregroundStyle(Color.statusError)
                    }
                    Picker("Icon", selection: $icon) {
                        ForEach(iconChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Open in a new tab on the web", isOn: $newTab)
                } footer: {
                    Text("LayerPal always opens links in an in-app Safari sheet. The new-tab switch only changes Bambuddy's web sidebar.")
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            }
            .farmBackground()
            .navigationTitle(link == nil ? "Add link" : "Edit link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if canSave { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid || saving) } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.perform { bearer in
                    if let link {
                        _ = try await APIClient.shared.linkUpdate(link.id, name: trimmedName, url: trimmedURL, icon: icon, openInNewTab: newTab, bearer: bearer)
                    } else {
                        _ = try await APIClient.shared.linkCreate(name: trimmedName, url: trimmedURL, icon: icon, openInNewTab: newTab, bearer: bearer)
                    }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onSaved()
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = AdminError.friendly(error)
            }
        }
    }
}
