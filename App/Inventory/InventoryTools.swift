import SwiftUI
import UniformTypeIdentifiers

// MARK: Usage history

/// Prints that used this spool (GET .../spools/{id}/usage). Reading needs inventory:read;
/// clearing the history needs inventory:update.
struct SpoolUsageSection: View {
    let spoolId: Int
    let spoolman: Bool
    let canClear: Bool
    @State private var records: [SpoolUsageRecord] = []
    @State private var loaded = false
    @State private var expanded = false
    @State private var confirmClear = false
    @State private var error: String?
    @EnvironmentObject private var farm: FarmStore

    var body: some View {
        Group {
            if farm.can("inventory:read") {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { withAnimation { expanded.toggle() } } label: {
                            HStack {
                                Text("Usage history").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
                                Spacer()
                                if loaded { Text("\(records.count)").font(.caption).foregroundStyle(Color.textMuted) }
                                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Color.textMuted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Usage history, \(expanded ? "expanded" : "collapsed")")
                        if expanded {
                            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                            if records.isEmpty, loaded, error == nil {
                                Text("No prints have used this spool yet.").font(.subheadline).foregroundStyle(Color.textMuted)
                            }
                            ForEach(records) { record in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(record.tint).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.printName ?? "Print").font(.subheadline).lineLimit(1)
                                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened) + (record.statusLabel.isEmpty ? "" : " · \(record.statusLabel)"))
                                            .font(.caption).foregroundStyle(Color.textMuted)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(String(format: "%.1f g", record.weightUsed)).font(.subheadline.monospacedDigit())
                                        if let cost = record.cost, cost > 0 {
                                            Text(cost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))).font(.caption).foregroundStyle(Color.textMuted)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if canClear, !records.isEmpty {
                                Button(role: .destructive) { confirmClear = true } label: { Label("Clear history", systemImage: "trash") }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .task(id: expanded) {
            guard expanded, !loaded else { return }
            do {
                records = try await APIClient.shared.spoolUsage(spoolId, spoolman: spoolman)
                error = nil
            } catch {
                self.error = FriendlyError.message(error)
            }
            loaded = true
        }
        .confirmationDialog("Clear this spool's usage history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { clear() }
        } message: { Text("The record of which prints used this spool is deleted. The spool's weight is unchanged, and forecasts lose this history.") }
    }

    private func clear() {
        Task {
            do {
                try await APIClient.shared.clearSpoolUsage(spoolId, spoolman: spoolman)
                records = []
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: Bulk: storage location

/// Move the selected spools to a storage location (POST .../spools/bulk-update {storage_location}).
struct BulkLocationSheet: View {
    let count: Int
    let onPick: (String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locations: [StorageLocation] = []
    @State private var typed = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(locations) { location in
                        Button { apply(location.name) } label: {
                            HStack {
                                Text(location.name).foregroundStyle(.primary)
                                Spacer()
                                if let n = location.spoolCount { Text("\(n)").font(.caption).foregroundStyle(Color.textMuted) }
                            }
                        }
                    }
                    if loaded, locations.isEmpty { Text("No saved locations. Type a name below.").font(.footnote).foregroundStyle(Color.textMuted) }
                } header: { Text("Move \(count) spool\(count == 1 ? "" : "s") to") }
                Section("Another location") {
                    TextField("Location name", text: $typed)
                    Button("Move here") { apply(typed.trimmingCharacters(in: .whitespaces)) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section {
                    Button(role: .destructive) { apply(nil) } label: { Label("Clear location", systemImage: "xmark.circle") }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .farmBackground()
            .disabled(busy)
            .navigationTitle("Storage location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                locations = (try? await APIClient.shared.storageLocations()) ?? []
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(_ name: String?) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await onPick(name)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: CSV import

struct CSVImportRow: Decodable, Identifiable {
    let rowNumber: Int
    let status: String
    let reason: String?
    let material: String?
    let brand: String?
    let colorName: String?
    let duplicateOfExisting: Bool?

    var id: Int { rowNumber }
}

/// Dry-run answer from POST /inventory/spools/import?dry_run=true.
struct CSVImportPreview: Decodable {
    let total: Int
    let validCount: Int
    let errorCount: Int
    let skippedCount: Int
    let rows: [CSVImportRow]
    let warnings: [String]?
}

struct CSVImportOutcome: Decodable {
    let created: Int
    let skipped: Int
    let errors: Int
    let errorRows: [CSVImportRow]?
}

/// Import spools from a CSV file: pick the file, see what would be created, then confirm.
/// Needs inventory:update. The columns are the ones Export produces.
struct CSVImportSheet: View {
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picking = true
    @State private var fileURL: URL?
    @State private var preview: CSVImportPreview?
    @State private var outcome: CSVImportOutcome?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                if working { HStack { ProgressView(); Text("Checking the file") }.font(.footnote) }
                if let outcome {
                    Section {
                        Label("Created \(outcome.created) spool\(outcome.created == 1 ? "" : "s")", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentTeal)
                        if outcome.skipped > 0 { Text("\(outcome.skipped) skipped").font(.footnote) }
                        if outcome.errors > 0 { Text("\(outcome.errors) rows had errors and were left out").font(.footnote).foregroundStyle(Color.statusWarning) }
                        ForEach(outcome.errorRows ?? []) { row in
                            Text("Row \(row.rowNumber): \(row.reason ?? "invalid")").font(.footnote).foregroundStyle(Color.statusError)
                        }
                    }
                } else if let preview {
                    Section {
                        LabeledContent("Rows in file", value: "\(preview.total)")
                        LabeledContent("Ready to import", value: "\(preview.validCount)")
                        if preview.errorCount > 0 { LabeledContent("With errors", value: "\(preview.errorCount)") }
                        if preview.skippedCount > 0 { LabeledContent("Skipped", value: "\(preview.skippedCount)") }
                    } header: { Text(fileURL?.lastPathComponent ?? "CSV file") } footer: {
                        Text("Rows with errors are skipped. Fix them in the file and import again.")
                    }
                    ForEach(preview.warnings ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.statusWarning) }
                    Section("Rows") {
                        ForEach(preview.rows) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.status == "valid" ? "checkmark.circle" : (row.status == "error" ? "xmark.octagon" : "minus.circle"))
                                    .foregroundStyle(row.status == "valid" ? Color.accentTeal : (row.status == "error" ? Color.statusError : Color.textMuted))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text([row.brand, row.material, row.colorName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty ?? "Row \(row.rowNumber)")
                                        .font(.subheadline)
                                    if let reason = row.reason, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(Color.textSecondary) }
                                    if row.duplicateOfExisting == true { Text("Looks like a spool you already have").font(.caption).foregroundStyle(Color.statusWarning) }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } else if !working, error == nil {
                    ContentUnavailableView("Choose a CSV file", systemImage: "tablecells",
                                           description: Text("Use the file Export produced, or one with the same columns."))
                        .listRowBackground(Color.clear)
                }
            }
            .farmBackground()
            .navigationTitle("Import spools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(outcome == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if outcome == nil, let preview, preview.validCount > 0 {
                        Button("Import \(preview.validCount)") { runImport() }.disabled(working)
                    } else if outcome == nil {
                        Button("Choose file") { picking = true }.disabled(working)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                switch result {
                case let .success(url): check(url)
                case let .failure(err): error = err.localizedDescription
                }
            }
        }
        .presentationDetents([.large])
    }

    private func check(_ url: URL) {
        working = true
        preview = nil
        outcome = nil
        Task {
            defer { working = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Copy out of the security scope so the confirm step can read it after this task ends.
                let local = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).csv")
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.copyItem(at: url, to: local)
                fileURL = local
                let data = try await APIClient.shared.importSpoolsCSV(fileURL: local, dryRun: true)
                preview = try APIClient.shared.decoder().decode(CSVImportPreview.self, from: data)
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func runImport() {
        guard let fileURL else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let data = try await APIClient.shared.importSpoolsCSV(fileURL: fileURL, dryRun: false)
                outcome = try APIClient.shared.decoder().decode(CSVImportOutcome.self, from: data)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? FileManager.default.removeItem(at: fileURL)
                onImported()
                error = nil
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
