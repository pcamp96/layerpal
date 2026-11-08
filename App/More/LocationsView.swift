import SwiftUI
import UIKit

/// Printer locations with their printer counts. Everyone who can read printers can look. Changing
/// them (create, rename, delete, move printers) needs `printers:update`, which Bambuddy refuses for
/// API keys, so those calls use the admin session and ask the user to sign in when it's missing.
/// Moves into or out of a location granted to a group are admin-only; the server's message is shown.
struct LocationsView: View {
    @EnvironmentObject private var farm: FarmStore
    @ObservedObject private var session = AdminSession.shared
    @StateObject private var runner = AdminActionRunner()
    @State private var locations: [FarmLocation] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: FarmLocation?
    @State private var renameTo = ""
    @State private var pendingDelete: FarmLocation?

    /// Shown unless the signed-in account is known to lack printers:update.
    private var canEdit: Bool { !session.isSignedIn || session.can("printers:update") }
    private var unassigned: Int { farm.printers.filter { ($0.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let message = runner.error { Text(message).font(.footnote).foregroundStyle(Color.statusError) }
            Section {
                ForEach(locations) { location in
                    NavigationLink { LocationDetail(name: location.name, canEdit: canEdit) } label: {
                        row(location.name, count: location.printerCount)
                    }
                    .swipeActions(edge: .trailing) {
                        if canEdit {
                            Button(role: .destructive) { pendingDelete = location } label: { Label("Delete", systemImage: "trash") }
                            Button { renameTo = location.name; renaming = location } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.statusFinished)
                        }
                    }
                    .contextMenu {
                        if canEdit {
                            Button { renameTo = location.name; renaming = location } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = location } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                if unassigned > 0 {
                    NavigationLink { LocationDetail(name: nil, canEdit: canEdit) } label: {
                        row("No location", count: unassigned)
                    }
                }
            }
        }
        .farmBackground()
        .navigationTitle("Locations")
        .overlay {
            if loaded, locations.isEmpty, unassigned == 0, error == nil {
                ContentUnavailableView("No locations", systemImage: "mappin.slash")
            } else if !loaded, error == nil {
                ProgressView()
            }
        }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New location")
                }
            }
        }
        .alert("New location", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isSignedIn || session.authEnabled == false
                ? "Then move printers into it from its page."
                : "You'll be asked to sign in to Bambuddy. Then move printers into it from its page.")
        }
        .alert("Rename location", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo)
            Button("Rename") { if let target = renaming { rename(target) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its printers and any queue jobs aimed at it move to the new name.")
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "location")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete location", role: .destructive) { if let target = pendingDelete { delete(target) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(pendingDelete?.printerCount ?? 0) printers are kept but end up with no location. Queued jobs aimed at it stay as they are.")
        }
        .adminActions(runner)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: farm.printers) { _, _ in Task { await load() } }
    }

    private func row(_ name: String, count: Int) -> some View {
        HStack {
            IconLabel(title: name, symbol: "mappin.and.ellipse", tint: .statusFinished)
            Spacer()
            Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(count) printers")
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        runner.run {
            try await AdminSession.shared.perform { try await APIClient.shared.createPrinterLocation(name: name, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        }
    }

    private func rename(_ target: FarmLocation) {
        let name = renameTo.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != target.name else { return }
        runner.run {
            try await AdminSession.shared.perform { try await APIClient.shared.renamePrinterLocation(target.name, to: name, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await farm.refresh()
            await load()
        }
    }

    private func delete(_ target: FarmLocation) {
        pendingDelete = nil
        runner.run {
            _ = try await AdminSession.shared.perform { try await APIClient.shared.deletePrinterLocations([target.name], bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            await farm.refresh()
            await load()
        }
    }

    private func load() async {
        do {
            locations = try await APIClient.shared.printerLocations()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// One location's printers, with moving in (sheet) and out (swipe) for editors.
private struct LocationDetail: View {
    let name: String? // nil = printers with no location
    let canEdit: Bool
    @EnvironmentObject private var farm: FarmStore
    @StateObject private var runner = AdminActionRunner()
    @State private var picking = false

    private func here(_ printer: Printer) -> Bool {
        let loc = (printer.location ?? "").trimmingCharacters(in: .whitespaces)
        return name.map { loc == $0 } ?? loc.isEmpty
    }

    private var members: [Printer] {
        farm.printers.filter(here).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if let message = runner.error { Text(message).font(.footnote).foregroundStyle(Color.statusError) }
            Section("\(members.count) printers") {
                ForEach(members) { printer in
                    HStack(spacing: 10) {
                        StateDot(state: farm.state(printer.id)).frame(width: 14)
                        Text(printer.name).font(.subheadline)
                        Text(printer.displayModel).font(.caption).foregroundStyle(Color.textMuted)
                        Spacer()
                        if printer.isActive == false { Pill(text: "Inactive") }
                    }
                    .swipeActions {
                        if canEdit, name != nil {
                            Button("Remove") { move([printer.id], to: nil) }.tint(.statusWarning)
                        }
                    }
                }
            }
        }
        .farmBackground()
        .navigationTitle(name ?? "No location")
        .overlay { if members.isEmpty { ContentUnavailableView("No printers here", systemImage: "printer") } }
        .toolbar {
            if canEdit, let _ = name {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { picking = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add printers")
                }
            }
        }
        .sheet(isPresented: $picking) {
            if let name {
                PrinterPicker(location: name) { ids in move(ids, to: name) }
            }
        }
        .adminActions(runner)
    }

    private func move(_ ids: [Int], to location: String?) {
        guard !ids.isEmpty else { return }
        runner.run {
            try await AdminSession.shared.perform { try await APIClient.shared.assignPrinters(ids, to: location, bearer: $0) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await farm.refresh()
        }
    }
}

private struct PrinterPicker: View {
    let location: String
    let onMove: ([Int]) -> Void
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<Int>()
    @State private var search = ""

    private var candidates: [Printer] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return farm.printers
            .filter { ($0.location ?? "") != location }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.location ?? "").lowercased().contains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { printer in
                Button {
                    if selected.contains(printer.id) { selected.remove(printer.id) } else { selected.insert(printer.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(printer.name).foregroundStyle(.primary)
                            if let current = printer.location, !current.isEmpty {
                                Text("Now in \(current)").font(.caption).foregroundStyle(Color.textMuted)
                            }
                        }
                        Spacer()
                        Image(systemName: selected.contains(printer.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(printer.id) ? Color.accentTeal : Color.textMuted)
                    }
                }
                .accessibilityAddTraits(selected.contains(printer.id) ? .isSelected : [])
            }
            .farmBackground()
            .searchable(text: $search, prompt: "Printers")
            .navigationTitle("Move to \(location)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move \(selected.count)") { onMove(Array(selected)); dismiss() }.disabled(selected.isEmpty)
                }
            }
        }
    }
}
