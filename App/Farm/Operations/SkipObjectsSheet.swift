import SwiftUI

/// Multi-select list of the current print's objects; skipped objects can't be
/// un-skipped (the printer has no such command).
struct SkipObjectsSheet: View {
    let printerId: Int
    let canSkip: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var result: APIClient.OpsPrintableObjects?
    @State private var selection = Set<Int>()
    @State private var loading = true
    @State private var loadError: String?
    @State private var confirm = false
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result, !result.objects.isEmpty {
                    list(result)
                } else if loading {
                    ProgressView("Loading objects").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(loadError == nil ? "No objects found" : "Couldn't load objects", systemImage: "cube.transparent")
                    } description: {
                        Text(loadError ?? "This print has no skippable objects, or Bambuddy couldn't read them from the file.")
                    } actions: {
                        Button("Try again") { Task { await load(reload: true) } }
                    }
                }
            }
            .background(Color.bgPrimary)
            .navigationTitle("Skip objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load(reload: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload objects")
                        .disabled(loading)
                }
            }
            .task { await load(reload: false) }
            .alert("Couldn't skip", isPresented: .constant(sendError != nil), presenting: sendError) { _ in
                Button("OK") { sendError = nil }
            } message: { Text($0) }
        }
    }

    private func list(_ result: APIClient.OpsPrintableObjects) -> some View {
        let skippedCount = result.objects.filter(\.skipped).count
        return List {
            Section {
                ForEach(result.objects) { object in
                    Button { toggle(object) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(object))
                                .foregroundStyle(object.skipped ? Color.textMuted : (selection.contains(object.id) ? Color.statusError : Color.textSecondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(object.name).foregroundStyle(object.skipped ? Color.textMuted : Color.primary)
                                if object.skipped { Text("Already skipped").font(.caption).foregroundStyle(Color.textMuted) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .disabled(object.skipped || !canSkip)
                    .accessibilityAddTraits(selection.contains(object.id) ? .isSelected : [])
                }
            } header: {
                Text("\(skippedCount) of \(result.objects.count) skipped")
            } footer: {
                Text("Skipped objects stay skipped until the print ends. Skip an object that has failed so the printer stops printing it.")
            }
            .listRowBackground(Color.bgCard)

            if canSkip {
                Section {
                    Button(role: .destructive) { confirm = true } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else {
                                Text(selection.isEmpty ? "Select objects to skip" : "Skip \(selection.count) object\(selection.count == 1 ? "" : "s")")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(selection.isEmpty || sending)
                    .confirmationDialog("Skip \(selection.count) object\(selection.count == 1 ? "" : "s")?", isPresented: $confirm,
                                        titleVisibility: .visible) {
                        Button("Skip", role: .destructive) { Task { await skip() } }
                    } message: {
                        Text("The printer will stop printing the selected objects for the rest of this print. This can't be undone.")
                    }
                }
                .listRowBackground(Color.bgCard)
            }
        }
        .farmBackground()
    }

    private func icon(_ object: APIClient.OpsPrintableObject) -> String {
        if object.skipped { return "slash.circle" }
        return selection.contains(object.id) ? "checkmark.circle.fill" : "circle"
    }

    private func toggle(_ object: APIClient.OpsPrintableObject) {
        if selection.contains(object.id) { selection.remove(object.id) } else { selection.insert(object.id) }
    }

    private func load(reload: Bool) async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let fresh = try await APIClient.shared.printableObjects(printerId, reload: reload)
            result = fresh
            selection = selection.intersection(Set(fresh.objects.filter { !$0.skipped }.map(\.id)))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func skip() async {
        sending = true
        defer { sending = false }
        do {
            try await APIClient.shared.skipObjects(printerId, objectIds: selection.sorted())
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            selection = []
            await load(reload: false)
        } catch {
            sendError = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
