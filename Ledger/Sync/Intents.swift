import AppIntents
import UserNotifications
import LedgerKit

// Shortcuts / Siri actions. They run inside the app (no extension, so no extra App ID for SideStore).
// 「快速记一笔」 is meant for the Wallet "Transaction" automation: amount, merchant and card come from
// Apple Pay, the category is guessed from earlier entries for that merchant, and the entry is written
// right away — or, when something is unclear or the pre-commit check finds a problem, a notification
// asks you to confirm it in the app.

/// a draft waiting for confirmation (written by an action, opened from its notification)
struct IntentDraft: Codable {
    var date: String
    var payee: String
    var narration: String
    var amount: String
    var currency: String
    var account: String
    var funding: String
}

enum IntentPrefs {
    /// Wallet card name → funding account
    static let cardsKey = "intent.cards"
    /// card names seen from Shortcuts, for the settings page
    static let seenKey = "intent.seenCards"
    static let draftKey = "intent.draft"
}

@MainActor
extension Store {
    /// "¥1,234.50", "CN¥ 32", "32.00" → 32
    nonisolated static func parseAmount(_ s: String) -> Double? {
        let kept = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let v = Double(kept) else { return evalAmount(s) }
        return abs(v)
    }

    func cardAccount(_ card: String) -> String? {
        let name = card.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let map: [String: String] = Prefs.get(IntentPrefs.cardsKey, [String: String]())
        if let a = map[name], L?.accounts[a]?.close == nil { return a }
        var seen: [String] = Prefs.get(IntentPrefs.seenKey, [String]())
        if !seen.contains(name) { seen.append(name); Prefs.set(IntentPrefs.seenKey, seen) }
        guard let L = L, let D = D else { return nil }
        return guessFunding(name, source: .bank, L, D)
    }

    /// pick the expense account: an explicit account or keyword, else what this merchant used before
    func intentCategory(_ merchant: String, _ hint: String?) -> String? {
        guard let L = L, let D = D else { return nil }
        if let h = hint?.trimmingCharacters(in: .whitespaces), !h.isEmpty {
            if L.accounts[h] != nil { return h }
            let open = D.openAccounts.filter { $0.hasPrefix("Expenses:") }
            if let a = open.first(where: { $0.lowercased().contains(h.lowercased()) || acctDisplay($0).contains(h) }) { return a }
            var r = ImportRow(id: 0, date: Day.today()); r.payee = merchant; r.category = h
            if let a = guessCategory(r, L, D) { return a }
        }
        guard !merchant.isEmpty else { return nil }
        var r = ImportRow(id: 0, date: Day.today()); r.payee = merchant
        return guessCategory(r, L, D)
    }

    func intentDraft(amount: Double, merchant: String, card: String?, note: String?, category: String?) -> IntentDraft {
        let funding = card.flatMap { cardAccount($0) } ?? defaultFunding ?? D?.rankAccounts(["Liabilities:", "Assets:"]).first ?? ""
        let account = intentCategory(merchant, category) ?? ""
        return IntentDraft(date: Day.today(), payee: merchant, narration: note ?? "", amount: jsNumberString(amount),
                           currency: D?.acctCcy[funding] ?? L?.base ?? "CNY", account: account, funding: funding)
    }

    func draftFrom(_ x: IntentDraft) -> Draft {
        var d = newDraftFor(.expense)
        d.date = x.date; d.payee = x.payee; d.narration = x.narration; d.amount = x.amount
        d.currency = x.currency; d.account = x.account; d.funding = x.funding
        return d
    }

    /// open the entry form with a draft from an action
    func applyIntentDraft() {
        guard let x: IntentDraft = Prefs.get(IntentPrefs.draftKey, IntentDraft?.none) else { return }
        Prefs.set(IntentPrefs.draftKey, IntentDraft?.none)
        draft = draftFrom(x)
        popToken += 1
        tab = .add
    }

