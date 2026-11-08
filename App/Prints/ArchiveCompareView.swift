import SwiftUI

/// Two to five archives side by side: settings, filament, time and outcome, with the
/// differences marked, plus what separated the good prints from the failed ones.
struct ArchiveCompareView: View {
    let ids: [Int]
    @Environment(\.dismiss) private var dismiss
    @State private var result: ArchiveComparison?
    @State private var differencesOnly = false
    @State private var error: String?

    private let labelWidth: CGFloat = 112
    private let columnWidth: CGFloat = 132

    private var rows: [CompareField] {
        guard let result else { return [] }
        return differencesOnly ? result.comparison.filter(\.hasDifference) : result.comparison
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                    if let result {
                        Toggle("Show differences only", isOn: $differencesOnly).tint(.accentTeal)
                        Card(padding: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 0) {
                                    header(result)
                                    Divider()
                                    ForEach(rows) { row in
                                        fieldRow(row, count: result.archives.count)
                                        Divider()
                                    }
                                    if rows.isEmpty {
                                        Text("These archives match on every compared setting.")
                                            .font(.footnote).foregroundStyle(Color.textMuted).padding(14)
                                    }
                                }
                            }
                        }
                        correlation(result.successCorrelation)
                    } else if error == nil {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .padding()
            }
            .background(Color.bgPrimary)
            .navigationTitle("Compare prints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
    }

    private func header(_ result: ArchiveComparison) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 1)
            ForEach(result.archives) { archive in
                VStack(alignment: .leading, spacing: 6) {
                    RemoteImage(path: "archives/\(archive.id)/thumbnail")
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    Text(archive.name).font(.caption.weight(.semibold)).lineLimit(2)
                    if let project = archive.projectName { Text(project).font(.caption2).foregroundStyle(Color.textMuted).lineLimit(1) }
                    if let when = archive.createdAt?.date {
                        Text(when.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(Color.textMuted)
                    }
                }
                .frame(width: columnWidth, alignment: .leading)
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 12)
    }

    private func fieldRow(_ row: CompareField, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(row.label).font(.caption).foregroundStyle(Color.textMuted).frame(width: labelWidth, alignment: .leading)
            ForEach(0 ..< count, id: \.self) { index in
                Text(row.display(index))
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(row.hasDifference ? .semibold : .regular)
                    .foregroundStyle(row.hasDifference ? Color.statusWarning : Color.primary)
                    .frame(width: columnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.label + (row.hasDifference ? ", differs" : ""))
        .accessibilityValue((0 ..< count).map { row.display($0) }.joined(separator: ", "))
    }

    @ViewBuilder private func correlation(_ c: CompareCorrelation?) -> some View {
        if let c {
            SectionHeader(title: "What made the difference")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    if c.hasBothOutcomes {
                        Text("\(c.successfulCount ?? 0) successful, \(c.failedCount ?? 0) failed").font(.footnote).foregroundStyle(Color.textSecondary)
                        if (c.insights ?? []).isEmpty {
                            Text("No setting stood out.").font(.subheadline)
                        }
                        ForEach(c.insights ?? []) { Label($0.insight, systemImage: "lightbulb").font(.subheadline) }
                    } else {
                        Text(c.message ?? "Needs both a successful and a failed print to find a pattern.").font(.subheadline).foregroundStyle(Color.textMuted)
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            result = try await APIClient.shared.compareArchives(ids)
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

