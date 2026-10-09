import Foundation

/// what the home-screen widget shows; written by the app into the shared App Group
struct WidgetSnapshot: Codable {
    struct BudgetLine: Codable, Hashable {
        var name: String
        var spent: Double
        var limit: Double
        var over: Bool { spent > limit + 0.005 }
        var ratio: Double { limit > 0 ? spent / limit : 0 }
    }
    var month: String          // "2026年10月" / "Oct 2026"
    var spent: Double
    var income: Double
    var lastMonth: Double
    var budgetLimit: Double     // sum of this month's budgets (0 = none)
    var budgetSpent: Double
    var budgets: [BudgetLine]
    var currency: String
    var privacy: Bool
    var theme: String
    var english: Bool
    var updated: Date

    static let key = "widget.snapshot"

    /// the App Group; SideStore / AltStore rewrite group ids and list the real ones under ALTAppGroups
    static var group: String {
        (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])?.first ?? "group.com.iskerwin.ledger"
    }
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func load() -> WidgetSnapshot? {
        guard let d = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { WidgetSnapshot.defaults?.set(d, forKey: WidgetSnapshot.key) }
    }

    static let sample = WidgetSnapshot(month: "2026年10月", spent: 3268.5, income: 26800, lastMonth: 5766, budgetLimit: 6000, budgetSpent: 3268.5,
                                       budgets: [BudgetLine(name: "Food", spent: 1460, limit: 2000), BudgetLine(name: "Shopping", spent: 820, limit: 600),
                                                 BudgetLine(name: "Transit", spent: 210, limit: 400)],
                                       currency: "CNY", privacy: false, theme: "jade", english: false, updated: Date())
}
