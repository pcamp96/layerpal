import SwiftUI

/// Restore from the Git backup (Bambuddy: Settings > Backup > Restore from Git). Needs `github:restore`, plus the
/// write permission of each category restored. Pick a commit, read the preview, choose categories, type RESTORE.
struct GitRestoreSheet: View {
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var list: GitCommitList?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Section { OpsBanner(kind: .error, text: error) } }
                if let list {
                    if !list.success { Section { OpsBanner(kind: .error, text: list.message) } }
                    Section {
                        ForEach(list.commits) { commit in
                            NavigationLink { GitRestoreDetail(commit: commit, onFinished: { dismiss() }) } label: { row(commit) }
                        }
                    } header: {
                        Text(list.branch.isEmpty ? "Backups" : "Backups on \(list.branch)")
                    } footer: {
                        Text("Each commit is one backup run. Newest first. Restoring writes into Bambuddy's live data, so preview first.")
                    }
                }
            }
            .farmBackground()
            .overlay { if !loaded, error == nil { ProgressView() } }
            .overlay {
                if loaded, error == nil, list?.success == true, list?.commits.isEmpty == true {
                    ContentUnavailableView("No backups yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Run a Git backup first, then it shows up here."))
                }
            }
            .navigationTitle("Restore from Git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func row(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.message.split(separator: "\n").first.map(String.init) ?? "Backup").font(.subheadline).lineLimit(2)
            HStack(spacing: 8) {
                Text(String(commit.sha.prefix(8))).font(.caption.monospaced())
                if let date = commit.date { Text(date.opsShort) }
                if !commit.author.isEmpty { Text(commit.author) }
            }
            .font(.caption).foregroundStyle(Color.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            list = try await session.perform { try await APIClient.shared.githubCommits(bearer: $0) }
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }
}

private struct GitRestoreDetail: View {
    let commit: GitCommit
    var onFinished: () -> Void
    @ObservedObject private var session = AdminSession.shared
    @State private var preview: GitRestorePreview?
    @State private var selected: Set<String> = []
    @State private var overwrite = false
    @State private var loaded = false
    @State private var error: String?
    @State private var confirming = false
    @State private var restoring = false
    @State private var result: GitRestoreResult?

    private func allowed(_ category: GitRestoreCategory) -> Bool {
        guard category.available else { return false }
        guard let permission = category.permission else { return false }
        return session.can(permission)
    }

    private var chosen: [GitRestoreCategory] { (preview?.categories ?? []).filter { selected.contains($0.category) } }

    var body: some View {
        List {
            if let error { Section { OpsBanner(kind: .error, text: error) } }
            if let result { resultSection(result) }
            if let preview, result == nil {
                if !preview.success { Section { OpsBanner(kind: .error, text: preview.message) } }
                Section("Backup") {
                    OpsValueRow(label: "Commit", value: String(preview.ref.prefix(8)), mono: true)
                    if let date = (preview.commit ?? commit).date { OpsValueRow(label: "Taken", value: date.opsShort) }
                    if let message = preview.commit?.message ?? Optional(commit.message), !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(Color.textMuted)
                    }
                }
                Section {
                    ForEach(preview.categories) { category in categoryRow(category) }
                } header: {
                    Text("What this backup contains")
                } footer: {
                    Text("Choose what to bring back. A category needs its own permission on top of github:restore, and sign-in and mail settings stay as they are unless you're an admin.")
                }
                Section {
                    Toggle("Overwrite existing rows", isOn: $overwrite)
                } footer: {
                    Text(overwrite
                        ? "Rows that already exist are updated to match the backup. Newer changes to those rows are lost."
                        : "Only rows missing from Bambuddy are added. Nothing that exists now is changed.")
                }
                Section {
                    Button(role: .destructive) { confirming = true } label: {
                        HStack {
                            Label("Restore \(chosen.count) categor\(chosen.count == 1 ? "y" : "ies")…", systemImage: "arrow.counterclockwise")
                            Spacer()
                            if restoring { ProgressView() }
                        }
                    }
                    .disabled(chosen.isEmpty || restoring)
                }
            }
        }
        .farmBackground()
        .overlay { if !loaded, error == nil { ProgressView() } }
        .navigationTitle(String(commit.sha.prefix(8)))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $confirming) {
            TypedConfirmSheet(
                title: "Restore from Git",
                consequence: "This writes \(chosen.map(\.title).joined(separator: ", ")) from backup \(String(commit.sha.prefix(8))) into Bambuddy. \(overwrite ? "Existing rows are overwritten with the backup's version, so anything changed since is lost." : "Only missing rows are added.") A restore can't be undone from the app, so take a fresh backup first if you aren't sure.",
                word: "RESTORE", actionTitle: "Restore") { restore() }
        }
    }

    private func categoryRow(_ category: GitRestoreCategory) -> some View {
        let enabled = allowed(category)
        return Toggle(isOn: Binding(get: { selected.contains(category.category) },
                                    set: { on in if on { selected.insert(category.category) } else { selected.remove(category.category) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title).font(.subheadline)
                Text(subtitle(category)).font(.caption).foregroundStyle(Color.textMuted)
            }
        }
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ category: GitRestoreCategory) -> String {
        if !category.available { return category.detail ?? "Not in this backup" }
        if let permission = category.permission, !session.can(permission) { return "Needs \(permission)" }
        return "\(category.itemCount) item\(category.itemCount == 1 ? "" : "s")"
    }

    private func resultSection(_ r: GitRestoreResult) -> some View {
        Group {
            Section {
                OpsBanner(kind: r.success ? .success : .error, text: r.message.isEmpty ? (r.success ? "Restore finished." : "Restore failed.") : r.message)
            }
            Section("Results") {
                ForEach(r.lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(GitRestoreCategory(category: line.category, available: true, itemCount: 0, detail: nil).title).font(.subheadline)
                            Spacer()
                            Text("\(line.restored) restored · \(line.skipped) skipped\(line.failed > 0 ? " · \(line.failed) failed" : "")")
                                .font(.caption).foregroundStyle(line.failed > 0 ? Color.statusError : Color.textSecondary)
                        }
                        ForEach(line.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.textMuted) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                Button("Done") { onFinished() }
            } footer: {
                Text("If you restored settings or archives, pull to refresh the other screens to see them.")
            }
        }
    }

    private func load() async {
        do {
            let p = try await session.perform { try await APIClient.shared.githubRestorePreview(ref: commit.sha, bearer: $0) }
            preview = p
            selected = Set(p.categories.filter { allowed($0) }.map(\.category))
            error = nil
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func restore() {
        Task {
            restoring = true
            error = nil
            defer { restoring = false }
            let categories = chosen.map(\.category)
            let ref = preview?.ref ?? commit.sha
            let over = overwrite
            do {
                result = try await session.perform { try await APIClient.shared.githubRestore(ref: ref, categories: categories, overwrite: over, bearer: $0) }
                result?.success == true ? OpsHaptics.success() : OpsHaptics.error()
            } catch {
                self.error = AdminError.friendly(error)
                OpsHaptics.error()
            }
        }
    }
}
