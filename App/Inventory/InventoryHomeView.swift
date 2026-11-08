import SwiftUI

/// Color chip for a spool: the base color, or a gradient when the spool has extra stops.
struct SpoolSwatch: View {
    let colors: [Color]
    var size: CGFloat = 34

    var body: some View {
        Group {
            if colors.count > 1 {
                Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Circle().fill(colors.first ?? Color.bgRaised)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.hairline, lineWidth: 0.75))
        .accessibilityHidden(true)
    }
}

/// Inventory: every spool with search, filters, sort and a "Running low" group.
/// Pushed from the More tab, so it has no navigation stack of its own.
struct InventoryHomeView: View {
    @EnvironmentObject private var farm: FarmStore
    @StateObject private var store = InventoryStore()

    enum Sort: String, CaseIterable, Identifiable {
        case remaining = "Remaining (low first)"
        case recent = "Recently used"
        case name = "Name"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var material: String?
    @State private var brand: String?
    @State private var lowOnly = false
    @State private var showArchived = false
    @State private var sort = Sort.remaining
    @State private var creating = false
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var showLabels = false
    @State private var showImport = false
    @State private var showBulkLocation = false
    @State private var bulkConfirm: String?
    @State private var exportFile: URL?
    @State private var working = false
    @State private var notice: String?

    private var threshold: Double { store.lowStockThreshold }

    private var materials: [String] { Array(Set(store.spools.compactMap { $0.material }.filter { !$0.isEmpty })).sorted() }
    private var brands: [String] { Array(Set(store.spools.compactMap { $0.brand }.filter { !$0.isEmpty })).sorted() }

    private var filtersActive: Bool { material != nil || brand != nil || lowOnly }

    private var visible: [Spool] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = store.spools.filter { s in
            if !showArchived, s.isArchived { return false }
            if let material, s.material != material { return false }
            if let brand, s.brand != brand { return false }
            if lowOnly, !s.isLow(globalThreshold: threshold) { return false }
            guard !q.isEmpty else { return true }
            let haystack = [s.brand, s.material, s.subtype, s.colorName, s.category, s.storageLocation, s.note].compactMap { $0 }.joined(separator: " ")
            return haystack.lowercased().contains(q) || "#\(s.id)".contains(q)
        }
        return list.sorted(by: order)
    }

