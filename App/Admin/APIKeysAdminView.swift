import SwiftUI
import UIKit

/// API keys (Bambuddy: Settings > API keys). Needs an admin session.
struct APIKeysAdminView: View {
    var body: some View {
        AdminGate(title: "API keys", permission: "api_keys:read") { APIKeyList() }
    }
}

private struct APIKeyList: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var keys: [AdminAPIKey] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false
    @State private var pendingRevoke: AdminAPIKey?
    @State private var newKey: AdminCreatedKey?
    @State private var printerScopes: [Int: [Int]] = [:]
    @StateObject private var choices = PrinterChoices()

    private func keyRow(_ key: AdminAPIKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(key.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if key.isThisApp { Pill(text: "This app", tint: .accentTeal) }
                if !key.enabled { Pill(text: "Disabled", tint: .statusWarning) }
                if let exp = key.expiresAt, exp < Date() { Pill(text: "Expired", tint: .statusError) }
            }
            Text("\(key.keyPrefix)…").font(.caption.monospaced()).foregroundStyle(Color.textMuted)
            Text(key.scopes.isEmpty ? "No scopes" : key.scopes.joined(separator: " · "))
                .font(.caption).foregroundStyle(Color.textSecondary)
            Label(printerScopeText(for: key), systemImage: printerScopes[key.id] == nil ? "printer.fill" : "lock.fill")
                .font(.caption).foregroundStyle(printerScopes[key.id] == nil ? Color.textMuted : Color.statusWarning)
            HStack(spacing: 10) {
                Text(key.lastUsed.map { "Used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                if let exp = key.expiresAt { Text("Expires \(exp.formatted(date: .abbreviated, time: .omitted))") }
            }
            .font(.caption2).foregroundStyle(Color.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    /// "All printers", or the printers a limited key is restricted to.
    private func printerScopeText(for key: AdminAPIKey) -> String {
        guard let ids = printerScopes[key.id] else { return "All printers" }
        if ids.isEmpty { return "No printers" }
        return "Only " + ids.map { choices.name($0) }.joined(separator: ", ")
    }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(keys) { key in
                Group {
                    if session.can("api_keys:update") {
                        NavigationLink {
                            APIKeyPrintersView(key: key, current: printerScopes[key.id], names: choices) { await load() }
                        } label: { keyRow(key) }
                    } else {
                        keyRow(key)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if session.can("api_keys:delete") {
                        Button(role: .destructive) { pendingRevoke = key } label: { Label("Revoke", systemImage: "trash") }
                    }
                    if session.can("api_keys:update") {
                        Button { setEnabled(key, !key.enabled) } label: {
                            Label(key.enabled ? "Disable" : "Enable", systemImage: key.enabled ? "pause.fill" : "play.fill")
                        }.tint(.statusWarning)
                    }
                }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, keys.isEmpty, error == nil {
                ContentUnavailableView("No API keys", systemImage: "key.fill")
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            if session.can("api_keys:create") {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create API key")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { APIKeyCreateView { created in newKey = created; await load() } }
        }
        .sheet(item: $newKey) { created in NavigationStack { NewKeyView(key: created) } }
        .confirmationDialog("Revoke \(pendingRevoke?.name ?? "key")?",
                            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible) {
            Button("Revoke key", role: .destructive) { if let k = pendingRevoke { revoke(k) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingRevoke?.isThisApp == true
                ? "This key looks like one LayerPal made. If a phone is using it, that phone stops working until you sign in again from LayerPal Settings."
                : "Anything using this key stops working immediately. This can't be undone.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func setEnabled(_ key: AdminAPIKey, _ on: Bool) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.setAPIKeyEnabled(key.id, enabled: on, bearer: $0) }
                await load()
            } catch { self.error = AdminError.friendly(error) }
        }
    }

    private func revoke(_ key: AdminAPIKey) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.revokeAPIKey(key.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await load()
            } catch { self.error = AdminError.friendly(error) }
            pendingRevoke = nil
        }
    }

    private func load() async {
        do {
            keys = try await session.perform { try await APIClient.shared.adminAPIKeys(bearer: $0) }
            printerScopes = (try? await session.perform { try await APIClient.shared.adminAPIKeyPrinterScopes(bearer: $0) }) ?? [:]
            await choices.load()
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}

extension AdminCreatedKey: Identifiable {}

// MARK: - Create

private struct APIKeyCreateView: View {
    var onCreated: (AdminCreatedKey) async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = APIClient.APIKeyDraft()
    @State private var printerScope: Set<Int>?
    @State private var expires = false
    @State private var expiry = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Home Assistant"))
            }
            Section("What it can do") {
                Toggle("Read status and history", isOn: $draft.canReadStatus)
                Toggle("Queue prints", isOn: $draft.canQueue)
                Toggle("Control printers", isOn: $draft.canControlPrinter)
                Toggle("Manage library", isOn: $draft.canManageLibrary)
                Toggle("Manage inventory", isOn: $draft.canManageInventory)
                Toggle("Manage maintenance", isOn: $draft.canManageMaintenance)
                Toggle("Manage archives", isOn: $draft.canManageArchives)
                Toggle("Manage projects", isOn: $draft.canManageProjects)
                Toggle("Cloud access", isOn: $draft.canAccessCloud)
                Toggle("Update energy price", isOn: $draft.canUpdateEnergyCost)
                Toggle("Send notifications", isOn: $draft.canSendNotifications)
            }
            PrinterScopeSection(selection: $printerScope)
            Section {
                Toggle("Expires", isOn: $expires)
                if expires { DatePicker("Expires on", selection: $expiry, in: Date()..., displayedComponents: .date) }
            } footer: {
                Text("A key can never do more than the account that creates it. Admin actions (printers, users, settings) always need a signed-in admin, never a key.")
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
        }
        .farmBackground()
        .navigationTitle("New API key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Create") { Task { await create() } }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || printerScope?.isEmpty == true)
                }
            }
        }
    }

    private func create() async {
        saving = true
        error = nil
        defer { saving = false }
        var body = draft
        body.name = body.name.trimmingCharacters(in: .whitespaces)
        body.expiresAt = expires ? expiry : nil
        body.printerIds = printerScope?.sorted()
        do {
            let created = try await session.perform { try await APIClient.shared.createAPIKey(body, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            await onCreated(created)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Show once

private struct NewKeyView: View {
    let key: AdminCreatedKey
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(key.key).font(.callout.monospaced()).textSelection(.enabled)
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": key.key]], options: [.expirationDate: Date().addingTimeInterval(120)])
                    copied = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label(copied ? "Copied (clears in 2 minutes)" : "Copy key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } header: {
                Text(key.name)
            } footer: {
                Text("This is the only time Bambuddy shows the full key. Store it somewhere safe; if you lose it, revoke it and make a new one.")
            }
        }
        .farmBackground()
        .navigationTitle("Key created")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .interactiveDismissDisabled(!copied)
    }
}

// MARK: - Edit printer access

/// Which printers a key may use (`printer_ids`). PATCH replaces the list; it can't clear it, so a key
/// that is already limited stays limited.
private struct APIKeyPrintersView: View {
    let key: AdminAPIKey
    let current: [Int]?
    @ObservedObject var names: PrinterChoices
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Set<Int>?
    @State private var saving = false
    @State private var error: String?
    @State private var populated = false

    private var changed: Bool { scope != current.map(Set.init) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Key", value: key.name)
                LabeledContent("Starts with", value: "\(key.keyPrefix)…")
            } footer: {
                Text(key.scopes.isEmpty ? "No scopes" : key.scopes.joined(separator: " · "))
            }
            PrinterScopeSection(selection: $scope, canWiden: current == nil)
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
        }
        .farmBackground()
        .navigationTitle("Printer access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") { Task { await save() } }.disabled(!changed || scope == nil || scope?.isEmpty == true)
                }
            }
        }
        .onAppear {
            guard !populated else { return }
            populated = true
            scope = current.map(Set.init)
        }
    }

    private func save() async {
        guard let ids = scope?.sorted() else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.perform { try await APIClient.shared.setAPIKeyPrinters(key.id, printerIds: ids, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