    /// keep the draft and post a notification that opens it
    func askToConfirm(_ x: IntentDraft, why: String) async {
        Prefs.set(IntentPrefs.draftKey, x)
        let c = UNMutableNotificationContent()
        c.title = LS("请确认这笔交易")
        c.body = LS("%@ %@：%@", x.payee.isEmpty ? LS("交易") : x.payee, money(Double(x.amount) ?? 0, x.currency), why)
        c.sound = .default
        c.userInfo = ["tab": "add", "draft": true]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ledger.intent." + UUID().uuidString, content: c, trigger: nil))
    }
}

struct QuickRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "快速记一笔"
    static var description = IntentDescription("按商户自动选择分类并直接入账；分类不确定或提交前检查发现问题时，发通知请你确认。适合钱包「交易」自动化：金额、商户、卡片分别填入快捷指令输入的对应项。")
    static var openAppWhenRun = false

    @Parameter(title: "金额") var amount: String
    @Parameter(title: "商户") var merchant: String?
    @Parameter(title: "卡片或付款方式") var card: String?
    @Parameter(title: "备注") var note: String?
    @Parameter(title: "分类（科目或关键词，可选）") var category: String?

    static var parameterSummary: some ParameterSummary {
        Summary("记一笔 \(\.$amount) 商户 \(\.$merchant)") {
            \.$card
            \.$note
            \.$category
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = Store.shared
        await store.ensureLoaded()
        guard let a = Store.parseAmount(amount), a > 0 else {
            return .result(value: "", dialog: IntentDialog(stringLiteral: LS("无法识别金额：%@", amount)))
        }
        guard store.L != nil else {
            return .result(value: "", dialog: IntentDialog(stringLiteral: LS("账本尚未加载，请先打开 App")))
        }
        let x = store.intentDraft(amount: a, merchant: merchant ?? "", card: card, note: note, category: category)
        if x.account.isEmpty || x.funding.isEmpty {
            await store.askToConfirm(x, why: x.account.isEmpty ? LS("未能确定分类") : LS("未能确定付款账户"))
            return .result(value: "", dialog: IntentDialog(stringLiteral: LS("已发送通知，请在 App 中确认分类")))
        }
        let d = store.draftFrom(x)
        guard let L = store.L, let D = store.D else { return .result(value: "", dialog: "") }
        let text = draftText(d, L, D)
        guard validateText(text, L, single: true).ok, let ops = store.makeOps(text, single: true) else {
            await store.askToConfirm(x, why: LS("内容校验未通过"))
            return .result(value: "", dialog: IntentDialog(stringLiteral: LS("已发送通知，请在 App 中确认")))
        }
        let issues = await store.issues(for: ops)
        if let first = issues.first {
            await store.askToConfirm(x, why: first.title)
            return .result(value: "", dialog: IntentDialog(stringLiteral: LS("提交前检查发现问题，已发送通知请你确认")))
        }
        await store.commit(ops, word: LS("已入账"), checked: true)
        let msg = LS("已记录 %@ %@ → %@", x.payee.isEmpty ? LS("交易") : x.payee, money(a, x.currency), acctLabel(x.account))
        return .result(value: text, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct OpenRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "记一笔（在 App 中确认）"
    static var description = IntentDescription("打开记账页并预填金额、商户和分类，核对后保存。")
    static var openAppWhenRun = true

    @Parameter(title: "金额") var amount: String?
    @Parameter(title: "商户") var merchant: String?
    @Parameter(title: "卡片或付款方式") var card: String?
    @Parameter(title: "备注") var note: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = Store.shared
        await store.ensureLoaded()
        let a = amount.flatMap { Store.parseAmount($0) } ?? 0
        if a > 0 || !(merchant ?? "").isEmpty {
            var x = store.intentDraft(amount: a, merchant: merchant ?? "", card: card, note: note, category: nil)
            if a <= 0 { x.amount = "" }
            Prefs.set(IntentPrefs.draftKey, x)
            store.applyIntentDraft()
        } else {
            store.popToken += 1
            store.tab = .add
        }
        return .result()
    }
}

struct MonthSpendIntent: AppIntent {
    static var title: LocalizedStringResource = "本月支出"
    static var description = IntentDescription("本月支出、与上月同期相比，以及预算剩余。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let store = Store.shared
        await store.ensureLoaded()
        guard let L = store.L, let D = store.D else { return .result(value: 0, dialog: IntentDialog(stringLiteral: LS("账本尚未加载，请先打开 App"))) }
        let today = Day.today()
        let m = Day.ym(today)
        let spent = D.monthExp[m] ?? 0
        // last month up to the same day
        let pm = Day.addMonth(m, -1)
        let cut = pm + "-" + String(today.suffix(2))
        var prev = 0.0
        for t in L.txns where t.date.hasPrefix(pm) && t.date <= cut {
            let c = classify(t, L)
            if c.kind == .expense { prev -= c.amount }
        }
        var msg = LS("%@ 已支出 %@，上月同期 %@", Day.monthLabel(m), money(spent, L.base), money(prev, L.base))
        let bs = budgetProgress(L, key: m).filter { $0.budget.currency == L.base }
        if !bs.isEmpty {
            let left = bs.reduce(0) { $0 + $1.remaining }
            msg += LS("；预算剩余 %@", money(left, L.base))
        }
        return .result(value: spent, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct UpcomingIntent: AppIntent {
    static var title: LocalizedStringResource = "待付款项"
    static var description = IntentDescription("待记账的订阅、7 天内的订阅扣费和信用卡还款，以及可用资金预测。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        await store.ensureLoaded()
        guard let L = store.L else { return .result(dialog: IntentDialog(stringLiteral: LS("账本尚未加载，请先打开 App"))) }
        let today = Day.today()
        let week = Day.shift(today, 7)
        var parts: [String] = []
        let due = subscriptionsDue(L, today: today)
        if !due.isEmpty { parts.append(LS("待记账：%@", due.map { $0.sub.name }.joined(separator: LS("、")))) }
        let soon = subscriptions(L).filter { $0.status == .active }.compactMap { s -> String? in
            let d = s.due(onOrAfter: Day.shift(today, 1))
            return d <= week ? LS("%@ %@ %@", s.name, d, money(s.amount, s.currency)) : nil
        }
        if !soon.isEmpty { parts.append(LS("7 天内扣费：%@", soon.joined(separator: LS("、")))) }
        let cards = cardCycles(L, today: today).filter { !$0.settled && $0.due <= Day.shift(today, 15) }
        if !cards.isEmpty {
            parts.append(LS("信用卡：%@", cards.map { LS("%@ %@ 应还 %@", acctLabel($0.account), $0.due, money($0.remaining, $0.currency)) }.joined(separator: LS("、"))))
        }
        if let f = store.forecastCached(days: 30, daily: UserDefaults.standard.object(forKey: ForecastPrefs.dailyKey) as? Bool ?? true), !f.accounts.isEmpty {
            parts.append(LS("30 天后可用资金约 %@，最低 %@（%@）", money(f.end, f.currency, 0), money(f.lowest.value, f.currency, 0), f.lowest.date))
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.isEmpty ? LS("近期没有待付款项") : parts.joined(separator: LS("。"))))
    }
}

struct LedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenRecordIntent(), phrases: ["用 \(.applicationName) 记一笔", "\(.applicationName) 记账"],
                    shortTitle: "记一笔", systemImageName: "square.and.pencil")
        AppShortcut(intent: MonthSpendIntent(), phrases: ["\(.applicationName) 本月支出", "\(.applicationName) 这个月花了多少"],
                    shortTitle: "本月支出", systemImageName: "chart.bar.xaxis")
        AppShortcut(intent: UpcomingIntent(), phrases: ["\(.applicationName) 待付款项", "\(.applicationName) 最近要付什么"],
                    shortTitle: "待付款项", systemImageName: "calendar.badge.clock")
    }
}
