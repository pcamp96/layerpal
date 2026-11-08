import SwiftUI
import UIKit

/// Finance (Bambuddy: Finance page): wallet balance, ledger, cost centers and the electricity price.
/// Bambuddy refuses API keys for cost-center data, so this screen runs on the admin/user sign-in
/// session (`AdminGate`). Personal view needs `cost_centers:read_own`; the all-users view and every
/// write need `cost_centers:read_all`, `:modify` or `:create`. Billing itself is switched on in
/// Bambuddy's settings; with it off the ledger is simply empty.
struct FinanceView: View {
    var body: some View {
        AdminGate(title: "Finance", permission: nil) { FinanceContent() }
    }
}

private enum FinMode: String, CaseIterable, Identifiable {
    case mine = "Personal", all = "All users"
    var id: String { rawValue }
}

private enum FinSheet: Identifiable {
    case createCenter, adjust, manual, price
    case editTransaction(FinTransaction)

    var id: String {
        switch self {
        case .createCenter: "create"
        case .adjust: "adjust"
        case .manual: "manual"
        case .price: "price"
        case let .editTransaction(tx): "edit-\(tx.id)"
        }
    }
}

private struct FinanceContent: View {
    @ObservedObject private var session = AdminSession.shared
    @State private var mode: FinMode = .mine
    @State private var balance: FinBalance?
    @State private var centers: [FinCostCenter] = []
    @State private var transactions: [FinTransaction] = []
    @State private var txTotal = 0
    @State private var users: [FinUser] = []
    @State private var energy: FinEnergySettings?
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var sheet: FinSheet?
    @State private var pendingDelete: FinTransaction?
    @State private var includeInactive = true

    private let pageSize = 50

