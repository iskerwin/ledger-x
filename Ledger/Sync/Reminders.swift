import Foundation
import SwiftUI
import UserNotifications
import LedgerKit

/// local notifications, rescheduled every time the ledger is (re)loaded
@MainActor
enum Reminders {
    static let enabledKey = "ledger.remind.on"
    static let fixedKey = "ledger.remind.fixed"
    static let balanceKey = "ledger.remind.balance"
    static let balanceDaysKey = "ledger.remind.balanceDays"
    static let budgetKey = "ledger.remind.budget"
    static let subsKey = "ledger.remind.subs"
    static let subsDaysKey = "ledger.remind.subsDays"
    static var subsDays: Int { UserDefaults.standard.object(forKey: subsDaysKey) as? Int ?? 3 }
    /// card account → repayment day of month (0 = none), per ledger
    static func cardDays(_ store: Store) -> [String: Int] { Prefs.get(store.pk("remind.cards"), [String: Int]()) }
    static func setCardDays(_ v: [String: Int], _ store: Store) { Prefs.set(store.pk("remind.cards"), v) }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static func flag(_ k: String, _ def: Bool = true) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func next(hour: Int, after: Date = Date()) -> DateComponents {
        let cal = Calendar.current
        var d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: after) ?? after
        if d <= after { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    }

    private static func add(_ id: String, _ title: String, _ body: String, _ when: DateComponents, repeats: Bool = false, tab: String = "add") {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["tab": tab]
        let req = UNNotificationRequest(identifier: "ledger." + id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: repeats))
        UNUserNotificationCenter.current().add(req)
    }

    /// cancel and re-create every reminder from the current ledger
    static func reschedule(_ store: Store) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map { $0.identifier }.filter { $0.hasPrefix("ledger.") })
        guard enabled, !store.demo, let L = store.L else { return }
        let today = Day.today()

        // credit card repayment days
        for (acct, day) in cardDays(store) where day >= 1 && day <= 31 {
            let owed = -((L.final[acct] ?? [:]).reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key) ?? 0) })
            var dc = DateComponents()
            dc.day = day
            dc.hour = 9
            add("card." + acct, LS("信用卡还款日"),
                owed > 0.005 ? LS("%@ 今天到期，账本中当前欠款 %@", acctLabel(acct), money(owed)) : LS("%@ 今天到期，记得还款并在 App 中入账", acctLabel(acct)),
                dc, repeats: true)
        }

        // fixed monthly transactions not recorded yet this month
        if flag(fixedKey) {
            let due = store.templateList.filter { $0.monthly && $0.due }
            if !due.isEmpty {
                let names = due.prefix(4).map { $0.label }.joined(separator: LS("、"))
                add("fixed." + Day.ym(today), LS("本月固定交易未入账"),
                    LS("%@ 笔：%@%@", due.count, names, due.count > 4 ? "…" : ""), next(hour: 20))
            }
        }

        // accounts not reconciled for a while
        if flag(balanceKey) {
            let days = max(7, UserDefaults.standard.integer(forKey: balanceDaysKey) == 0 ? 30 : UserDefaults.standard.integer(forKey: balanceDaysKey))
            var last: [String: String] = [:]
            for b in L.balances { if let a = b.account, b.date > (last[a] ?? "") { last[a] = b.date } }
            let cutoff = Day.shift(today, -days)
            let stale = last.filter { a, d in
                d < cutoff && (L.accounts[a]?.close == nil) && abs((L.final[a] ?? [:]).values.reduce(0, +)) > 0.005
            }.keys.sorted()
            if !stale.isEmpty {
                add("balance." + today, LS("该核对余额了"),
                    LS("%@ 个账户超过 %@ 天未做余额核对：%@", stale.count, days, stale.prefix(3).map(acctLabel).joined(separator: LS("、"))), next(hour: 10))
            }
        }

        // subscriptions: N days before the next charge
        if flag(subsKey) {
            let lead = subsDays
            let cal = Calendar.current
            for sub in subscriptions(L) where sub.status == .active {
                let due = sub.due(onOrAfter: today)
                guard let dueDay = Day.date(due), let leadDay = Day.date(Day.shift(due, -lead)) else { continue }
                // 09:00 on the lead day; inside the lead window, the next of 09:00 / 20:00 that is
                // still on or before the charge day
                let now = Date()
                var times: [Date] = []
                for day in [leadDay, now, cal.date(byAdding: .day, value: 1, to: now) ?? now] {
                    for h in [9, 20] { if let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: day) { times.append(t) } }
                }
                let lastOK = cal.date(bySettingHour: 23, minute: 59, second: 0, of: dueDay) ?? dueDay
                guard let fire = times.filter({ $0 > now && $0 >= cal.startOfDay(for: leadDay) && $0 <= lastOK }).min() else { continue }
                // the date itself, not "today"/"tomorrow": the text is fixed when it is scheduled
                add("sub." + sub.name + "." + due, LS("订阅即将扣费"),
                    LS("%@ %@ 将扣费 %@", sub.name, due, money(sub.amount, sub.currency)),
                    cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire), tab: "overview")
            }
        }

        // budgets over
        if flag(budgetKey) {
            let over = budgetProgress(L, key: Day.ym(today)).filter { $0.over }
            if !over.isEmpty {
                add("budget." + Day.ym(today) + "." + over.map { $0.budget.account }.joined(), LS("预算超支"),
                    LS("本月 %@ 已超出预算", over.prefix(3).map { acctLabel($0.budget.account) }.joined(separator: LS("、"))), next(hour: 21))
            }
        }
    }
}

