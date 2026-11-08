import SwiftUI

/// Notification message templates (Bambuddy: Settings > Notifications > Message templates). One template per
/// event, with `{variable}` placeholders. Listing and previewing need `notification_templates:read`; saving and
/// resetting need `notification_templates:update`.
struct MessageTemplatesView: View {
    var body: some View {
        SessionGate(title: "Message templates", permission: "notification_templates:read") { TemplateList() }
    }
}

private struct TemplateList: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var templates: [SetupTemplate] = []
    @State private var variables: [String: SetupEventVariables] = [:]
    @State private var loaded = false
    @State private var error: String?
    @State private var search = ""

    private var shown: [SetupTemplate] {
        let sorted = templates.sorted { name(for: $0).localizedCaseInsensitiveCompare(name(for: $1)) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { name(for: $0).localizedCaseInsensitiveContains(search) || $0.titleTemplate.localizedCaseInsensitiveContains(search) }
    }

    private func name(for t: SetupTemplate) -> String { variables[t.eventType]?.eventName ?? t.name }

    var body: some View {
        List {
            if let error { Section { InlineError(message: error) } }
            ForEach(shown) { template in
                NavigationLink {
                    TemplateEditor(template: template, info: variables[template.eventType]) { await load() }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name(for: template)).font(.subheadline.weight(.semibold))
                        Text(template.titleTemplate).font(.caption).foregroundStyle(Color.textMuted).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .farmBackground()
        .searchable(text: $search, prompt: "Search events")
        .overlay {
            if loaded, templates.isEmpty, error == nil {
                ContentUnavailableView("No templates", systemImage: "text.bubble")
            } else if !loaded, error == nil { ProgressView() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            templates = try await session.perform { try await APIClient.shared.templateList(bearer: $0) }
            let vars = try await session.perform { try await APIClient.shared.templateVariables(bearer: $0) }
            variables = Dictionary(vars.map { ($0.eventType, $0) }, uniquingKeysWith: { a, _ in a })
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}

private struct TemplateEditor: View {
    let template: SetupTemplate
    let info: SetupEventVariables?
    var onSaved: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var ready = false
    @State private var preview: (title: String, body: String)?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmReset = false

    private var canEdit: Bool { session.can("notification_templates:update") }
    private var changed: Bool { title != template.titleTemplate || bodyText != template.bodyTemplate }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 200
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bodyText.count <= 2000
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical).lineLimit(1 ... 3).disabled(!canEdit)
            } header: { Text("Title") } footer: { Text("\(title.count)/200").foregroundStyle(title.count > 200 ? Color.statusError : Color.textMuted) }
            Section {
                TextEditor(text: $bodyText).font(.callout).frame(minHeight: 140).disabled(!canEdit)
                    .textInputAutocapitalization(.sentences)
            } header: { Text("Message") } footer: { Text("\(bodyText.count)/2000").foregroundStyle(bodyText.count > 2000 ? Color.statusError : Color.textMuted) }
            if canEdit, let vars = info?.variables, !vars.isEmpty {
                Section {
                    Menu {
                        ForEach(vars, id: \.self) { v in Button("{\(v)}") { bodyText += "{\(v)}" } }
                    } label: { Label("Add variable to message", systemImage: "curlybraces") }
                    Menu {
                        ForEach(vars, id: \.self) { v in Button("{\(v)}") { title += "{\(v)}" } }
                    } label: { Label("Add variable to title", systemImage: "curlybraces") }
                } header: { Text("Variables") } footer: {
                    Text(vars.map { "{\($0)}" }.joined(separator: "  ") + (info?.supportsPhoto == true ? "\nThis message can carry a camera snapshot." : ""))
                        .font(.caption.monospaced())
                }
            }
            Section {
                Button { Task { await runPreview() } } label: { Label("Preview with sample data", systemImage: "eye") }.disabled(busy || !valid)
                if let preview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.title).font(.subheadline.weight(.semibold))
                        Text(preview.body).font(.callout).foregroundStyle(Color.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let error { Section { InlineError(message: error) } }
            if canEdit {
                Section {
                    Button("Reset to default", role: .destructive) { confirmReset = true }.disabled(busy)
                } footer: { Text("Puts back Bambuddy's original wording for this event.") }
            }
        }
        .farmBackground()
        .navigationTitle(info?.eventName ?? template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(!changed || !valid) }
                }
            }
        }
        .confirmationDialog("Reset this template?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to default", role: .destructive) { Task { await reset() } }
        } message: { Text("Your wording for \(info?.eventName ?? template.name) is replaced.") }
        .onAppear {
            guard !ready else { return }
            ready = true
            title = template.titleTemplate
            bodyText = template.bodyTemplate
        }
    }

    private func runPreview() async {
        busy = true
        defer { busy = false }
        do {
            let t = title, b = bodyText
            preview = try await session.perform { try await APIClient.shared.templatePreview(eventType: template.eventType, title: t, body: b, bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let t = title, b = bodyText
            _ = try await session.perform { try await APIClient.shared.templateSave(template.id, title: t, body: b, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onSaved()
            dismiss()
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func reset() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let fresh = try await session.perform { try await APIClient.shared.templateReset(template.id, bearer: $0) }
            title = fresh.titleTemplate
            bodyText = fresh.bodyTemplate
            preview = nil
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await onSaved()
        } catch {
            self.error = AdminError.friendly(error)
        }
    }
}
