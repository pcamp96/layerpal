import SwiftUI

/// Saved label sheets (Avery-style grids). Everyone with inventory:read can see and print with them;
/// creating, changing and deleting need inventory:update. No navigation stack of its own.
struct LabelTemplatesView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var templates: [LabelTemplate] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: Editing?
    @State private var deleting: LabelTemplate?

    private struct Editing: Identifiable { let template: LabelTemplate?; var id: Int { template?.id ?? -1 } }

    private var canWrite: Bool { farm.can("inventory:update") }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(templates) { template in
                Button { if canWrite { editing = Editing(template: template) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(summary(template.layout)).font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
                .swipeActions {
                    if canWrite { Button(role: .destructive) { deleting = template } label: { Label("Delete", systemImage: "trash") } }
                }
                .listRowBackground(Color.bgCard)
                .accessibilityElement(children: .combine)
            }
            if loaded, templates.isEmpty, error == nil {
                ContentUnavailableView("No saved sheets", systemImage: "rectangle.grid.3x2",
                                       description: Text(canWrite ? "Tap + to describe a sheet of labels." : "The built-in sizes are always available when printing."))
                    .listRowBackground(Color.clear)
            }
            if !canWrite, loaded {
                Label("Read-only: your account can't change label sheets.", systemImage: "lock").font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .farmBackground()
        .navigationTitle("Label sheets")
        .toolbar {
            if canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Editing(template: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("New label sheet")
                }
            }
        }
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { edit in LabelTemplateEditSheet(template: edit.template) { await load() } }
        .confirmationDialog("Delete this sheet?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { template in
            Button("Delete \(template.name)", role: .destructive) { delete(template) }
        } message: { _ in Text("Labels already printed with it are unaffected.") }
    }

    private func summary(_ l: SheetLayout) -> String {
        "\(l.page.uppercased()) · \(l.cols) × \(l.rows) labels of \(formatMM(l.labelWMm)) × \(formatMM(l.labelHMm)) mm"
    }

    private func formatMM(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func load() async {
        do {
            templates = try await APIClient.shared.labelTemplates()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func delete(_ template: LabelTemplate) {
        Task {
            do {
                try await APIClient.shared.deleteLabelTemplate(template.id)
                templates.removeAll { $0.id == template.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

struct LabelTemplateEditSheet: View {
    let template: LabelTemplate?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var layout: SheetLayout
    @State private var saving = false
    @State private var error: String?

    init(template: LabelTemplate?, onSaved: @escaping () async -> Void) {
        self.template = template
        self.onSaved = onSaved
        _name = State(initialValue: template?.name ?? "")
        _layout = State(initialValue: template?.layout ?? SheetLayout())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name) }
                Section("Page") {
                    Picker("Paper", selection: $layout.page) {
                        Text("A4").tag("a4")
                        Text("Letter").tag("letter")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Labels") {
                    number("Label width (mm)", $layout.labelWMm)
                    number("Label height (mm)", $layout.labelHMm)
                    Stepper("Columns: \(layout.cols)", value: $layout.cols, in: 1 ... SheetLayout.maxCols)
                    Stepper("Rows: \(layout.rows)", value: $layout.rows, in: 1 ... SheetLayout.maxRows)
                }
                Section("Margins and gaps (mm)") {
                    number("Top margin", $layout.topMm)
                    number("Left margin", $layout.leftMm)
                    number("Gap between columns", $layout.colGapMm)
                    number("Gap between rows", $layout.rowGapMm)
                }
                Section {
                    if let problem = layout.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.statusWarning)
                    } else {
                        Label("\(layout.capacity) labels per sheet", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Color.accentTeal)
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle(template == nil ? "New sheet" : "Edit sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || layout.problem != nil)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0 ... 2)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
        }
    }

    private func save() {
        saving = true
        let clean = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { saving = false }
            do {
                if let template {
                    _ = try await APIClient.shared.replaceLabelTemplate(template.id, name: clean, layout: layout)
                } else {
                    _ = try await APIClient.shared.createLabelTemplate(name: clean, layout: layout)
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