/// 设置 → 提醒
struct RemindersSection: View {
    @EnvironmentObject var store: Store
    @AppStorage(Reminders.enabledKey) private var on = false
    @AppStorage(Reminders.fixedKey) private var fixed = true
    @AppStorage(Reminders.balanceKey) private var balance = true
    @AppStorage(Reminders.balanceDaysKey) private var balanceDays = 30
    @AppStorage(Reminders.budgetKey) private var budget = true
    @AppStorage(Reminders.subsKey) private var subs = true
    @AppStorage(Reminders.subsDaysKey) private var subsDays = 3
    @State private var cards: [String: Int] = [:]

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { v in
                Task {
                    if v, !(await Reminders.requestPermission()) { store.show(LS("请在系统设置中允许 Ledger 发送通知")); return }
                    on = v
                    await Reminders.reschedule(store)
                }
            })) { Label(LS("本地提醒"), systemImage: "bell.badge") }
            if on {
                Toggle(LS("固定交易本月未入账"), isOn: $fixed)
                Toggle(LS("预算超支"), isOn: $budget)
                Toggle(LS("订阅扣费"), isOn: $subs)
                if subs {
                    Stepper(LS("提前 %@ 天", subsDays), value: $subsDays, in: 0...14)
                }
                Toggle(LS("长期未做余额核对"), isOn: $balance)
                if balance {
                    Stepper(LS("超过 %@ 天", balanceDays), value: $balanceDays, in: 7...180, step: 7)
                }
                ForEach(cardAccounts, id: \.self) { a in
                    Picker(LS("%@ 还款日", acctLabel(a)), selection: Binding(get: { cards[a] ?? 0 }, set: { cards[a] = $0; Reminders.setCardDays(cards, store) })) {
                        Text(LS("不提醒")).tag(0)
                        ForEach(1...28, id: \.self) { Text(LS("每月 %@ 日", $0)).tag($0) }
                    }
                }
            }
        } header: {
            Text(LS("提醒"))
        } footer: {
            Text(LS("提醒在本机生成，每次打开 App 或同步后按最新账本重新安排。"))
        }
        .onChange(of: subsDays) { _, _ in Task { await Reminders.reschedule(store) } }
        .onChange(of: [fixed, balance, budget, subs]) { _, _ in Task { await Reminders.reschedule(store) } }
        .onChange(of: balanceDays) { _, _ in Task { await Reminders.reschedule(store) } }
        .onChange(of: cards) { _, _ in Task { await Reminders.reschedule(store) } }
        .onAppear { cards = Reminders.cardDays(store) }
    }

    private var cardAccounts: [String] {
        (store.D?.openAccounts ?? []).filter { $0.hasPrefix("Liabilities:CreditCard") || ($0.hasPrefix("Liabilities:") && $0.lowercased().contains("card")) }
    }
}

/// shows reminders while the app is open, and opens the right tab when one is tapped
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    var open: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tab = response.notification.request.content.userInfo["tab"] as? String ?? "add"
        await MainActor.run { open?(tab) }
    }
}