    private func order(_ a: Spool, _ b: Spool) -> Bool {
        switch sort {
        case .remaining:
            if a.remainingPercent != b.remainingPercent { return a.remainingPercent < b.remainingPercent }
        case .recent:
            if a.lastUsed != b.lastUsed { return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast) }
        case .name:
            break
        }
        return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }

    var body: some View {
        let list = visible
        let low = list.filter { $0.isLow(globalThreshold: threshold) }
        let rest = list.filter { !$0.isLow(globalThreshold: threshold) }
        List {
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal).listRowBackground(Color.bgCard) }
            if selecting {
                Label(selected.isEmpty ? "Select spools to label, archive, move or delete" : "\(selected.count) selected", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.bgCard)
            }
            if store.spoolman {
                Label("Spoolman mode: spools come from your Spoolman server.", systemImage: "link")
                    .font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.bgCard)
            }
            if !store.canWrite, store.loaded {
                Label("Read-only: your account can't change inventory.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.bgCard)
            }
            if !list.isEmpty { summary(list) }
            if !low.isEmpty {
                Section("Running low (\(low.count))") { rows(low) }
            }
            if !rest.isEmpty {
                Section(low.isEmpty ? "Spools" : "Everything else") { rows(rest) }
            }
        }
        .farmBackground()
        .navigationTitle("Inventory")
        .searchable(text: $search, prompt: "Material, brand, color")
        .overlay {
            if !store.loaded, store.error == nil {
                ProgressView()
            } else if store.loaded, list.isEmpty, store.error == nil {
                ContentUnavailableView(store.spools.isEmpty ? "No spools" : "No matches",
                                       systemImage: "cylinder.split.1x2",
                                       description: Text(store.spools.isEmpty ? "Add a spool with the plus button." : "Try clearing the search or filters."))
            }
        }
        .toolbar {
            if selecting {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { selecting = false; selected = [] } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selected.count == list.count ? "Select none" : "Select all") {
                        selected = selected.count == list.count ? [] : Set(list.map(\.id))
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) { bulkBar }
            } else {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) { toolsMenu }
                if store.canWrite {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { creating = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add spool")
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            SpoolFormView(store: store, editing: nil) { _ in }
        }
        .sheet(isPresented: $showLabels) { LabelPrintSheet(spoolIds: Array(selected), spoolman: store.spoolman) }
        .sheet(isPresented: $showImport) { CSVImportSheet { Task { await store.load(includeArchived: showArchived) } } }
        .sheet(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } })) {
            if let exportFile { AdvShareSheet(items: [exportFile]) }
        }
        .sheet(isPresented: $showBulkLocation) {
            BulkLocationSheet(count: selected.count) { name in
                try await store.bulkSetLocation(name, ids: Array(selected))
                InventoryHaptics.success()
                notice = name.map { "Moved \(selected.count) spools to \($0)." } ?? "Cleared the location of \(selected.count) spools."
                selected = []
                selecting = false
            }
        }
        .confirmationDialog(bulkTitle, isPresented: Binding(get: { bulkConfirm != nil }, set: { if !$0 { bulkConfirm = nil } }), titleVisibility: .visible) {
            if let action = bulkConfirm {
                Button(action == "delete" ? "Delete \(selected.count)" : action.capitalized + " \(selected.count)", role: action == "delete" ? .destructive : nil) {
                    runBulk(action)
                }
            }
        } message: { Text(bulkMessage) }
        .task { await store.load(includeArchived: showArchived) }
        .refreshable { await store.load(includeArchived: showArchived) }
        .onChange(of: showArchived) { _, on in Task { await store.load(includeArchived: on) } }
        .onChange(of: farm.permissions) { _, _ in Task { await store.load(includeArchived: showArchived) } }
    }

    private func rows(_ spools: [Spool]) -> some View {
        ForEach(spools) { spool in
            if selecting {
                Button {
                    if selected.contains(spool.id) { selected.remove(spool.id) } else { selected.insert(spool.id) }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack {
                        Image(systemName: selected.contains(spool.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(spool.id) ? Color.accentTeal : Color.textMuted)
                        InventorySpoolRow(spool: spool, threshold: threshold, slots: store.slots(for: spool.id))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(spool.id) ? .isSelected : [])
            } else {
                NavigationLink {
                    SpoolDetailView(spoolId: spool.id, store: store)
                } label: {
                    InventorySpoolRow(spool: spool, threshold: threshold, slots: store.slots(for: spool.id))
                }
            }
        }
    }

    // MARK: Tools, export and bulk actions

    private var canViewForecast: Bool { farm.can("inventory:read") || farm.can("inventory:forecast_read") }

    private var toolsMenu: some View {
        Menu {
            if canViewForecast {
                NavigationLink { ForecastView() } label: { Label("Forecast and shopping list", systemImage: "chart.line.downtrend.xyaxis") }
            }
            if farm.can("inventory:read") {
                NavigationLink { SuppliersView() } label: { Label("Suppliers", systemImage: "shippingbox") }
                NavigationLink { LabelTemplatesView() } label: { Label("Label sheets", systemImage: "rectangle.grid.3x2") }
                NavigationLink { SpoolCatalogView() } label: { Label("Spool catalog", systemImage: "circle.dashed") }
            }
            if farm.can("filaments:read") {
                NavigationLink { FilamentCatalogView() } label: { Label("Filament catalog", systemImage: "swatchpalette") }
            }
            if store.canRead, !store.spoolman {
                Divider()
                Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                if store.canWrite { Button { showImport = true } label: { Label("Import CSV", systemImage: "square.and.arrow.down") } }
            }
            if store.canRead {
                Divider()
                Button { selecting = true; selected = [] } label: { Label("Select spools", systemImage: "checkmark.circle") }
            }
        } label: { Image(systemName: working ? "hourglass" : "ellipsis.circle") }
            .accessibilityLabel("Inventory tools")
    }

    @ViewBuilder private var bulkBar: some View {
        Button { showLabels = true } label: { Label("Labels", systemImage: "printer") }
            .disabled(selected.isEmpty || !farm.can("inventory:read"))
        if store.canWrite {
            Spacer()
            Button { showBulkLocation = true } label: { Label("Location", systemImage: "mappin.and.ellipse") }.disabled(selected.isEmpty)
            Spacer()
            Button { bulkConfirm = showArchived && selectedAllArchived ? "restore" : "archive" } label: {
                Label(showArchived && selectedAllArchived ? "Restore" : "Archive", systemImage: showArchived && selectedAllArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .disabled(selected.isEmpty)
            Spacer()
            Button(role: .destructive) { bulkConfirm = "delete" } label: { Label("Delete", systemImage: "trash") }.disabled(selected.isEmpty)
        }
    }

    private var selectedAllArchived: Bool {
        !selected.isEmpty && selected.allSatisfy { id in store.spool(id)?.isArchived == true }
    }

    private var bulkTitle: String {
        switch bulkConfirm {
        case "delete": "Delete \(selected.count) spool\(selected.count == 1 ? "" : "s")?"
        case "restore": "Restore \(selected.count) spool\(selected.count == 1 ? "" : "s")?"
        default: "Archive \(selected.count) spool\(selected.count == 1 ? "" : "s")?"
        }
    }

    private var bulkMessage: String {
        switch bulkConfirm {
        case "delete": "This can't be undone. Their printer slots are freed. Archive them instead to keep the history."
        case "restore": "They go back into active inventory."
        default: "They leave active inventory and are taken out of any printer slot."
        }
    }

    private func runBulk(_ action: String) {
        let ids = Array(selected)
        working = true
        Task {
            defer { working = false }
            do {
                try await store.bulk(action, ids: ids)
                InventoryHaptics.success()
                notice = "\(action == "delete" ? "Deleted" : (action == "restore" ? "Restored" : "Archived")) \(ids.count) spool\(ids.count == 1 ? "" : "s")."
                selected = []
                selecting = false
            } catch {
                InventoryHaptics.error()
                store.error = FriendlyError.message(error)
            }
        }
    }

    private func exportCSV() {
        working = true
        Task {
            defer { working = false }
            do {
                exportFile = try await APIClient.shared.exportSpoolsCSV()
                store.error = nil
            } catch {
                InventoryHaptics.error()
                store.error = FriendlyError.message(error)
            }
        }
    }

    private func summary(_ list: [Spool]) -> some View {
        let active = list.filter { !$0.isArchived }
        let grams = active.reduce(0) { $0 + $1.remainingGrams }
        return HStack(spacing: 16) {
            stat("\(active.count)", "spools")
            stat(formatGrams(grams), "left")
            stat("\(active.filter { $0.isLow(globalThreshold: threshold) }.count)", "low")
            Spacer()
        }
        .listRowBackground(Color.bgCard)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(Color.textMuted)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            Section("Filter") {
                Picker("Material", selection: $material) {
                    Text("All materials").tag(String?.none)
                    ForEach(materials, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Brand", selection: $brand) {
                    Text("All brands").tag(String?.none)
                    ForEach(brands, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Toggle("Low stock only", isOn: $lowOnly)
                Toggle("Show archived", isOn: $showArchived)
            }
            if filtersActive {
                Button("Clear filters", role: .destructive) { material = nil; brand = nil; lowOnly = false }
            }
        } label: {
            Image(systemName: filtersActive || showArchived ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Sort and filter")
    }
}

struct InventorySpoolRow: View {
    let spool: Spool
    let threshold: Double
    let slots: [SlotAssignment]

    private var low: Bool { spool.isLow(globalThreshold: threshold) }
    private var tint: Color { spool.remainingGrams <= 0 ? .statusError : (low ? .statusWarning : .accentTeal) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpoolSwatch(colors: spool.swatchColors)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(spool.displayName).font(.subheadline.weight(.medium))
                    if spool.isArchived { Pill(text: "Archived") }
                }
                if let sub = subtitle { Text(sub).font(.caption).foregroundStyle(Color.textMuted) }
                FarmProgressBar(value: spool.remainingPercent, tint: tint, height: 5)
                HStack {
                    Text("\(formatGrams(spool.remainingGrams)) of \(formatGrams(spool.labelGrams))")
                        .font(.caption.monospacedDigit()).foregroundStyle(Color.textSecondary)
                    if low { Pill(text: "Low", tint: .statusWarning) }
                }
                if !slots.isEmpty {
                    Label(slots.map(\.fullName).joined(separator: ", "), systemImage: "printer.fill")
                        .font(.caption).foregroundStyle(Color.accentTeal)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(spool.remainingPercent)) percent left" + (slots.isEmpty ? "" : ", loaded in \(slots.map(\.fullName).joined(separator: ", "))"))
    }

    private var subtitle: String? {
        let parts = [spool.colorName, spool.category].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
