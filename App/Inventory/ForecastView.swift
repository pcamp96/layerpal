import SwiftUI

/// Reorder forecast and shopping list. Each filament (material, brand, color) shows how much is left,
/// how fast it is used and when it runs out. Reading needs inventory:read or inventory:forecast_read;
/// lead times and the shopping list need inventory:forecast_write or inventory:update.
/// No navigation stack of its own.
struct ForecastView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var forecasts: [SkuForecast] = []
    @State private var shopping: [ShoppingItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var detail: SkuForecast?
    @State private var confirmClear = false
    @State private var onlyAlerts = false

    private var canRead: Bool { farm.can("inventory:read") || farm.can("inventory:forecast_read") }
    private var canWrite: Bool { farm.can("inventory:forecast_write") || farm.can("inventory:update") }

    private var shown: [SkuForecast] {
        let list = onlyAlerts ? forecasts.filter { $0.stockBreak || $0.reorder } : forecasts
        return list.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.daysRemaining ?? .greatestFiniteMagnitude) < (b.daysRemaining ?? .greatestFiniteMagnitude)
        }
    }

    private func rank(_ f: SkuForecast) -> Int { f.stockBreak ? 0 : (f.reorder ? 1 : 2) }

    var body: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            if !canRead {
                Label("Your account can't view the forecast.", systemImage: "lock").font(.footnote).listRowBackground(Color.bgCard)
            }
            Section {
                ForEach(shown) { forecast in
                    Button { detail = forecast } label: { row(forecast) }.listRowBackground(Color.bgCard)
                }
                if loaded, shown.isEmpty, error == nil {
                    ContentUnavailableView(onlyAlerts ? "Nothing to reorder" : "No filament to forecast", systemImage: "chart.line.downtrend.xyaxis",
                                           description: Text(onlyAlerts ? "No filament has reached its reorder point." : "Spools need to be in inventory."))
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Filament")
            } footer: {
                Text("The rate comes from your usage history over the last weeks, and needs at least two days of prints. Filament without enough history shows no estimate.")
            }
            Section {
                ForEach(shopping) { item in shoppingRow(item) }
                if loaded, shopping.isEmpty { Text("Nothing on the list.").font(.footnote).foregroundStyle(Color.textMuted) }
            } header: { Text("Shopping list") }
        }
        .farmBackground()
        .navigationTitle("Forecast")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Only items needing attention", isOn: $onlyAlerts)
                    if canWrite, !shopping.isEmpty {
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear shopping list", systemImage: "trash") }
                    }
                } label: { Image(systemName: onlyAlerts ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle") }
                    .accessibilityLabel("Forecast options")
            }
        }
        .overlay { if !loaded, error == nil { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $detail) { forecast in
            SkuSettingsSheet(forecast: forecast, canWrite: canWrite) { await load() }
        }
        .confirmationDialog("Clear the shopping list?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear list", role: .destructive) { clear() }
        } message: { Text("Every item is removed.") }
    }

    private func row(_ f: SkuForecast) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                if f.stockBreak { Pill(text: "Will run out", tint: .statusError, systemImage: "exclamationmark.triangle") }
                else if f.reorder { Pill(text: "Reorder", tint: .statusWarning, systemImage: "cart") }
                else if f.settings?.alertsSnoozed == true { Pill(text: "Snoozed", systemImage: "bell.slash") }
            }
            HStack(spacing: 10) {
                Text("\(formatGrams(f.remainingG)) in \(f.spoolCount) spool\(f.spoolCount == 1 ? "" : "s")")
                if let rate = f.dailyRateG { Text(String(format: "%.1f g/day", rate)) }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Color.textSecondary)
            if let days = f.daysRemaining, let date = f.projectedEmpty {
                Text("About \(Int(days.rounded())) days left, empty around \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(f.stockBreak ? Color.statusError : Color.textMuted)
            } else if f.dailyRateG == nil {
                Text("Not enough usage history yet").font(.caption).foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func shoppingRow(_ item: ShoppingItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline)
                Text("\(item.quantitySpools) spool\(item.quantitySpools == 1 ? "" : "s")" + ((item.note ?? "").isEmpty ? "" : " · \(item.note ?? "")"))
                    .font(.caption).foregroundStyle(Color.textSecondary)
            }
            Spacer()
            if canWrite {
                Menu {
                    ForEach(["pending", "purchased", "received"], id: \.self) { status in
                        Button { setStatus(item, status) } label: { Label(status.capitalized, systemImage: item.status == status ? "checkmark" : "circle") }
                    }
                    Button(role: .destructive) { remove(item) } label: { Label("Remove", systemImage: "trash") }
                } label: { Pill(text: item.status.capitalized, tint: item.status == "pending" ? .statusWarning : .accentTeal) }
                    .accessibilityLabel("Status of \(item.title): \(item.status)")
            } else {
                Pill(text: item.status.capitalized, tint: item.status == "pending" ? .statusWarning : .accentTeal)
            }
        }
        .listRowBackground(Color.bgCard)
        .accessibilityElement(children: .combine)
    }

    // MARK: Loading and actions

    private func load() async {
        guard canRead else { loaded = true; return }
        do {
            let spoolman = (try? await APIClient.shared.inventorySettings()).map { $0.spoolmanEnabled == true && !($0.spoolmanUrl ?? "").isEmpty } ?? false
            async let spools = APIClient.shared.inventorySpools(includeArchived: false, spoolman: spoolman)
            async let usage = APIClient.shared.allSpoolUsage(limit: 5000, spoolman: spoolman)
            async let settings = APIClient.shared.skuSettings()
            let lead = (try? await APIClient.shared.forecastLeadTimeDays()) ?? 0
            forecasts = ForecastEngine.build(spools: try await spools, usage: try await usage, settings: (try? await settings) ?? [],
                                             globalLeadDays: lead, spoolman: spoolman)
            shopping = (try? await APIClient.shared.shoppingList()) ?? shopping
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
        loaded = true
    }

    private func setStatus(_ item: ShoppingItem, _ status: String) {
        Task {
            do {
                let updated = try await APIClient.shared.setShoppingStatus(item.id, status: status)
                if let i = shopping.firstIndex(where: { $0.id == item.id }) { shopping[i] = updated }
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func remove(_ item: ShoppingItem) {
        Task {
            do {
                try await APIClient.shared.deleteShoppingItem(item.id)
                shopping.removeAll { $0.id == item.id }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func clear() {
        Task {
            do {
                try await APIClient.shared.clearShoppingList()
                shopping = []
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}

/// One filament's reorder settings and the shopping-list button.
struct SkuSettingsSheet: View {
    let forecast: SkuForecast
    let canWrite: Bool
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var leadDays: Int
    @State private var margin: Int
    @State private var unit: String
    @State private var snoozed: Bool
    @State private var quantity = 1
    @State private var note = ""
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?

    init(forecast: SkuForecast, canWrite: Bool, onSaved: @escaping () async -> Void) {
        self.forecast = forecast
        self.canWrite = canWrite
        self.onSaved = onSaved
        _leadDays = State(initialValue: forecast.settings?.leadTimeDays ?? 0)
        _margin = State(initialValue: forecast.settings?.safetyMarginValue ?? 14)
        _unit = State(initialValue: forecast.settings?.safetyMarginUnit ?? "days")
        _snoozed = State(initialValue: forecast.settings?.alertsSnoozed ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(forecast.title).font(.headline)
                    LabeledContent("In stock", value: "\(formatGrams(forecast.remainingG)) of \(formatGrams(forecast.labelG))")
                    if let rate = forecast.dailyRateG { LabeledContent("Used per day", value: String(format: "%.1f g", rate)) }
                    LabeledContent("Reorder point", value: formatGrams(forecast.reorderPointG))
                }
                Section {
                    Stepper("Delivery time: \(leadDays) day\(leadDays == 1 ? "" : "s")", value: $leadDays, in: 0 ... 365)
                    Stepper("Safety margin: \(margin) \(unit)", value: $margin, in: 0 ... 10_000, step: unit == "grams" ? 50 : 1)
                    Picker("Margin in", selection: $unit) {
                        Text("Days").tag("days")
                        Text("Grams").tag("grams")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Snooze alerts", isOn: $snoozed)
                } header: { Text("Reorder settings") } footer: {
                    Text("A delivery time of 0 uses the server's global setting.")
                }
                .disabled(!canWrite)
                if canWrite {
                    Section("Shopping list") {
                        Stepper("Spools: \(quantity)", value: $quantity, in: 1 ... 99)
                        TextField("Note (optional)", text: $note)
                        Button { addToList() } label: { Label("Add to shopping list", systemImage: "cart.badge.plus") }.disabled(saving)
                    }
                }
                if let message { Label(message, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.accentTeal) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            }
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(canWrite ? "Cancel" : "Close") { dismiss() } }
                if canWrite { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving) } }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let settings = SkuSettings(id: forecast.settings?.id, material: forecast.material, subtype: forecast.subtype, brand: forecast.brand,
                                           colorName: forecast.colorName, leadTimeDays: leadDays, safetyMarginValue: margin,
                                           safetyMarginUnit: unit, alertsSnoozed: snoozed)
                _ = try await APIClient.shared.saveSkuSettings(settings)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onSaved()
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }

    private func addToList() {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await APIClient.shared.addShoppingItem(material: forecast.material, subtype: forecast.subtype, brand: forecast.brand,
                                                               colorName: forecast.colorName, quantity: quantity,
                                                               note: note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                message = "Added to the shopping list."
                await onSaved()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = FriendlyError.message(error)
            }
        }
    }
}
