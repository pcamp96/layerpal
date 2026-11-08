import SwiftUI

// MARK: README

/// A folder's README.md (or description.md): GET /library/folders/{id}/readme. View only, as in
/// the web UI; the server has no endpoint that edits a library file's contents.
struct FolderReadmeSection: View {
    let folderId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var readme: FolderReadme?
    @State private var expanded = true

    var body: some View {
        Group {
            if let readme {
                DisclosureGroup(isExpanded: $expanded) {
                    MarkdownLite(text: readme.content)
                        .padding(.top, 6)
                    if readme.truncated {
                        Text("Shortened: the file is longer than the server shows.").font(.caption).foregroundStyle(Color.textMuted)
                    }
                } label: {
                    Label(readme.filename, systemImage: "doc.text").font(.subheadline.weight(.medium))
                }
                .accessibilityLabel("Folder description \(readme.filename)")
            }
        }
        .task(id: folderId) {
            guard farm.can("library:read_all") || farm.can("library:read_own") else { return }
            readme = try? await APIClient.shared.libFolderReadme(folderId)
        }
    }
}

/// Headings, bullets, code blocks and inline markdown, which is what model descriptions use.
struct MarkdownLite: View {
    let text: String

    private enum Block: Identifiable {
        case heading(Int, String), bullet(String), code(String), paragraph(String)
        var id: String {
            switch self {
            case let .heading(l, t): "h\(l)\(t)"
            case let .bullet(t): "b\(t)"
            case let .code(t): "c\(t)"
            case let .paragraph(t): "p\(t)"
            }
        }
    }

    private var blocks: [(Int, Block)] {
        var result: [Block] = []
        var code: [String] = []
        var inCode = false
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode { result.append(.code(code.joined(separator: "\n"))); code = [] } else { flush() }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                result.append(.heading(min(level, 3), trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                result.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }
        }
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        flush()
        return Array(result.enumerated()).map { ($0.offset, $0.element) }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks, id: \.0) { _, block in
                switch block {
                case let .heading(level, t):
                    Text(inline(t)).font(level == 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .accessibilityAddTraits(.isHeader)
                case let .bullet(t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(t))
                    }
                    .font(.subheadline)
                case let .code(t):
                    Text(t).font(.system(.footnote, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.bgRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case let .paragraph(t):
                    Text(inline(t)).font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Links to projects and archives

/// Which project and archive a folder is linked to. Linking needs library:update_all.
struct FolderLinksSheet: View {
    let node: LibFolderNode
    let onChanged: () -> Void
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var projectId: Int?
    @State private var projectName: String?
    @State private var archiveId: Int?
    @State private var archiveName: String?
    @State private var pickingProject = false
    @State private var pickingArchive = false
    @State private var error: String?

    init(node: LibFolderNode, onChanged: @escaping () -> Void) {
        self.node = node
        self.onChanged = onChanged
        _projectId = State(initialValue: node.projectId)
        _projectName = State(initialValue: node.projectName)
        _archiveId = State(initialValue: node.archiveId)
        _archiveName = State(initialValue: node.archiveName)
    }

    private var canLink: Bool { farm.can("library:update_all") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(title: "Project", name: projectName, symbol: "square.stack.3d.up", linked: projectId != nil,
                        choose: { pickingProject = true }, remove: { Task { await unlinkProject() } })
                    row(title: "Print", name: archiveName, symbol: "clock.arrow.circlepath", linked: archiveId != nil,
                        choose: { pickingArchive = true }, remove: { Task { await unlinkArchive() } })
                } header: { Text("Linked to") } footer: {
                    Text(canLink ? "A folder linked to a project feeds the project's file list, and prints from it count toward the project."
                         : "Linking folders needs the library:update_all permission.")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle(node.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pickingProject) {
                ProjectPickerSheet(currentId: projectId) { id in
                    try await APIClient.shared.libLinkFolder(node.id, projectId: id)
                    projectId = id
                    projectName = nil
                    if let id, let project = try? await APIClient.shared.project(id) { projectName = project.name }
                    onChanged()
                }
            }
            .sheet(isPresented: $pickingArchive) {
                ArchiveLinkPicker { archive in
                    try await APIClient.shared.libLinkFolder(node.id, archiveId: archive.id)
                    archiveId = archive.id
                    archiveName = archive.name
                    onChanged()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(title: String, name: String?, symbol: String, linked: Bool, choose: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(linked ? (name ?? "Linked") : "None").foregroundStyle(Color.textMuted).lineLimit(1)
            if canLink {
                Menu {
                    Button(action: choose) { Label(linked ? "Change" : "Link", systemImage: "link") }
                    if linked { Button(role: .destructive, action: remove) { Label("Remove link", systemImage: "link.badge.minus") } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("\(title) link actions")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func unlinkProject() async {
        do {
            try await APIClient.shared.libLinkFolder(node.id, projectId: nil)
            projectId = nil
            projectName = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onChanged()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func unlinkArchive() async {
        do {
            try await APIClient.shared.libLinkFolder(node.id, archiveId: nil)
            archiveId = nil
            archiveName = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onChanged()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

/// Pick a print (archive) to link a folder to: recent prints, or search.
struct ArchiveLinkPicker: View {
    let onPick: (Archive) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var archives: [Archive] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                ForEach(archives) { archive in
                    Button { pick(archive) } label: { ArchiveRow(archive: archive, showPrinter: false) }.foregroundStyle(.primary)
                }
                if loaded, archives.isEmpty, error == nil { ContentUnavailableView("No prints", systemImage: "clock.arrow.circlepath") }
            }
            .listStyle(.plain)
            .farmBackground()
            .searchable(text: $search, prompt: "Search prints")
            .onSubmit(of: .search) { Task { await load() } }
            .onChange(of: search) { _, q in if q.isEmpty { Task { await load() } } }
            .navigationTitle("Link to a print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    private func load() async {
        do {
            let q = search.trimmingCharacters(in: .whitespaces)
            archives = q.count >= 2 ? try await APIClient.shared.searchArchives(q, status: nil, printerId: nil) : try await APIClient.shared.archives(limit: 40, offset: 0, printerId: nil)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func pick(_ archive: Archive) {
        Task {
            do {
                try await onPick(archive)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

// MARK: Archive page: linked folders

/// Library folders linked to this print (GET /library/folders/by-archive/{id}).
struct ArchiveFoldersSection: View {
    let archiveId: Int
    @EnvironmentObject private var farm: FarmStore
    @State private var folders: [LibFolderNode] = []

    var body: some View {
        Group {
            if !folders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Library folders", trailing: "\(folders.count)")
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                                NavigationLink { LibraryFolderView(folderId: folder.id).navigationTitle(folder.name) } label: {
                                    HStack {
                                        Label(folder.name, systemImage: "folder.fill").foregroundStyle(.primary)
                                        Spacer()
                                        if let n = folder.fileCount, n > 0 { Text("\(n)").font(.caption).foregroundStyle(Color.textMuted) }
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textMuted)
                                    }
                                    .padding(14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if index < folders.count - 1 { Divider().padding(.leading, 14) }
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard farm.can("library:read_all") || farm.can("library:read_own") else { return }
            folders = (try? await APIClient.shared.libFolders(archiveId: archiveId)) ?? []
        }
    }
}
