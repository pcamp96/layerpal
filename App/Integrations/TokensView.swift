import SwiftUI
import UIKit

/// Long-lived camera tokens (Bambuddy: Camera tokens). A token lets Home Assistant, Frigate or a kiosk pull
/// camera streams without refreshing the hourly one. The /auth/tokens routes need `camera:view` and a real
/// user (they refuse API keys), so this runs on the sign-in session. The token itself is shown once.
struct TokensView: View {
    var body: some View {
        AdminGate(title: "Camera tokens", permission: "camera:view") { TokenList() }
    }
}

private struct TokenList: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var tokens: [TokRecord] = []
    @State private var showAll = false
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false
    @State private var created: TokRecord?
    @State private var pendingRevoke: TokRecord?

    private var isAdmin: Bool { session.me?.isAdmin == true }

    var body: some View {
        List {
            if isAdmin {
                Section {
                    Toggle("Show everyone's tokens", isOn: $showAll).onChange(of: showAll) { _, _ in Task { await load() } }
                } footer: { Text("Admins can review and revoke any user's tokens, handy if one leaks.") }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
            Section {
                ForEach(tokens) { token in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(token.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if token.isExpired { Pill(text: "Expired", tint: .statusError) }
                            Pill(text: token.scopeLabel, tint: .statusFinished)
                        }
                        if let prefix = token.lookupPrefix { Text("\(prefix)…").font(.caption.monospaced()).foregroundStyle(Color.textMuted) }
                        HStack(spacing: 10) {
                            Text(token.lastUsedAt.map { "Used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                            if let exp = token.expiresAt { Text("Expires \(exp.formatted(date: .abbreviated, time: .omitted))") }
                        }
                        .font(.caption2).foregroundStyle(Color.textMuted)
                        if showAll, let uid = token.userId { Text("User #\(uid)").font(.caption2).foregroundStyle(Color.textMuted) }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingRevoke = token } label: { Label("Revoke", systemImage: "trash") }
                    }
                }
            } footer: {
                if !tokens.isEmpty { Text("Swipe a token to revoke it.") }
            }
        }
        .farmBackground()
        .overlay {
            if loaded, tokens.isEmpty, error == nil {
                ContentUnavailableView("No camera tokens", systemImage: "key.viewfinder",
                                       description: Text("Create one for Home Assistant, Frigate or a kiosk."))
            } else if !loaded, error == nil { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create camera token")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { TokenCreateView { record in created = record; await load() } }
        }
        .sheet(item: $created) { record in NavigationStack { TokenShownView(record: record) } }
        .confirmationDialog("Revoke \(pendingRevoke?.name ?? "token")?",
                            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible) {
            Button("Revoke token", role: .destructive) { if let t = pendingRevoke { revoke(t) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything using this token loses camera access immediately. This can't be undone.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            tokens = try await session.perform { bearer in
                showAll && isAdmin ? try await APIClient.shared.tokListAll(bearer: bearer) : try await APIClient.shared.tokList(bearer: bearer)
            }
            error = nil
        } catch { self.error = AdminError.friendly(error) }
        loaded = true
    }

    private func revoke(_ token: TokRecord) {
        pendingRevoke = nil
        Task {
            do {
                try await session.perform { try await APIClient.shared.tokRevoke(token.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await load()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Create

private struct TokenCreateView: View {
    var onCreated: (TokRecord) async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope = "camera_stream"
    @State private var days = 90
    @State private var saving = false
    @State private var error: String?

    private var scopeNote: String {
        switch scope {
        case "camwall": "Video plus the Cam Wall's tile info: printer names and print state."
        case "overlay": "Video plus single-printer status for the streaming overlay, including the print filename."
        default: "Video streams and snapshots only. What a Home Assistant or Frigate card needs."
        }
    }

    var body: some View {
        Form {
            Section { TextField("Name", text: $name, prompt: Text("e.g. Home Assistant")) }
            Section {
                Picker("Scope", selection: $scope) {
                    Text("Camera stream").tag("camera_stream")
                    Text("Cam Wall").tag("camwall")
                    Text("Streaming overlay").tag("overlay")
                }
            } footer: { Text(scopeNote) }
            Section {
                Stepper("Expires in \(days) days", value: $days, in: 1 ... 365)
            } footer: { Text("The longest a token can live is 365 days. There are no permanent tokens.") }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
        }
        .farmBackground()
        .navigationTitle("New camera token")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Create") { Task { await create() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let record = try await session.perform {
                try await APIClient.shared.tokCreate(name: name.trimmingCharacters(in: .whitespaces), days: days, scope: scope, bearer: $0)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            await onCreated(record)
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Show once

private struct TokenShownView: View {
    let record: TokRecord
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(record.token ?? "No token returned").font(.callout.monospaced()).textSelection(.enabled)
                if let token = record.token {
                    Button {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": token]], options: [.expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Label(copied ? "Copied (clears in 2 minutes)" : "Copy token", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            } header: {
                Text("\(record.name) · \(record.scopeLabel)")
            } footer: {
                Text("This is the only time Bambuddy shows the full token. Store it somewhere safe; if you lose it, revoke it and make a new one.")
            }
        }
        .farmBackground()
        .navigationTitle("Token created")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .interactiveDismissDisabled(!copied)
    }
}
