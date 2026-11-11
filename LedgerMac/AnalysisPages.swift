import SwiftUI
import Charts
import LedgerKit

/// the most used payees, all of them when searching; the picked one's year, its month on average, and its entries opening in place
struct PayeesPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    /// the window's time: the payees and what went to them in it
    let period: ViewPeriod
    @State private var all: [PayeeSummary] = []
    @State private var text = ""
    @State private var picked: String?

    var body: some View {
        let shown = text.trimmed.isEmpty ? Array(all.prefix(50)) : all.filter { $0.name.localizedCaseInsensitiveContains(text.trimmed) }
        SplitPage {
            TextField("搜索", text: $text)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 6)
            ForEach(shown) { payee in
                PickRow(title: payee.name, caption: "\(payee.n) 笔 · 最近 \(shortDay(payee.last))",
                        trailing: payee.spent > 0.005 ? money(payee.spent, ledger.base) : payee.received > 0.005 ? "+" + money(payee.received, ledger.base) : "",
                        picked: picked == payee.name) { picked = payee.name }
            }
        } detail: {
            if let name = picked ?? all.first?.name {
                PayeeDetail(ledger: ledger, config: config, folder: folder, name: name, period: period).id(name)
            }
        }
        // every entry is classified: once a ledger and period, not on each key or pick
        .task(id: PayeesKey(ledger: ObjectIdentifier(ledger), period: period)) { all = payeeSummaries(ledger, span: period.span) }
    }
}

private struct PayeesKey: Hashable {
    let ledger: ObjectIdentifier
    let period: ViewPeriod
}

/// the twelve months up to the period's end, never past this one
private func monthsTo(_ period: ViewPeriod) -> [String] {
    let now = Day.ym(Day.today())
    let last = min(period.span.map { Day.ym($0.1) } ?? now, now)
    return (0..<12).map { Day.addMonth(last, $0 - 11) }
}

/// what went out to a payee in the operating currency, refunds taken off
private func payeeSpent(_ entries: [Entry], _ ledger: Ledger) -> Double {
    entries.reduce(0.0) { total, entry in
        let shown = classify(entry, ledger)
        return total + (shown.kind == .expense || shown.kind == .refund ? -shown.amount : 0)
    }
}

private struct PayeeDetail: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let name: String
    let period: ViewPeriod

    var body: some View {
        let entries = ledger.payeeEntriesKept(name)
        let span = period.span
        let inPeriod = span.map { span in entries.filter { $0.date >= span.0 && $0.date <= span.1 } } ?? entries
        let spent = payeeSpent(inPeriod, ledger)
        // the months of the period up to now, at least one
        let today = Day.today()
        let first = Day.ym(span?.0 ?? entries.first?.date ?? today), last = Day.ym(min(span?.1 ?? today, today))
        let count = { (m: String) in (Int(m.prefix(4)) ?? 0) * 12 + (Int(m.suffix(2)) ?? 0) }
        let months = Double(max(1, count(last) - count(first) + 1))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2.weight(.semibold))
                    Text("\(entries.count) 笔 · \(entries.first.map { $0.date } ?? "") 起 · 最近 \(entries.last.map { shortDay($0.date) } ?? "")")
                        .foregroundStyle(.secondary)
                }
                Card(summary: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        Headline(label: period.isCurrent && period.day == nil ? period.current : period.title, value: money(spent, ledger.base))
                        SummaryFigures(items: [("月均", money(spent / months, ledger.base), .primary),
                                               ("每笔约", money(inPeriod.isEmpty ? 0 : spent / Double(inPeriod.count), ledger.base), .primary)])
                    }
                }
                SideBySide {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle("每月")
                            MonthlySpend(ledger: ledger, entries: entries, months: monthsTo(period))
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle("常用")
                            ForEach(usual(entries), id: \.0) { item in
                                Divider()
                                FigureRow(label: item.0, value: "\(item.1) 笔")
                            }
                        }
                    }
                }
                EntryListCard(entries: Array(inPeriod.reversed().prefix(200)), ledger: ledger, config: config, folder: folder,
                              columns: [.date, .payee, .category, .accounts, .amount]) {
                    CardTitle("交易")
                }
            }
            .padding(20)
            .pageWidth(900)
        }
    }

    /// the categories and the accounts paid from most often, two of each
    private func usual(_ entries: [Entry]) -> [(String, Int)] {
        var categories: [String: Int] = [:], accounts: [String: Int] = [:]
        for entry in entries {
            if let category = shownCategory(entry) { categories[acctDisplay(category), default: 0] += 1 }
            for posting in entry.postings where posting.account.hasPrefix("Assets") || posting.account.hasPrefix("Liabilities") {
                accounts[accountTitle(ledger, posting.account), default: 0] += 1
            }
        }
        let top = { (counts: [String: Int]) in counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map { ($0.key, $0.value) } }
        return top(categories) + top(accounts)
    }
}

/// what went to a payee in each of `months`, in the operating currency
private struct MonthlySpend: View {
    let ledger: Ledger
    let entries: [Entry]
    let months: [String]

    var body: some View {
        var spent: [String: Double] = [:]
        for entry in entries where entry.date >= months[0] && Day.ym(entry.date) <= months[months.count - 1] {
            let shown = classify(entry, ledger)
            if shown.kind == .expense || shown.kind == .refund { spent[Day.ym(entry.date), default: 0] -= shown.amount }
        }
        return Chart(months, id: \.self) { month in
            BarMark(x: .value("月份", month), y: .value("支出", spent[month] ?? 0))
                .foregroundStyle(Color.jade.opacity(0.75))
                .cornerRadius(3)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: months) { value in
                AxisValueLabel { if let month = value.as(String.self) { Text(String(Int(month.suffix(2)) ?? 0)) } }
            }
        }
        .frame(height: 100)
        .accessibilityLabel("每月支出")
    }
}

