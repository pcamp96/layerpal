import SwiftUI

/// A month grid of prints, from GET /archives/prints for the visible month. Each day shows
/// how many prints ended on it; tapping a day lists them.
struct ArchiveCalendarView: View {
    var printerId: Int?
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var prints: [PrintLogEntry] = []
    @State private var selectedDay: Date?
    @State private var printerFilter: Int?
    @State private var loading = false
    @State private var error: String?

    private var calendar: Calendar { Calendar.current }

    private var byDay: [Date: [PrintLogEntry]] {
        Dictionary(grouping: prints.compactMap { p in p.endedAt.map { (calendar.startOfDay(for: $0), p) } }, by: { $0.0 }).mapValues { $0.map(\.1) }
    }

    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let count = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 30
        return Array(repeating: nil, count: lead) + (0 ..< count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var weekdayHeaders: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0 ..< 7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    monthHeader
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                    Card { grid }
                    summary
                    if let day = selectedDay { dayList(day) }
                }
                .padding()
            }
            .background(Color.bgPrimary)
            .navigationTitle("Print calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if printerId == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Printer", selection: $printerFilter) {
                                Text("All printers").tag(Int?.none)
                                ForEach(farm.printers) { Text($0.name).tag(Int?.some($0.id)) }
                            }
                        } label: {
                            Image(systemName: printerFilter == nil ? "printer" : "printer.fill")
                        }
                        .accessibilityLabel("Filter by printer")
                    }
                }
            }
            .task(id: "\(month.timeIntervalSince1970)-\(printerFilter ?? -1)") { await load() }
        }
    }

    // MARK: Pieces

    private var monthHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
        }
        .padding(.horizontal, 4)
    }

    private var grid: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(weekdayHeaders.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(Color.textMuted)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 46) }
                }
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let entries = byDay[day] ?? []
        let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let today = calendar.isDateInToday(day)
        return Button {
            selectedDay = selected ? nil : day
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.footnote.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.accentTeal : Color.primary)
                if entries.isEmpty {
                    Color.clear.frame(height: 8)
                } else {
                    HStack(spacing: 2) {
                        ForEach(Array(Set(entries.map(\.status)).sorted().prefix(3)), id: \.self) { status in
                            Circle().fill(color(for: status)).frame(width: 6, height: 6)
                        }
                        if entries.count > 1 { Text("\(entries.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.textSecondary) }
                    }
                    .frame(height: 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(selected ? Color.accentTeal.opacity(0.18) : Color.bgRaised.opacity(entries.isEmpty ? 0.25 : 0.6),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.accentTeal : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(entries.isEmpty ? "No prints" : "\(entries.count) print\(entries.count == 1 ? "" : "s")")
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": .accentTeal
        case "failed": .statusError
        case "cancelled", "aborted", "stopped": .statusWarning
        default: .textMuted
        }
    }

    private var summary: some View {
        let done = prints.filter { $0.status == "completed" }.count
        let failed = prints.filter { $0.status == "failed" }.count
        let grams = prints.reduce(0) { $0 + ($1.filamentUsedGrams ?? 0) }
        return HStack(spacing: 18) {
            stat("\(prints.count)", "prints")
            stat("\(done)", "completed")
            stat("\(failed)", "failed")
            stat(formatGrams(grams), "filament")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(Color.textMuted)
        }
    }

    @ViewBuilder private func dayList(_ day: Date) -> some View {
        let entries = (byDay[calendar.startOfDay(for: day)] ?? []).sorted { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
        SectionHeader(title: day.formatted(date: .complete, time: .omitted), trailing: "\(entries.count)")
        if entries.isEmpty {
            Card { Text("Nothing printed this day.").font(.footnote).foregroundStyle(Color.textMuted) }
        } else {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry)
                        if index < entries.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func entryRow(_ entry: PrintLogEntry) -> some View {
        let row = HStack(spacing: 10) {
            Circle().fill(entry.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.statusLabel)
                    if let printer = entry.printerName { Text("· \(printer)") }
                    if let ended = entry.endedAt { Text("· \(ended.formatted(date: .omitted, time: .shortened))") }
                }
                .font(.caption).foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let s = entry.durationSeconds, s > 0 { Text(formatMinutes(s / 60)).font(.caption.monospacedDigit()) }
                if let g = entry.filamentUsedGrams, g > 0 { Text(formatGrams(g)).font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted) }
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        if let archiveId = entry.archiveId {
            NavigationLink { ArchiveDetailView(archiveId: archiveId, initial: nil) } label: { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    // MARK: Loading

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            month = next
            selectedDay = nil
        }
    }

    private func load() async {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        loading = true
        defer { loading = false }
        do {
            var all: [PrintLogEntry] = []
            while true {
                let page = try await APIClient.shared.archivePrints(from: f.string(from: interval.start), to: f.string(from: last),
                                                                    printerId: printerId ?? printerFilter, limit: 1000, offset: all.count)
                all += page.items
                if page.items.isEmpty || all.count >= page.total { break }
            }
            prints = all
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}
