import SwiftUI

/// Maintenance types: list, add (maintenance:create), edit (maintenance:update), delete and
/// restore defaults (maintenance:delete). System types are hidden when deleted, custom ones removed.
struct MaintenanceTypesView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var types: [MaintType] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var editor: TypeEditorTarget?
    @State private var deleting: MaintType?

    private var access: MaintAccess { MaintAccess(farm: farm) }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) }
            Section {
                ForEach(types) { type in
                    Button { if access.canUpdate { editor = .edit(type) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: MaintIcon.symbol(type.icon)).frame(width: 24).foregroundStyle(Color.accentTeal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.name).font(.subheadline)
                                Text(type.intervalText).font(.caption).foregroundStyle(Color.textMuted)
                            }
                            Spacer()
                            if type.isSystem { Pill(text: "Built-in") }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if access.canDelete {
                            Button(role: .destructive) { deleting = type } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            } footer: { if access.canUpdate { Text("Tap a type to edit it. Interval changes apply to printers that use the default.") } }
        }
        .farmBackground()
        .navigationTitle("Maintenance types")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loaded, types.isEmpty, error == nil { ContentUnavailableView("No types", systemImage: "wrench") } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if access.canCreate { Button { editor = .create } label: { Label("New type", systemImage: "plus") } }
                    if access.canDelete { Button { restoreDefaults() } label: { Label("Restore built-in types", systemImage: "arrow.counterclockwise") } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Type actions")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editor) { target in MaintTypeEditor(target: target) { await load() } }
        .confirmationDialog("Delete \(deleting?.name ?? "type")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { type in
            Button("Delete", role: .destructive) { delete(type) }
        } message: { type in
            Text(type.isSystem
                 ? "Built-in types are hidden, and \"Restore built-in types\" brings them back."
                 : "Printers that use this type lose it, along with its history. This cannot be undone.")
        }
    }

    private func load() async {
        do {
            types = try await APIClient.shared.maintTypes()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func delete(_ type: MaintType) {
        Task {
            do {
                try await APIClient.shared.maintDeleteType(type.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }

    private func restoreDefaults() {
        Task {
            do {
                let n = try await APIClient.shared.maintRestoreDefaults()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                notice = n == 0 ? "No built-in types were hidden." : "Restored \(n) built-in type\(n == 1 ? "" : "s")."
                await load()
            } catch { self.error = FriendlyError.message(error) }
        }
    }
}

enum TypeEditorTarget: Identifiable {
    case create
    case edit(MaintType)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(t): "edit-\(t.id)"
        }
    }
}

/// Create or edit a type: name, description, default interval (hours or days), icon, how-to link.
struct MaintTypeEditor: View {
    let target: TypeEditorTarget
    var onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var details = ""
    @State private var intervalText = "100"
    @State private var inDays = false
    @State private var icon = "Wrench"
    @State private var wiki = ""
    @State private var error: String?
    @State private var busy = false

    private var existing: MaintType? { if case let .edit(t) = target { t } else { nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $details, axis: .vertical).lineLimit(1 ... 4)
                }
                Section("Default interval") {
                    Picker("Count in", selection: $inDays) {
                        Text("Print hours").tag(false)
                        Text("Days").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Every")
                        TextField("Interval", text: $intervalText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text(inDays ? "days" : "hours").foregroundStyle(Color.textMuted)
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                        ForEach(MaintIcon.all, id: \.name) { entry in
                            Button { icon = entry.name } label: {
                                Image(systemName: entry.symbol)
                                    .frame(width: 40, height: 40)
                                    .background(icon == entry.name ? Color.accentTeal.opacity(0.25) : Color.bgRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(icon == entry.name ? Color.accentTeal : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.name)
                            .accessibilityAddTraits(icon == entry.name ? .isSelected : [])
                        }
                    }
                }
                Section("How-to link (optional)") {
                    TextField("https://", text: $wiki).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle(existing == nil ? "New type" : "Edit type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear {
                guard let t = existing else { return }
                name = t.name
                details = t.description ?? ""
                intervalText = t.defaultIntervalHours.rounded() == t.defaultIntervalHours ? String(Int(t.defaultIntervalHours)) : String(t.defaultIntervalHours)
                inDays = t.inDays
                icon = t.icon ?? "Wrench"
                wiki = t.wikiUrl ?? ""
            }
        }
    }

    private func save() {
        guard let interval = Double(intervalText.replacingOccurrences(of: ",", with: ".")), interval >= 1 else {
            error = "The interval must be a number of at least 1."
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanWiki = wiki.trimmingCharacters(in: .whitespaces)
        let cleanDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            defer { busy = false }
            do {
                if let t = existing {
                    var patch = LibPatch()
                    patch["name"] = .string(cleanName)
                    patch["description"] = cleanDetails.isEmpty ? .null : .string(cleanDetails)
                    patch["default_interval_hours"] = .double(interval)
                    patch["interval_type"] = .string(inDays ? "days" : "hours")
                    patch["icon"] = .string(icon)
                    patch["wiki_url"] = cleanWiki.isEmpty ? .null : .string(cleanWiki)
                    try await APIClient.shared.maintUpdateType(t.id, patch)
                } else {
                    try await APIClient.shared.maintCreateType(
                        name: cleanName, description: cleanDetails.isEmpty ? nil : cleanDetails, interval: interval,
                        intervalType: inDays ? "days" : "hours", icon: icon, wikiUrl: cleanWiki.isEmpty ? nil : cleanWiki)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onSaved()
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
