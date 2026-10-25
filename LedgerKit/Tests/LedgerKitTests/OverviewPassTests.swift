import XCTest
@testable import LedgerKit

/// Payees, budgets, card cycles and report categories taken from one walk must match the scans they replace,
/// including another currency, an account left out of net worth, and the day the range stops.
final class OverviewPassTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger {
        let L = loadLedger(root: "main.bean") { _ in text }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined(separator: "\n"))
        return L
    }

    private let text = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Cash USD
    2026-01-01 open Assets:Hidden CNY
    2026-01-01 open Liabilities:CreditCard:CMB CNY,USD
      statement_day: 10
      due_day: 25
    2026-01-01 open Liabilities:CreditCard:Old CNY
      statement_day: 5
    2026-02-01 close Liabilities:CreditCard:Old
    2026-01-01 open Equity:Opening
    2026-01-01 open Income:Salary
    2026-01-01 open Income:Rewards
    2026-01-01 open Expenses:Food
    2026-01-01 open Expenses:Food:Snack
    2026-01-01 open Expenses:Travel
    2026-01-01 custom "budget" Expenses:Food "monthly" 200.00 CNY
    2026-01-01 custom "budget" Expenses:Travel "monthly" 40.00 USD
    2026-01-01 custom "budget" Expenses:Food:Snack "weekly" 20.00 CNY
    2026-03-20 custom "budget" Expenses:Food "monthly" 0.00 CNY

    2026-01-02 * "期初"
      Assets:Bank  5000.00 CNY
      Equity:Opening

    2026-02-01 price USD 7.00 CNY

    2026-02-10 * "超市" "米"
      Expenses:Food  40.00 CNY
      Assets:Bank

    2026-02-15 * "超市" "油"
      Expenses:Food  7.00 CNY
      Assets:Bank

    2026-02-16 * "超市" "盐"
      Expenses:Food  9.00 CNY
      Assets:Bank

    2026-03-01 * "机票"
      Expenses:Travel  10.00 USD
      Assets:Cash

    2026-03-02 * "超市" "退货"
      Expenses:Food  -5.00 CNY
      Assets:Bank

    2026-03-03 * "超市" "买菜"
      Expenses:Food  20.00 CNY
      Assets:Bank

    2026-03-04 * "超市" "优惠"
      Expenses:Food  20.00 CNY
      Income:Rewards  -2.00 CNY
      Assets:Bank

    2026-03-05 * "零食店"
      Expenses:Food:Snack  30.00 CNY
      Assets:Hidden

    2026-03-06 * "" "路边摊"
      Expenses:Food  6.00 CNY
      Assets:Bank

    2026-03-10 * "还款"
      Liabilities:CreditCard:CMB  15.00 CNY
      Assets:Bank

    2026-03-12 * "外币"
      Expenses:Travel  4.00 USD
      Liabilities:CreditCard:CMB

    2026-03-15 * "甲" "一样多"
      Expenses:Food  10.00 CNY
      Assets:Bank

    2026-03-15 * "乙" "一样多"
      Expenses:Food  10.00 CNY
      Assets:Bank

    2026-03-16 * "明天"
      Expenses:Food  50.00 CNY
      Assets:Bank

    """

    private func sameBudget(_ a: [BudgetProgress], _ b: [BudgetProgress], _ label: String) {
        XCTAssertEqual(a.map { $0.budget.id }, b.map { $0.budget.id }, label)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.spent, y.spent, accuracy: 1e-6, label + " " + x.budget.account)
            XCTAssertEqual(x.limit, y.limit, accuracy: 1e-6, label)
            XCTAssertEqual(x.elapsed, y.elapsed, accuracy: 1e-9, label)
            XCTAssertEqual(x.biggest?.what, y.biggest?.what, label)
            XCTAssertEqual(x.biggest?.date, y.biggest?.date, label)
            XCTAssertEqual(x.biggest?.amount ?? 0, y.biggest?.amount ?? 0, accuracy: 1e-6, label)
        }
    }

    private func sameSpend(_ a: CategorySpend, _ b: CategorySpend, _ label: String) {
        XCTAssertEqual(a.byCat.keys.sorted(), b.byCat.keys.sorted(), label)
        for key in a.byCat.keys.sorted() {
            XCTAssertEqual(a.byCat[key] ?? 0, b.byCat[key] ?? 0, accuracy: 1e-6, label + " " + key)
            let left = a.byCatPayee[key] ?? [:], right = b.byCatPayee[key] ?? [:]
            XCTAssertEqual(left.keys.sorted(), right.keys.sorted(), label)
            for who in left.keys {
                XCTAssertEqual(left[who]?.amount ?? 0, right[who]?.amount ?? 0, accuracy: 1e-6, who)
                XCTAssertEqual(left[who]?.count, right[who]?.count, who)
            }
        }
    }

    /// what the overview counted before, for the default currency: an expense (not a refund) once per transaction
    private func referencePayees(_ L: Ledger, prefix: String, synthetic: Bool) -> [String: (Double, Int)] {
        var m: [String: (Double, Int)] = [:]
        for t in L.txns where t.date.hasPrefix(prefix) && (synthetic || !t.synthetic) {
            let c = classify(t, L)
            guard c.kind == .expense else { continue }
            let name = payeeLabel(t)
            var row = m[name] ?? (0, 0)
            row.0 += -c.amount
            if !t.synthetic { row.1 += 1 }
            m[name] = row
        }
        return m.filter { $0.value.0 > 0.005 }
    }

    func testPayeesMatchAndARefundIsNotSpending() {
        let L = ledger(text)
        let d = Derived(L, today: "2026-03-15")
        for prefix in ["2026-03", "2026"] {
            let got = Dictionary(uniqueKeysWithValues: (d.payeeStats(prefix: prefix) ?? []).map { ($0.name, ($0.value, $0.count)) })
            let ref = referencePayees(L, prefix: prefix, synthetic: false)
            XCTAssertEqual(got.keys.sorted(), ref.keys.sorted(), prefix)
            for name in ref.keys {
                XCTAssertEqual(got[name]?.0 ?? 0, ref[name]?.0 ?? 0, accuracy: 1e-6, name)
                XCTAssertEqual(got[name]?.1, ref[name]?.1, name)
            }
        }
        let march = Dictionary(uniqueKeysWithValues: (d.payeeStats(prefix: "2026-03") ?? []).map { ($0.name, $0.value) })
        // 退货不算支出；优惠那笔按支出 20，不把收入的 2 扣掉；没写收付款方的用摘要。整月名单含 16 日。
        XCTAssertEqual(march["超市"] ?? 0, 20 + 20, accuracy: 1e-6)
        XCTAssertEqual(march["路边摊"] ?? 0, 6, accuracy: 1e-6)
        XCTAssertEqual(march["明天"] ?? 0, 50, accuracy: 1e-6)
        // 不计入净资产的账户，支出仍算在收付款方里
        XCTAssertEqual(march["零食店"] ?? 0, 30, accuracy: 1e-6)
        let hidden = netWorthSeries(L, today: "2026-03-15", exclude: ["Assets:Hidden"]).last!.netWorth
        XCTAssertNotEqual(hidden, netWorthSeries(L, today: "2026-03-15").last!.netWorth)
    }

    func testBudgetsMatchAcrossCurrenciesDaysAndABudgetSwitchedOff() {
        let L = ledger(text)
        let d = Derived(L, today: "2026-03-15")
        for today in ["2026-02-01", "2026-03-01", "2026-03-15", "2026-03-20", "2026-04-01"] {
            sameBudget(d.budgetProgress(key: "2026-03", today: today), budgetProgress(L, key: "2026-03", today: today), today)
            sameBudget(d.budgetProgress(key: "2026", today: today), budgetProgress(L, key: "2026", today: today), "year " + today)
        }
        let mid = d.budgetProgress(key: "2026-03", today: "2026-03-15")
        let food = mid.first { $0.budget.account == "Expenses:Food" }
        // 退货把支出减掉；子分类的零食算进餐饮。最大的一笔是 16 日的「明天」，不是同额的甲、乙。
        XCTAssertEqual(food?.spent ?? 0, -5 + 20 + 20 + 30 + 6 + 10 + 10 + 50, accuracy: 1e-6)
        XCTAssertEqual(food?.biggest?.what, "明天")
        XCTAssertEqual(mid.first { $0.budget.account == "Expenses:Food:Snack" }?.biggest?.what, "零食店")
        // 3 月 20 日把餐饮预算关掉之后，这项就没有了；旅行仍按美元折算
        let later = d.budgetProgress(key: "2026-03", today: "2026-03-20")
        XCTAssertNil(later.first { $0.budget.account == "Expenses:Food" })
        let travel = later.first { $0.budget.account == "Expenses:Travel" }
        XCTAssertEqual(travel?.spent ?? 0, 10 + 4, accuracy: 1e-6)
        XCTAssertEqual(travel?.budget.currency, "USD")
        // 今天还在 2 月时，3 月的账不进 2 月的预算
        let feb = d.budgetProgress(key: "2026-02", today: "2026-02-10")
        XCTAssertEqual(feb.first { $0.budget.account == "Expenses:Food" }?.spent ?? -1, 40 + 7 + 9, accuracy: 1e-6)
        XCTAssertLessThan(feb.first { $0.budget.account == "Expenses:Food" }?.elapsed ?? 1, 1)
    }

    func testCardCyclesMatchThePerCardWalkIncludingTheStatementDay() {
        let L = ledger(text)
        for today in ["2026-03-09", "2026-03-10", "2026-03-15", "2026-03-16"] {
            let got = cardCycles(L, today: today)
            let walk = cardCyclesWalk(L, today: today)
            let ref = referenceCycles(L, today: today)
            XCTAssertEqual(got.map(signature), ref.map(signature), today)
            XCTAssertEqual(got.map(signature), walk.map(signature), today)
        }
        XCTAssertFalse(cardCycles(L, today: "2026-03-15").contains { $0.account == "Liabilities:CreditCard:Old" })
        let on = cardCycles(L, today: "2026-03-10").first { $0.account == "Liabilities:CreditCard:CMB" }
        let before = cardCycles(L, today: "2026-03-09").first { $0.account == "Liabilities:CreditCard:CMB" }
        XCTAssertEqual(before?.statement, "2026-02-10")
        XCTAssertEqual(on?.statement, "2026-03-10")
        XCTAssertEqual(on?.currency, "CNY")
        // 余额是账上全部人民币，不按「今天」截断。这张卡只有 10 日的还款 +15，所以 9 日和 10 日余额都是 -15。
        // 9 日这笔还在今天之后，不进已还、也不进未出账；10 日它落在账单日上，还款使账单金额仍是 0。
        // 12 日的 4 美元在同一张卡上，按开户的第一个币种人民币出账，美元不加进人民币余额。
        XCTAssertEqual(before?.balance ?? 0, -15, accuracy: 1e-6)
        XCTAssertEqual(on?.balance ?? 0, -15, accuracy: 1e-6)
        XCTAssertEqual(before?.paid ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(before?.unbilled ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(on?.statementAmount ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(on?.paid ?? -1, 0, accuracy: 1e-6)
    }

    func testReportCategoriesUseTheMonthAndStopAtToday() {
        let L = ledger(text)
        let d = Derived(L, today: "2026-03-15")
        let feb = d.categorySpend(from: "2026-02-01", to: "2026-02-28")!
        sameSpend(feb, categorySpend(L, from: "2026-02-01", to: "2026-02-28"), "feb")
        var fromMonth: [String: Double] = [:]
        for (account, amount) in d.monthCat["2026-02"] ?? [:] { fromMonth[catOf(account), default: 0] += amount }
        XCTAssertEqual(fromMonth.keys.sorted(), feb.byCat.keys.sorted())
        for key in feb.byCat.keys { XCTAssertEqual(fromMonth[key] ?? 0, feb.byCat[key] ?? 0, accuracy: 1e-6, key) }
        let through = d.categorySpend(from: "2026-03-01", to: "2026-03-15")!
        sameSpend(through, categorySpend(L, from: "2026-03-01", to: "2026-03-15"), "through today")
        let whole = d.categorySpend(from: "2026-03-01", to: "2026-03-31")!
        sameSpend(whole, categorySpend(L, from: "2026-03-01", to: "2026-03-31"), "whole march")
        XCTAssertEqual((whole.byCat["Expenses:Food"] ?? 0) - (through.byCat["Expenses:Food"] ?? 0), 50, accuracy: 1e-6)
        let prev = d.categorySpend(from: "2026-02-01", to: "2026-02-15")!
        sameSpend(prev, categorySpend(L, from: "2026-02-01", to: "2026-02-15"), "prev")
        XCTAssertEqual(prev.byCat["Expenses:Food"] ?? 0, 40 + 7, accuracy: 1e-6)
        XCTAssertEqual(feb.byCat["Expenses:Food"] ?? 0, 40 + 7 + 9, accuracy: 1e-6)
        // 10 美元按 7 折；不计入的 Hidden 账户付出的零食仍在分类里
        XCTAssertEqual(through.byCat["Expenses:Travel"] ?? 0, (10 + 4) * 7, accuracy: 1e-6)
        XCTAssertEqual(through.byCatPayee["Expenses:Food"]?["零食店"]?.amount ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(through.byCatPayee["Expenses:Food"]?["路边摊"]?.count, 1)
        // 不是整月、也不是「到今天 / 上月同一天」的范围，留给原来的扫描
        XCTAssertNil(d.categorySpend(from: "2026-03-02", to: "2026-03-15"))
    }

    func testACurrencyViewRanksPayeesFromItsOwnWalk() {
        let L = ledger(text)
        let flows = viewFlows(L, mode: .units, only: nil, currency: "CNY")
        let again = viewFlows(L, mode: .units, only: nil, currency: "CNY")
        let stats = flows.payeeStats(prefix: "2026-03") ?? []
        XCTAssertEqual(stats.map(\.name), again.payeeStats(prefix: "2026-03")?.map(\.name))
        var ref: [String: Double] = [:]
        for t in L.txns where t.date.hasPrefix("2026-03") && !t.synthetic {
            guard let v = flows.txnExp[t.id] else { continue }
            ref[payeeLabel(t), default: 0] += v
        }
        ref = ref.filter { $0.value > 0.005 }
        let got = Dictionary(uniqueKeysWithValues: stats.map { ($0.name, $0.value) })
        XCTAssertEqual(got.keys.sorted(), ref.keys.sorted())
        for name in ref.keys { XCTAssertEqual(got[name] ?? 0, ref[name] ?? 0, accuracy: 1e-6, name) }
    }

    private func signature(_ c: CardCycle) -> String {
        [c.account, c.currency, c.statement, c.previousStatement, c.nextStatement, c.due, c.dueEstimated ? "est" : "set",
         String(c.statementAmount), String(c.paid), String(c.unbilled), String(c.balance), String(c.minimum)].joined(separator: "|")
    }

    /// the per-card walk cardCycles used to do
    private func referenceCycles(_ L: Ledger, today: String) -> [CardCycle] {
        var out: [CardCycle] = []
        let bills = cardBills(L)
        for (name, acc) in L.accounts.sorted(by: { $0.key < $1.key }) where name.hasPrefix("Liabilities:") && acc.close == nil {
            guard let sd = metaInt(acc.meta[statementDayKey]), sd >= 1, sd <= 31 else { continue }
            let dd = metaInt(acc.meta[dueDayKey])
            let ccy = acc.currencies.first ?? L.final[name]?.max(by: { abs($0.value) < abs($1.value) })?.key ?? L.base
            let st = statementOn(orBefore: today, day: sd)
            let prev = statementOn(orBefore: Day.shift(dayIn(Day.ym(st), 1), -1), day: sd)
            let next = statementOn(orAfter: Day.shift(today, 1), day: sd)
            var atStatement = 0.0, paid = 0.0, unbilled = 0.0, now = 0.0
            for t in L.txns {
                for p in t.postings where p.account == name && p.currency == ccy {
                    guard let u = p.units else { continue }
                    now += u
                    if t.date <= st { atStatement += u }
                    else if t.date <= today {
                        if u > 0 { paid += u } else { unbilled -= u }
                    }
                }
            }
            let (due, est) = dueDate(statement: st, statementDay: sd, dueDay: dd)
            let bill = bills.last { $0.account == name && $0.currency == ccy && $0.date > prev && $0.date <= st }
            let amount = bill?.amount ?? roundTo(max(0, -atStatement), 2)
            let minimum = bill?.minimum ?? roundTo(amount * minPaymentRate(acc.meta[minPaymentRateKey]), 2)
            out.append(CardCycle(account: name, currency: ccy, statementDay: sd, dueDay: dd, statement: st, previousStatement: prev,
                                 nextStatement: next, due: due, dueEstimated: est,
                                 statementAmount: amount, paid: roundTo(paid, 2),
                                 unbilled: roundTo(unbilled, 2), balance: roundTo(-now, 2),
                                 limit: creditLimit(acc.meta[creditLimitKey], ccy),
                                 minimum: min(minimum, amount), minimumEstimated: bill?.minimum == nil, bill: bill?.entry))
        }
        return out
    }
}