/// a year of the ledger, as the phone's 年度回顾: what was kept, month by month, net worth, where it went and the rest
struct YearPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    /// the window's time: the year it's in
    let period: ViewPeriod

    var body: some View {
        let year = String(period.anchor.prefix(4))
        let review = yearReviewCached(ledger, year: year, mode: .convert(ledger.base), currency: ledger.base, only: nil,
                                      exclude: config?.netWorthExclude ?? [], reimbursement: config?.receivable ?? "Assets:Receivable:Reimbursement")
        ReportScaffold {
            if review.isEmpty {
                ContentUnavailableView("\(year) 年没有交易", systemImage: "calendar")
            } else {
                summary(review)
                SideBySide(weights: [2, 1]) {
                    months(review)
                    worth(review)
                }
                SideBySide {
                    categories(review)
                    biggest(review)
                    others(review)
                }
            }
        }
    }

    private func m(_ value: Double) -> String { money(value, ledger.base) }

    private func change(_ now: Double, _ before: Double?) -> String? {
        guard let before, before > 0.005 else { return nil }
        let rate = (now - before) / before * 100
        return (rate < 0 ? "−" : "+") + String(format: "%.1f%%", abs(rate))
    }

    private func summary(_ review: YearReview) -> some View {
        let changes = [change(review.income, review.previousIncome).map { "收入比上年 " + $0 },
                       change(review.expenses, review.previousExpenses).map { "支出比上年 " + $0 }].compactMap { $0 }
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                Headline(label: "\(review.year) 年结余" + (review.through < review.year + "-12-31" ? "（截至 \(review.through.dropFirst(5))）" : ""),
                         value: m(review.net), color: review.net < 0 ? .loss : .primary)
                if !changes.isEmpty {
                    Text(changes.joined(separator: "，")).foregroundStyle(.secondary)
                }
                SummaryFigures(items: [("收入", m(review.income), .gain), ("支出", m(review.expenses), .loss),
                                       ("储蓄率", review.savingsRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", .primary)])
            }
        }
    }

    private func months(_ review: YearReview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                FlowCard(months: review.months.map(\.month), income: Dictionary(uniqueKeysWithValues: review.months.map { ($0.month, $0.income) }),
                         expenses: Dictionary(uniqueKeysWithValues: review.months.map { ($0.month, $0.expenses) }), base: ledger.base)
                if let most = review.dearestMonth, let least = review.cheapestMonth {
                    Divider()
                    FigureRow(label: "花得最多", caption: "\(Int(most.month.suffix(2)) ?? 0) 月", value: m(most.expenses))
                    FigureRow(label: "花得最少", caption: "\(Int(least.month.suffix(2)) ?? 0) 月", value: m(least.expenses))
                }
            }
        }
    }

    private func worth(_ review: YearReview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("净资产")
                if let start = review.worthStart { FigureRow(label: "年初", value: m(start)) }
                if let end = review.worthEnd { FigureRow(label: review.through < review.year + "-12-31" ? "现在" : "年末", value: m(end)) }
                if let start = review.worthStart, let end = review.worthEnd {
                    FigureRow(label: "变化", value: signedMoney(end - start, ledger.base), color: end - start < 0 ? .loss : .gain)
                }
                Divider().padding(.vertical, 4)
                FigureRow(label: "资产变化", value: signedMoney(review.assetsChange, ledger.base))
                FigureRow(label: "负债变化", value: signedMoney(review.liabilitiesChange, ledger.base))
            }
        }
    }

    private func categories(_ review: YearReview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("支出构成")
                ForEach(review.categories.prefix(8)) { category in
                    Divider()
                    FigureRow(label: acctZH(category.account) ?? acctDisplay(category.account),
                              caption: change(category.amount, category.previous).map { "比上年 " + $0 } ?? "",
                              value: m(category.amount))
                }
            }
        }
    }

    private func biggest(_ review: YearReview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("最大的 5 笔支出")
                ForEach(review.biggest.prefix(5)) { item in
                    Divider()
                    FigureRow(label: item.entry.payee.isEmpty ? item.entry.narration : item.entry.payee, caption: shortDay(item.entry.date), value: m(item.amount))
                }
            }
        }
    }

    private func others(_ review: YearReview) -> some View {
        var rows: [(String, String)] = []
        if let salary = review.salary {
            rows.append(("工资实发", m(salary.net)))
            rows.append(("个税", m(salary.tax)))
        }
        if review.subscriptions > 0.005 { rows.append(("订阅", m(review.subscriptions))) }
        if review.advanced > 0.005 { rows.append(("报销：垫付", m(review.advanced))) }
        if review.reimbOwed > 0.005 { rows.append(("报销：年末未回款", m(review.reimbOwed))) }
        for item in review.events.prefix(3) { rows.append(("事件：" + item.event.title, "\(item.days) 天 · " + m(item.summary.total))) }
        return Group {
            if !rows.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle("其他")
                        ForEach(rows, id: \.0) { row in
                            Divider()
                            FigureRow(label: row.0, value: row.1)
                        }
                    }
                }
            }
        }
    }
}