    private var canOwn: Bool { session.can("cost_centers:read_own") }
    private var canAll: Bool { session.can("cost_centers:read_all") }
    private var canModify: Bool { session.can("cost_centers:modify") }
    private var canCreate: Bool { session.can("cost_centers:create") }
    private var hasAdminView: Bool { canAll || canModify || canCreate }
    private var adminMode: Bool { mode == .all && hasAdminView }
    private var currency: String? { balance?.currency ?? energy?.currency }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError).padding(.horizontal, 4) }
                if hasAdminView {
                    Picker("View", selection: $mode) {
                        ForEach(FinMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in Task { await reload() } }
                }
                if canOwn { balanceCard }
                centersSection
                transactionsSection
                energyCard
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .overlay { if !loaded, error == nil { ProgressView() } }
        .toolbar {
            if canModify || canCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canCreate { Button { sheet = .createCenter } label: { Label("New cost center", systemImage: "building.2") } }
                        if canModify {
                            Button { sheet = .adjust } label: { Label("Adjust a wallet", systemImage: "plusminus.circle") }
                            Button { sheet = .manual } label: { Label("Add manual print charge", systemImage: "printer") }
                        }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Finance actions")
                }
            }
        }
        .sheet(item: $sheet) { item in
            NavigationStack { sheetContent(item) }
        }
        .confirmationDialog("Delete this transaction?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete transaction", role: .destructive) { if let tx = pendingDelete { delete(tx) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bambuddy voids the entry and rebuilds the balances. This can't be undone.")
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: Sections

    private var balanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Personal account balance").font(.footnote).foregroundStyle(Color.textSecondary)
                Text(balance.map { FinMoney.format($0.balance, currency: currency) } ?? "–")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle((balance?.balance ?? 0) < 0 ? Color.statusError : Color.primary)
                Text("Balances track costs. Printing is limited only by the cost center's budget.")
                    .font(.caption).foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var centersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Cost centers", trailing: "\(centers.count)")
            }
            if adminMode {
                Toggle("Show inactive", isOn: $includeInactive)
                    .font(.subheadline).padding(.horizontal, 4)
                    .onChange(of: includeInactive) { _, _ in Task { await reload() } }
            }
            if centers.isEmpty, loaded {
                Card { Text("No cost centers").font(.subheadline).foregroundStyle(Color.textMuted) }
            }
            ForEach(centers) { center in
                if adminMode {
                    NavigationLink { CostCenterDetailView(center: center, users: users, currency: currency) { await reload() } } label: {
                        CostCenterRow(center: center, currency: currency, chevron: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    CostCenterRow(center: center, currency: currency, chevron: false)
                }
            }
        }
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: adminMode ? "Transactions" : "Personal transactions", trailing: txTotal > 0 ? "\(txTotal)" : nil)
            if transactions.isEmpty, loaded {
                Card { Text("No transactions yet").font(.subheadline).foregroundStyle(Color.textMuted) }
            }
            ForEach(transactions) { tx in
                Card { transactionRow(tx) }
            }
            if transactions.count < txTotal {
                Button { Task { await loadMore() } } label: {
                    HStack { Spacer(); if loadingMore { ProgressView() } else { Text("Load more") }; Spacer() }
                }
                .buttonStyle(.bordered)
                .disabled(loadingMore)
            }
        }
    }

    private func transactionRow(_ tx: FinTransaction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tx.symbol)
                .foregroundStyle(tx.amount >= 0 ? Color.accentTeal : Color.statusWarning)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.description?.isEmpty == false ? tx.description! : tx.typeLabel).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Pill(text: tx.typeLabel, tint: .textSecondary)
                    if let archive = tx.printArchiveId { Pill(text: "Print #\(archive)", tint: .statusFinished, systemImage: "printer") }
                }
                Text(detailLine(tx)).font(.caption).foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(FinMoney.format(tx.amount, currency: currency, signed: true))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tx.amount >= 0 ? Color.accentTeal : Color.primary)
                if let after = tx.balanceAfter {
                    Text("Bal \(FinMoney.format(after, currency: currency))").font(.caption2.monospacedDigit()).foregroundStyle(Color.textMuted)
                }
            }
            if canModify {
                Menu {
                    Button { sheet = .editTransaction(tx) } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { pendingDelete = tx } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Color.textSecondary)
                }
                .accessibilityLabel("Transaction actions")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailLine(_ tx: FinTransaction) -> String {
        var parts: [String] = []
        if let date = tx.createdAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let cc = tx.costCenterId { parts.append(centers.first { $0.id == cc }?.name ?? "Cost center #\(cc)") }
        if adminMode, let uid = tx.userId { parts.append(users.first { $0.id == uid }?.username ?? "User #\(uid)") }
        return parts.joined(separator: " · ")
    }

    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Electricity price")
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(energy?.energyCostPerKwh.map { FinMoney.format($0, currency: currency, decimals: 4) + " per kWh" } ?? "Not available")
                            .font(.headline.monospacedDigit())
                        Text("Used for per-print energy cost.").font(.caption).foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    if energy != nil {
                        Button("Update") { sheet = .price }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: FinSheet) -> some View {
        switch item {
        case .createCenter: FinCreateCenterSheet { await reload() }
        case .adjust: FinAdjustSheet(users: users, centers: centers) { await reload() }
        case .manual: FinManualSheet(users: users, centers: centers) { await reload() }
        case .price: FinPriceSheet(current: energy?.energyCostPerKwh, currency: currency) { value in
            energy = FinEnergySettings(currency: energy?.currency, energyCostPerKwh: value)
        }
        case let .editTransaction(tx): FinEditTransactionSheet(tx: tx) { await reload() }
        }
    }

    // MARK: Loading

    private func reload() async {
        error = nil
        let admin = adminMode
        do {
            if canOwn { balance = try? await session.perform { try await APIClient.shared.finBalance(bearer: $0) } }
            if admin {
                centers = try await session.perform { try await APIClient.shared.finCostCenters(includeInactive: includeInactive, bearer: $0) }
            } else {
                centers = (try? await session.perform { try await APIClient.shared.finMyCostCenters(bearer: $0) }) ?? []
            }
            let page: FinTransactionPage
            if admin, canAll {
                page = try await session.perform { try await APIClient.shared.finAllTransactions(limit: pageSize, offset: 0, bearer: $0) }
            } else if canOwn {
                page = try await session.perform { try await APIClient.shared.finMyTransactions(limit: pageSize, offset: 0, bearer: $0) }
            } else {
                page = FinTransactionPage(items: [], total: 0)
            }
            transactions = page.items
            txTotal = page.total
            if hasAdminView, users.isEmpty {
                users = (try? await session.perform { try await APIClient.shared.finUsers(bearer: $0) }) ?? []
            }
            energy = try? await session.perform { try await APIClient.shared.finEnergySettings(bearer: $0) }
        } catch {
            self.error = AdminError.friendly(error)
        }
        loaded = true
    }

    private func loadMore() async {
        loadingMore = true
        defer { loadingMore = false }
        let offset = transactions.count
        do {
            let page: FinTransactionPage
            if adminMode, canAll {
                page = try await session.perform { try await APIClient.shared.finAllTransactions(limit: pageSize, offset: offset, bearer: $0) }
            } else {
                page = try await session.perform { try await APIClient.shared.finMyTransactions(limit: pageSize, offset: offset, bearer: $0) }
            }
            transactions += page.items.filter { new in !transactions.contains { $0.id == new.id } }
            txTotal = page.total
        } catch {
            self.error = AdminError.friendly(error)
        }
    }

    private func delete(_ tx: FinTransaction) {
        pendingDelete = nil
        Task {
            do {
                try await session.perform { try await APIClient.shared.finDeleteTransaction(tx.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await reload()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Cost center row

private struct CostCenterRow: View {
    let center: FinCostCenter
    let currency: String?
    let chevron: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(center.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if center.isPrivate { Pill(text: "Private", tint: .statusFinished, systemImage: "lock.fill") }
                    if !center.isActive { Pill(text: "Inactive", tint: .statusWarning) }
                    if center.canPrint == false { Pill(text: "View only", tint: .textMuted) }
                    Spacer()
                    if chevron { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color.textMuted) }
                }
                HStack {
                    Text("Balance").font(.caption).foregroundStyle(Color.textMuted)
                    Spacer()
                    Text(FinMoney.format(center.totalBalance ?? 0, currency: currency)).font(.subheadline.monospacedDigit())
                }
                if let percent = center.budgetPercent, let limit = center.budgetLimit, let available = center.budgetAvailable {
                    FarmProgressBar(value: percent, tint: percent >= 90 ? .statusError : (percent >= 70 ? .statusWarning : .accentTeal))
                    Text("\(center.budgetKind): \(FinMoney.format(available, currency: currency)) left of \(FinMoney.format(limit, currency: currency))")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                } else {
                    Text("Unlimited").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cost center detail

private struct CostCenterDetailView: View {
    let center: FinCostCenter
    let users: [FinUser]
    let currency: String?
    var onChanged: () async -> Void

    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var detail: FinCostCenterDetail?
    @State private var error: String?
    @State private var showBudget = false
    @State private var showRename = false
    @State private var showAddMember = false
    @State private var confirmDelete = false
    @State private var pendingRemove: FinMember?

    private var canModify: Bool { session.can("cost_centers:modify") }
    private var current: FinCostCenter { detail?.center ?? center }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
                CostCenterRow(center: current, currency: currency, chevron: false)
                if canModify { actions }
                SectionHeader(title: "Members", trailing: current.isPrivate ? "Owner only" : "\(detail?.members.count ?? 0)")
                if current.isPrivate {
                    Card {
                        Text(ownerLine).font(.subheadline)
                        Text("Private cost centers belong to one user and can't have members.").font(.caption).foregroundStyle(Color.textMuted)
                    }
                } else if let members = detail?.members {
                    if members.isEmpty { Card { Text("No members yet").font(.subheadline).foregroundStyle(Color.textMuted) } }
                    ForEach(members) { member in
                        Card { memberRow(member) }
                    }
                }
            }
            .padding()
        }
        .background(Color.bgPrimary)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showBudget) {
            NavigationStack { FinBudgetSheet(center: current) { await load(); await onChanged() } }
        }
        .sheet(isPresented: $showRename) {
            NavigationStack { FinRenameSheet(center: current) { await load(); await onChanged() } }
        }
        .sheet(isPresented: $showAddMember) {
            NavigationStack {
                FinAddMemberSheet(centerId: center.id, users: users.filter { u in !(detail?.members.contains { $0.userId == u.id } ?? false) }) {
                    await load()
                }
            }
        }
        .confirmationDialog("Delete \(current.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete cost center", role: .destructive) { deleteCenter() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Members lose access to it. Bambuddy may refuse if it still has history.")
        }
        .confirmationDialog("Remove \(name(of: pendingRemove?.userId))?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove member", role: .destructive) { if let m = pendingRemove { remove(m) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var ownerLine: String { "Owner: " + name(of: current.ownerUserId) }

    private func name(of userId: Int?) -> String {
        guard let userId else { return "deleted user" }
        return users.first { $0.id == userId }?.username ?? "User #\(userId)"
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button { showBudget = true } label: { Label("Edit budget", systemImage: "gauge.with.dots.needle.50percent").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            if !current.isPrivate {
                Button { showRename = true } label: { Label("Rename or deactivate", systemImage: "pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { showAddMember = true } label: { Label("Add member", systemImage: "person.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete cost center", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func memberRow(_ member: FinMember) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name(of: member.userId)).font(.subheadline.weight(.semibold))
                Text(member.canPrint ? "Can print" : "View only").font(.caption).foregroundStyle(Color.textMuted)
            }
            Spacer()
            if canModify {
                Toggle("Can print", isOn: Binding(get: { member.canPrint }, set: { setCanPrint(member, $0) }))
                    .labelsHidden()
                Button(role: .destructive) { pendingRemove = member } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove \(name(of: member.userId))")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func load() async {
        do {
            detail = try await session.perform { try await APIClient.shared.finCostCenter(center.id, bearer: $0) }
            error = nil
        } catch { self.error = AdminError.friendly(error) }
    }

    private func setCanPrint(_ member: FinMember, _ value: Bool) {
        Task {
            do {
                try await session.perform { try await APIClient.shared.finSetMember(costCenterId: center.id, userId: member.userId, canPrint: value, bearer: $0) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch { self.error = AdminError.friendly(error) }
            await load()
        }
    }

    private func remove(_ member: FinMember) {
        pendingRemove = nil
        Task {
            do {
                try await session.perform { try await APIClient.shared.finRemoveMember(costCenterId: center.id, userId: member.userId, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } catch { self.error = AdminError.friendly(error) }
            await load()
        }
    }

    private func deleteCenter() {
        Task {
            do {
                try await session.perform { try await APIClient.shared.finDeleteCostCenter(center.id, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                await onChanged()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Forms

private func finParse(_ text: String) -> Double? {
    Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
}

private struct FinFormScaffold<Content: View>: View {
    let title: String
    let confirmTitle: String
    var canSubmit: Bool
    var saving: Bool
    var error: String?
    var onSubmit: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            content
            if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.statusError) } }
        }
        .farmBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button(confirmTitle, action: onSubmit).disabled(!canSubmit) }
            }
        }
    }
}

private struct FinCreateCenterSheet: View {
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = 0 // 0 none, 1 monthly, 2 total
    @State private var amount = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "New cost center", confirmTitle: "Create", canSubmit: valid, saving: saving, error: error, onSubmit: submit) {
            Section { TextField("Name", text: $name) }
            Section {
                Picker("Budget", selection: $kind) {
                    Text("None (unlimited)").tag(0)
                    Text("Monthly").tag(1)
                    Text("Total").tag(2)
                }
                if kind != 0 { TextField("Amount", text: $amount).keyboardType(.decimalPad) }
            } footer: { Text("Without a budget, printing against this cost center is unlimited.") }
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (kind == 0 || (finParse(amount) ?? -1) >= 0)
    }

    private func submit() {
        saving = true
        error = nil
        let value = finParse(amount)
        Task {
            defer { saving = false }
            do {
                try await session.perform {
                    try await APIClient.shared.finCreateCostCenter(name: name.trimmingCharacters(in: .whitespaces),
                                                                   totalBudget: kind == 2 ? value : nil,
                                                                   monthlyBudget: kind == 1 ? value : nil, bearer: $0)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct FinBudgetSheet: View {
    let center: FinCostCenter
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0
    @State private var amount = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Budget", confirmTitle: "Save", canSubmit: kind == 0 || (finParse(amount) ?? -1) >= 0,
                        saving: saving, error: error, onSubmit: submit) {
            Section {
                Picker("Budget", selection: $kind) {
                    Text("None (unlimited)").tag(0)
                    Text("Monthly").tag(1)
                    Text("Total").tag(2)
                }
                if kind != 0 { TextField("Amount", text: $amount).keyboardType(.decimalPad) }
            } footer: { Text("A cost center has either a monthly or a total budget, not both.") }
        }
        .onAppear {
            if let m = center.monthlyBudget { kind = 1; amount = String(m) }
            else if let t = center.totalBudget { kind = 2; amount = String(t) }
        }
    }

    private func submit() {
        saving = true
        error = nil
        let value = finParse(amount)
        Task {
            defer { saving = false }
            do {
                try await session.perform {
                    try await APIClient.shared.finUpdateBudget(center.id, totalBudget: kind == 2 ? value : nil,
                                                               monthlyBudget: kind == 1 ? value : nil, bearer: $0)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct FinRenameSheet: View {
    let center: FinCostCenter
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var active = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Cost center", confirmTitle: "Save", canSubmit: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                        saving: saving, error: error, onSubmit: submit) {
            Section { TextField("Name", text: $name) }
            Section { Toggle("Active", isOn: $active) } footer: { Text("Inactive cost centers can't be picked for new prints.") }
        }
        .onAppear { name = center.name; active = center.isActive }
    }

    private func submit() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await session.perform {
                    try await APIClient.shared.finUpdateCostCenter(center.id, name: name.trimmingCharacters(in: .whitespaces), isActive: active, bearer: $0)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct FinAddMemberSheet: View {
    let centerId: Int
    let users: [FinUser]
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var userId: Int?
    @State private var canPrint = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Add member", confirmTitle: "Add", canSubmit: userId != nil, saving: saving, error: error, onSubmit: submit) {
            Section {
                Picker("User", selection: $userId) {
                    Text("Choose a user").tag(Int?.none)
                    ForEach(users) { Text($0.username).tag(Int?.some($0.id)) }
                }
                Toggle("Can print", isOn: $canPrint)
            }
        }
    }

    private func submit() {
        guard let userId else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await session.perform { try await APIClient.shared.finSetMember(costCenterId: centerId, userId: userId, canPrint: canPrint, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct FinAdjustSheet: View {
    let users: [FinUser]
    let centers: [FinCostCenter]
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var userId: Int?
    @State private var deposit = true
    @State private var amount = ""
    @State private var note = ""
    @State private var centerId: Int?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Adjust wallet", confirmTitle: deposit ? "Deposit" : "Withdraw",
                        canSubmit: userId != nil && (finParse(amount) ?? 0) > 0, saving: saving, error: error, onSubmit: submit) {
            Section {
                Picker("User", selection: $userId) {
                    Text("Choose a user").tag(Int?.none)
                    ForEach(users) { Text($0.username).tag(Int?.some($0.id)) }
                }
                Picker("Type", selection: $deposit) {
                    Text("Deposit").tag(true)
                    Text("Withdraw").tag(false)
                }
                .pickerStyle(.segmented)
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                TextField("Note (optional)", text: $note)
                Picker("Cost center", selection: $centerId) {
                    Text("None").tag(Int?.none)
                    ForEach(centers) { Text($0.name).tag(Int?.some($0.id)) }
                }
            } footer: { Text("Amounts are always positive; the type decides the direction.") }
        }
    }

    private func submit() {
        guard let userId, let value = finParse(amount) else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await session.perform {
                    try await APIClient.shared.finAdjust(userId: userId, deposit: deposit, amount: value,
                                                         description: note.isEmpty ? nil : note, costCenterId: centerId, bearer: $0)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct FinManualSheet: View {
    let users: [FinUser]
    let centers: [FinCostCenter]
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var userId: Int?
    @State private var centerId: Int?
    @State private var amount = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Manual print charge", confirmTitle: "Add",
                        canSubmit: userId != nil && centerId != nil && (finParse(amount) ?? 0) > 0,
                        saving: saving, error: error, onSubmit: submit) {
            Section {
                Picker("User", selection: $userId) {
                    Text("Choose a user").tag(Int?.none)
                    ForEach(users) { Text($0.username).tag(Int?.some($0.id)) }
                }
                Picker("Cost center", selection: $centerId) {
                    Text("Choose a cost center").tag(Int?.none)
                    ForEach(centers.filter(\.isActive)) { Text($0.name).tag(Int?.some($0.id)) }
                }
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                TextField("Description (optional)", text: $note)
            } footer: { Text("Records a charge for a print made outside Bambuddy. It reduces the user's balance.") }
        }
    }

    private func submit() {
        guard let userId, let centerId, let value = finParse(amount) else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await session.perform {
                    try await APIClient.shared.finManualPrint(userId: userId, costCenterId: centerId, amount: value,
                                                              description: note.isEmpty ? nil : note, bearer: $0)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct FinEditTransactionSheet: View {
    let tx: FinTransaction
    var onDone: () async -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Edit transaction", confirmTitle: "Save", canSubmit: finParse(amount) != nil, saving: saving,
                        error: error, onSubmit: submit) {
            Section {
                TextField("Amount", text: $amount).keyboardType(.numbersAndPunctuation)
                TextField("Description", text: $note)
            } footer: { Text("Amounts are signed: charges are negative, deposits positive. Balances are recalculated.") }
        }
        .onAppear { amount = String(tx.amount); note = tx.description ?? "" }
    }

    private func submit() {
        guard let value = finParse(amount) else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await session.perform { try await APIClient.shared.finEditTransaction(tx.id, amount: value, description: note, bearer: $0) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await onDone()
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

/// Electricity price. Tries the signed-in session when it holds `settings:update`, otherwise the app's
/// API key (works only when that key has "Update energy price" enabled; Bambuddy answers 403 if not).
private struct FinPriceSheet: View {
    let current: Double?
    let currency: String?
    var onSaved: (Double) -> Void
    @ObservedObject private var session = AdminSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        FinFormScaffold(title: "Electricity price", confirmTitle: "Save", canSubmit: (finParse(text) ?? -1) >= 0,
                        saving: saving, error: error, onSubmit: submit) {
            Section {
                HStack {
                    Text(FinMoney.symbol(currency)).foregroundStyle(Color.textMuted)
                    TextField("Price per kWh", text: $text).keyboardType(.decimalPad)
                }
            } footer: {
                Text("Price per kWh in \(currency ?? "your currency"). Free hours are fine: use 0. If this fails with 403, turn on \"Update energy price\" for LayerPal's API key or sign in as an admin.")
            }
        }
        .onAppear { if let current { text = String(current) } }
    }

    private func submit() {
        guard let value = finParse(text) else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if session.isSignedIn, session.can("settings:update") {
                    try await session.perform { try await APIClient.shared.finSetElectricityPrice(value, bearer: $0) }
                } else {
                    try await APIClient.shared.finSetElectricityPrice(value, bearer: nil)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onSaved(value)
                dismiss()
            } catch {
                self.error = AdminError.friendly(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
