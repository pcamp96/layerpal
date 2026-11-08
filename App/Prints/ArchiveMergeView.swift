import SwiftUI

/// Merge duplicate archives: every group of archives holding the same file (same owner and
/// project) becomes one, keeping the oldest and moving the rest's prints onto it.
/// Needs archives:update_all and archives:delete_all.
struct ArchiveMergeView: View {
    var onMerged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [MergeGroup] = []
    @State private var selected: Set<Int> = []
    @State private var loaded = false
    @State private var error: String?
    @State private var confirming = false
    @State private var merging = false
    @State private var outcome: MergeOutcome?

    private var mergeable: [MergeGroup] { groups.filter { $0.skipped == nil } }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError).listRowBackground(Color.bgPrimary) }
                if let outcome { outcomeSection(outcome) }
                if !loaded, error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if groups.isEmpty, outcome == nil, error == nil {
                    ContentUnavailableView("No duplicates", systemImage: "checkmark.circle",
                                           description: Text("Every archive holds a different file."))
                        .listRowBackground(Color.clear)
                }
                ForEach(groups) { group in groupRow(group) }
            }
            .listStyle(.insetGrouped)
            .farmBackground()
            .navigationTitle("Merge duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge \(selected.count)") { confirming = true }
                        .disabled(selected.isEmpty || merging)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(selected.count == mergeable.count ? "Select none" : "Select all") {
                        selected = selected.count == mergeable.count ? [] : Set(mergeable.map(\.id))
                    }
                    .disabled(mergeable.isEmpty)
                }
            }
            .confirmationDialog("Merge \(selected.count) group\(selected.count == 1 ? "" : "s")?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Merge", role: .destructive) { merge() }
            } message: {
                Text("The oldest archive in each group stays and takes over the others' prints, photos and notes. The duplicates are removed and this can't be undone.")
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func groupRow(_ group: MergeGroup) -> some View {
        let canSelect = group.skipped == nil
        return Button {
            guard canSelect else { return }
            if selected.contains(group.id) { selected.remove(group.id) } else { selected.insert(group.id) }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected.contains(group.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(canSelect ? Color.accentTeal : Color.textMuted)
                    .font(.title3)
                RemoteImage(path: "archives/\(group.survivor.id)/thumbnail")
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.survivor.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text("Keeps the oldest, merges \(group.merged.count) other\(group.merged.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    if let when = group.survivor.createdAt?.date {
                        Text("Oldest from \(when.formatted(date: .abbreviated, time: .omitted)), \(group.survivor.runCount ?? 0) prints")
                            .font(.caption2).foregroundStyle(Color.textMuted)
                    }
                    if let text = group.skippedText {
                        Label(text, systemImage: "pause.circle").font(.caption).foregroundStyle(Color.statusWarning)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect || merging)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected.contains(group.id) ? .isSelected : [])
    }

    private func outcomeSection(_ result: MergeOutcome) -> some View {
        Section {
            Label("Merged \(result.merged.count) group\(result.merged.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.accentTeal)
            ForEach(result.skipped, id: \.survivorId) { skip in
                Label("Archive \(skip.survivorId) left alone (\(skip.reason.replacingOccurrences(of: "_", with: " "))).", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Color.statusWarning)
            }
        }
    }

    private func load() async {
        do {
            groups = try await APIClient.shared.archiveMergePreview()
            selected = selected.intersection(Set(mergeable.map(\.id)))
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func merge() {
        let ids = Array(selected)
        merging = true
        Task {
            defer { merging = false }
            do {
                outcome = try await APIClient.shared.mergeArchives(survivorIds: ids)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                selected = []
                onMerged()
                await load()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
