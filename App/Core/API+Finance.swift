import Foundation

/// Finance endpoints (/finance, Bambuddy 1.3.0).
/// The server refuses cost-center permissions for API keys:
/// callers pass the signed-in user's JWT as `bearer`. The one exception is
/// `GET /finance/cost-centers/mine`, which accepts a key that may queue.
/// Settings reads (`GET /settings/`, `settings:read`) work with a key.
extension APIClient {
    // MARK: Wallet (cost_centers:read_own)

    /// GET /finance/me/balance
    func finBalance(bearer: String?) async throws -> FinBalance { try await get("finance/me/balance", bearer: bearer) }

    /// GET /finance/me/transactions?limit=&offset= (cost_centers:read_own)
    func finMyTransactions(limit: Int, offset: Int, bearer: String?) async throws -> FinTransactionPage {
        try await get("finance/me/transactions", query: finPageQuery(limit, offset), bearer: bearer)
    }

    /// GET /finance/transactions?limit=&offset=&user_id= (cost_centers:read_all)
    func finAllTransactions(limit: Int, offset: Int, userId: Int? = nil, bearer: String?) async throws -> FinTransactionPage {
        var query = finPageQuery(limit, offset)
        if let userId { query.append(URLQueryItem(name: "user_id", value: String(userId))) }
        return try await get("finance/transactions", query: query, bearer: bearer)
    }

    private func finPageQuery(_ limit: Int, _ offset: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
    }

    // MARK: Cost centers

    /// GET /finance/cost-centers/mine (private + assigned centers)
    func finMyCostCenters(bearer: String?) async throws -> [FinCostCenter] { try await get("finance/cost-centers/mine", bearer: bearer) }

    /// GET /finance/cost-centers?include_inactive= (any of cost_centers:read_all / modify / create)
    func finCostCenters(includeInactive: Bool, bearer: String?) async throws -> [FinCostCenter] {
        try await get("finance/cost-centers",
                      query: [URLQueryItem(name: "include_inactive", value: includeInactive ? "true" : "false")], bearer: bearer)
    }

    /// GET /finance/cost-centers/{id}: summary plus members.
    func finCostCenter(_ id: Int, bearer: String?) async throws -> FinCostCenterDetail { try await get("finance/cost-centers/\(id)", bearer: bearer) }

    /// POST /finance/cost-centers (cost_centers:create). One budget at most: monthly wins on the server.
    func finCreateCostCenter(name: String, totalBudget: Double?, monthlyBudget: Double?, bearer: String?) async throws {
        struct Body: Encodable { let name: String; let totalBudget: Double?; let monthlyBudget: Double? }
        _ = try await request("finance/cost-centers", method: "POST",
                              body: Body(name: name, totalBudget: totalBudget, monthlyBudget: monthlyBudget), bearer: bearer)
    }

    /// PATCH /finance/cost-centers/{id} (cost_centers:modify). Private centers answer 400.
    func finUpdateCostCenter(_ id: Int, name: String?, isActive: Bool?, bearer: String?) async throws {
        struct Body: Encodable { let name: String?; let isActive: Bool? }
        _ = try await request("finance/cost-centers/\(id)", method: "PATCH", body: Body(name: name, isActive: isActive), bearer: bearer)
    }

    /// PATCH /finance/cost-centers/{id}/budgets (cost_centers:modify). Both nil removes the budget.
    func finUpdateBudget(_ id: Int, totalBudget: Double?, monthlyBudget: Double?, bearer: String?) async throws {
        struct Body: Encodable { let totalBudget: Double?; let monthlyBudget: Double? }
        _ = try await request("finance/cost-centers/\(id)/budgets", method: "PATCH",
                              body: Body(totalBudget: totalBudget, monthlyBudget: monthlyBudget), bearer: bearer)
    }

    /// DELETE /finance/cost-centers/{id} (cost_centers:modify)
    func finDeleteCostCenter(_ id: Int, bearer: String?) async throws {
        _ = try await request("finance/cost-centers/\(id)", method: "DELETE", bearer: bearer)
    }

    /// POST /finance/cost-centers/{id}/members (cost_centers:modify): add or change a member.
    func finSetMember(costCenterId: Int, userId: Int, canPrint: Bool, bearer: String?) async throws {
        struct Body: Encodable { let userId: Int; let canPrint: Bool }
        _ = try await request("finance/cost-centers/\(costCenterId)/members", method: "POST",
                              body: Body(userId: userId, canPrint: canPrint), bearer: bearer)
    }

    /// DELETE /finance/cost-centers/{id}/members/{user_id} (cost_centers:modify)
    func finRemoveMember(costCenterId: Int, userId: Int, bearer: String?) async throws {
        _ = try await request("finance/cost-centers/\(costCenterId)/members/\(userId)", method: "DELETE", bearer: bearer)
    }

    // MARK: Adjustments (cost_centers:modify)

    /// POST /finance/users/{id}/deposit or /withdraw. `amount` must be > 0.
    func finAdjust(userId: Int, deposit: Bool, amount: Double, description: String?, costCenterId: Int?, bearer: String?) async throws {
        struct Body: Encodable { let amount: Double; let description: String?; let costCenterId: Int? }
        _ = try await request("finance/users/\(userId)/\(deposit ? "deposit" : "withdraw")", method: "POST",
                              body: Body(amount: amount, description: description, costCenterId: costCenterId), bearer: bearer)
    }

    /// POST /finance/transactions/manual: a charge against a cost center (server forces a negative amount).
    func finManualPrint(userId: Int, costCenterId: Int, amount: Double, description: String?, bearer: String?) async throws {
        struct Body: Encodable { let userId: Int; let costCenterId: Int; let amount: Double; let description: String? }
        _ = try await request("finance/transactions/manual", method: "POST",
                              body: Body(userId: userId, costCenterId: costCenterId, amount: amount, description: description), bearer: bearer)
    }

    /// PATCH /finance/transactions/{id}: the ledger is rebuilt afterwards.
    func finEditTransaction(_ id: Int, amount: Double?, description: String?, bearer: String?) async throws {
        struct Body: Encodable { let amount: Double?; let description: String? }
        _ = try await request("finance/transactions/\(id)", method: "PATCH", body: Body(amount: amount, description: description), bearer: bearer)
    }

    /// DELETE /finance/transactions/{id}: voids it and rebuilds the ledger.
    func finDeleteTransaction(_ id: Int, bearer: String?) async throws {
        _ = try await request("finance/transactions/\(id)", method: "DELETE", bearer: bearer)
    }

    // MARK: Lookups

    /// GET /users/slim: id + username (users:read_slim or users:read; admin session).
    func finUsers(bearer: String?) async throws -> [FinUser] { try await get("users/slim", bearer: bearer) }

    // MARK: Energy price

    /// GET /settings/ (settings:read; an API key with can_read_status is accepted).
    /// Only currency and price are read; secrets in the payload are ignored.
    func finEnergySettings(bearer: String?) async throws -> FinEnergySettings { try await get("settings/", bearer: bearer) }

    /// POST /settings/electricity-price {energy_cost_per_kwh}. An API key needs `can_update_energy_cost`
    /// (not visible in /auth/me, so the server's 403 is the only test); a JWT needs settings:update.
    func finSetElectricityPrice(_ perKWh: Double, bearer: String?) async throws {
        struct Body: Encodable { let energyCostPerKwh: Double }
        _ = try await request("settings/electricity-price", method: "POST", body: Body(energyCostPerKwh: perKWh), bearer: bearer)
    }
}
