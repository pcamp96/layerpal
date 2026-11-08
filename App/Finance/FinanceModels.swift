import Foundation

struct FinBalance: Decodable {
    let userId: Int?
    let balance: Double
    let currency: String?
}

struct FinTransaction: Decodable, Identifiable, Hashable {
    let id: Int
    let userId: Int?
    let costCenterId: Int?
    let transactionType: String
    let amount: Double
    let balanceAfter: Double?
    let description: String?
    let createdByUserId: Int?
    let printArchiveId: Int?
    let printQueueId: Int?
    let createdAt: Date?

    var typeLabel: String {
        switch transactionType {
        case "print_charge": "Print charge"
        case "deposit": "Deposit"
        case "withdraw": "Withdrawal"
        case "manual_adjustment": "Manual adjustment"
        default: transactionType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var symbol: String {
        switch transactionType {
        case "print_charge": "printer.fill"
        case "deposit": "arrow.down.circle.fill"
        case "withdraw": "arrow.up.circle.fill"
        default: "slider.horizontal.3"
        }
    }
}

struct FinTransactionPage: Decodable {
    let items: [FinTransaction]
    let total: Int
}

struct FinCostCenter: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let isPrivate: Bool
    let ownerUserId: Int?
    let isActive: Bool
    let totalBalance: Double?
    let totalBudget: Double?
    let monthlyBudget: Double?
    let budgetMode: String?
    let budgetLimit: Double?
    let budgetUsed: Double?
    let budgetAvailable: Double?
    let canPrint: Bool?

    /// 0...100 of the budget used, nil when unlimited.
    var budgetPercent: Double? {
        guard let limit = budgetLimit, limit > 0, let used = budgetUsed else { return nil }
        return min(100, max(0, used / limit * 100))
    }

    var budgetKind: String {
        budgetMode == "monthly" ? "Monthly budget" : (budgetMode == "total" ? "Total budget" : "No budget")
    }
}

struct FinMember: Decodable, Identifiable, Hashable {
    let id: Int
    let costCenterId: Int
    let userId: Int
    let canPrint: Bool
}

struct FinCostCenterDetail: Decodable {
    let center: FinCostCenter
    let members: [FinMember]

    private enum Keys: String, CodingKey { case members }

    init(from decoder: Decoder) throws {
        center = try FinCostCenter(from: decoder)
        members = try decoder.container(keyedBy: Keys.self).decodeIfPresent([FinMember].self, forKey: .members) ?? []
    }
}

struct FinUser: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
}

struct FinEnergySettings: Decodable {
    let currency: String?
    let energyCostPerKwh: Double?
}

enum FinMoney {
    static func symbol(_ code: String?) -> String {
        let code = (code ?? "USD").uppercased()
        let known = ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥", "CAD": "CA$", "AUD": "A$", "CHF": "CHF ", "INR": "₹",
                     "KRW": "₩", "BRL": "R$", "SEK": "kr ", "NOK": "kr ", "DKK": "kr ", "PLN": "zł ", "CZK": "Kč "]
        return known[code] ?? code + " "
    }

    static func format(_ amount: Double, currency: String?, signed: Bool = false, decimals: Int = 2) -> String {
        let body = symbol(currency) + String(format: "%.\(decimals)f", abs(amount))
        if amount < 0 { return "-" + body }
        return signed && amount > 0 ? "+" + body : body
    }
}
