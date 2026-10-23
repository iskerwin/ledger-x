import SwiftUI
import Charts
import LedgerKit

struct YearReviewDest: Hashable { var year: String? = nil }

/// 年度回顾: one year on one page. The figures come from `yearReview` (LedgerKit); this only shows them.
struct YearReviewView: View {
    @EnvironmentObject var store: Store
    @State private var year: String
    @State private var cur: String?
    @State private var picked: String?

    init(year: String? = nil) { _year = State(initialValue: year ?? String(Day.today().prefix(4))) }

    var body: some View {
        Group {
            if let L = store.L { content(L) } else { ProgressView() }
        }
        .navigationTitle(LS("年度回顾"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// what the page shows in: the operating currency by default; as chosen in the currency panel otherwise
    private func review(_ L: Ledger) -> (YearReview, [String]) {
        let mode = store.cmode, only = store.conly
        let cs = store.cview.isDefault ? [L.base] : viewCurrencies(L, mode: mode, only: only)
        let c = cur.flatMap { cs.contains($0) ? $0 : nil } ?? cs.first ?? L.base
        let r = yearReviewCached(L, year: year, mode: mode, currency: c, only: only, exclude: store.netWorthExclude,
                                 reimbursement: store.receivable)
        return (r, cs)
    }

    private func content(_ L: Ledger) -> some View {
        let years = reviewYears(L)
        let (r, cs) = review(L)
        return ScrollViewReader { proxy in
        List {
            Section {
                ChipRow {
                    ForEach(years, id: \.self) { y in
                        Chip(label: LS("%@年", y), selected: y == year) { withAnimation(AppMotion.quick) { year = y; picked = nil }; Haptics.selection() }
                    }
                }
                .listRowInsets(EdgeInsets(top: AppSpacing.icon, leading: AppSpacing.control, bottom: AppSpacing.icon, trailing: AppSpacing.control))
                if !store.cview.isDefault {
                    CurrencyBanner()
                    if cs.count > 1 {
                        ChipRow {
                            ForEach(cs, id: \.self) { c in
                                Button { cur = c } label: { CurrencyChip(code: c, on: c == r.currency, held: true, picker: true) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if r.isEmpty {
                Section { Text(LS("这一年没有记录。")).foregroundStyle(.secondary) }
            } else {
                summarySection(r)
                monthsSection(r)
                worthSection(r)
                categorySection(r, L).id("categories")
                biggestSection(r)
                payeeSection(r)
                eventSection(r)
                salarySection(r, L)
                fundSection(r, L)
                otherSection(r, L)
            }
        }
        .listSectionSpacing(.compact)
        .onAppear {
            if !years.isEmpty && !years.contains(year) { year = years[0] }
        }
        .task {
            // screenshots: further down the page
            guard store.demoEnv["LEDGER_YEAR_SCROLL"] != nil else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            proxy.scrollTo("categories", anchor: .top)
        }
        }
    }

    // MARK: sections

    private func change(_ now: Double, _ before: Double?) -> String? {
        guard let b = before, abs(b) > 0.005 else { return nil }
        let pct = (now - b) / abs(b) * 100
        return (pct >= 0 ? "+" : "") + String(format: "%.1f%%", pct)
    }

    private func summarySection(_ r: YearReview) -> some View {
        Section {
            Card {
                VStack(alignment: .leading, spacing: AppSpacing.control) {
                    Text(r.through < r.year + "-12-31" ? LS("%@ 年（截至 %@）", r.year, r.through) : LS("%@ 年", r.year))
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("结余")).font(.subheadline).foregroundStyle(.secondary)
                        Text(money(r.net, r.currency)).font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit().foregroundStyle(r.net >= 0 ? Color.gain : Color.loss).sensitive()
                    }
                    HStack(alignment: .top, spacing: AppSpacing.control) {
                        Figure(label: LS("收入"), value: money(r.income, r.currency), color: .gain)
                        Spacer()
                        Figure(label: LS("支出"), value: money(r.expenses, r.currency))
                        Spacer()
                        Figure(label: LS("储蓄率"), value: r.savingsRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", alignment: .trailing)
                    }
                    if r.income > 0 || r.expenses > 0 {
                        RatioBar(parts: [(r.income, Color.gain), (r.expenses, Color.jade)])
                    }
                    if let pi = r.previousIncome, let pe = r.previousExpenses {
                        let a = change(r.income, pi), b = change(r.expenses, pe)
                        if a != nil || b != nil {
                            Text([a.map { LS("收入比上年 %@", $0) }, b.map { LS("支出比上年 %@", $0) }].compactMap { $0 }.joined(separator: "，"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .cardRow()
        }
    }

    private func monthsSection(_ r: YearReview) -> some View {
        Section {
            IncomeExpenseChart(months: r.months.map { $0.month },
                               inc: Dictionary(uniqueKeysWithValues: r.months.map { ($0.month, $0.income) }),
                               exp: Dictionary(uniqueKeysWithValues: r.months.map { ($0.month, $0.expenses) }),
                               currency: r.currency, picked: $picked)
            if let hi = r.dearestMonth, let lo = r.cheapestMonth, hi.month != lo.month {
                LabeledContent(LS("花得最多：%@", Day.monthLabel(hi.month))) { Amount(n: hi.expenses, c: r.currency) }
                LabeledContent(LS("花得最少：%@", Day.monthLabel(lo.month))) { Amount(n: lo.expenses, c: r.currency) }
            }
        } header: {
            Text(LS("月度收支"))
        }
    }

    @ViewBuilder private func worthSection(_ r: YearReview) -> some View {
        if let end = r.worthEnd {
            Section {
                HStack(alignment: .top, spacing: AppSpacing.control) {
                    Figure(label: LS("年初"), value: r.worthStart.map { money($0, r.currency) } ?? "—")
                    Spacer()
                    Figure(label: LS("年末"), value: money(end, r.currency))
                    Spacer()
                    let d = end - (r.worthStart ?? 0)
                    Figure(label: LS("变化"), value: signedMoney(d, r.currency), color: d >= 0 ? .gain : .loss, alignment: .trailing)
                }
                if r.worthByMonth.count > 1 {
                    Chart(r.worthByMonth, id: \.month) { p in
                        LineMark(x: .value(LS("月份"), p.month), y: .value(LS("净资产"), p.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.jade)
                        PointMark(x: .value(LS("月份"), p.month), y: .value(LS("净资产"), p.value))
                            .symbolSize(18).foregroundStyle(Color.jade)
                            .accessibilityLabel(Day.monthLabel(p.month) + LS("末")).accessibilityValue(money(p.value, r.currency))
                    }
                    .chartXAxis {
                        AxisMarks(values: r.worthByMonth.map { $0.month }.filter { ((Int($0.suffix(2)) ?? 1) - 1) % 3 == 0 }) { v in
                            AxisValueLabel { if let m = v.as(String.self) { Text(String(Int(m.suffix(2)) ?? 0)) } }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 150)
                    .sensitive()
                }
                LabeledContent(LS("资产变化")) { Amount(n: r.assetsChange, c: r.currency, signed: true) }
                LabeledContent(LS("负债变化")) { Amount(n: r.liabilitiesChange, c: r.currency, signed: true) }
            } header: {
                Text(LS("净资产"))
            } footer: {
                Text(LS("负债以负数计；负债变化为正，表示欠得少了。"))
            }
        }
    }

    @ViewBuilder private func categorySection(_ r: YearReview, _ L: Ledger) -> some View {
        if !r.categories.isEmpty {
            Section {
                ForEach(r.categories) { c in
                    HStack(spacing: AppSpacing.control) {
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text(catLabel(c.account))
                            if r.expenses > 0 {
                                Text(String(format: "%.1f%%", c.amount / r.expenses * 100)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                            Amount(n: c.amount, c: r.currency)
                            if let p = c.previous, abs(c.amount - p) > 0.005 {
                                let d = c.amount - p
                                Text(LS("比上年 %@", signedMoney(d, r.currency))).font(.caption)
                                    .foregroundStyle(d > 0 ? Color.loss : Color.gain).sensitive()
                            } else if c.previous == nil, r.previousExpenses != nil {
                                Text(LS("上年没有")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(LS("支出构成"))
            }
        }
    }

    @ViewBuilder private func biggestSection(_ r: YearReview) -> some View {
        if !r.biggest.isEmpty {
            Section {
                ForEach(r.biggest) { x in
                    NavigationLink(value: TxDest(x.entry)) {
                        HStack(spacing: AppSpacing.control) {
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text([x.entry.payee, x.entry.narration].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                                Text(x.entry.date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: x.amount, c: r.currency)
                        }
                    }
                }
            } header: {
                Text(LS("最大的 %@ 笔支出", r.biggest.count))
            }
        }
    }

    @ViewBuilder private func payeeSection(_ r: YearReview) -> some View {
        if !r.payees.isEmpty {
            Section {
                ForEach(r.payees) { p in
                    NavigationLink(value: PayeeDest(name: p.name)) {
                        HStack(spacing: AppSpacing.control) {
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text(p.name).lineLimit(1)
                                Text(LS("%@ 次", p.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: p.amount, c: r.currency)
                        }
                    }
                }
            } header: {
                Text(LS("收付款方"))
            }
        }
    }

    @ViewBuilder private func eventSection(_ r: YearReview) -> some View {
        if !r.events.isEmpty {
            Section {
                ForEach(r.events) { e in
                    NavigationLink(value: EventDest(tag: e.event.tag)) {
                        HStack(spacing: AppSpacing.control) {
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text(e.event.title).lineLimit(1)
                                Text(e.summary.unpaid > 0.005 ? LS("%@ 天 · 未报销 %@", e.days, money(e.summary.unpaid)) : LS("%@ 天", e.days))
                                    .font(.caption).foregroundStyle(.secondary).sensitive()
                            }
                            Spacer()
                            Amount(n: e.summary.total)
                        }
                    }
                }
            } header: {
                Text(LS("事件"))
            }
        }
    }

    @ViewBuilder private func salarySection(_ r: YearReview, _ L: Ledger) -> some View {
        if let s = r.salary {
            Section {
                LabeledContent(LS("税前收入")) { Amount(n: s.gross, c: L.base) }
                ForEach(s.earnings.sorted { $0.value > $1.value }, id: \.key) { a, v in
                    LabeledContent(accountTitle(L, a)) { Amount(n: v, c: L.base) }.font(.subheadline).padding(.leading, AppSpacing.control)
                }
                if s.deductions > 0.005 { LabeledContent(LS("扣款")) { Amount(n: -s.deductions, c: L.base) } }
                if s.tax > 0.005 { LabeledContent(LS("个税")) { Amount(n: -s.tax, c: L.base) } }
                LabeledContent(LS("实发")) { Amount(n: s.net, c: L.base) }.fontWeight(.semibold)
            } header: {
                Text(LS("工资与个税"))
            } footer: {
                Text(LS("%@ 个月有工资记录。", s.months))
            }
        }
    }

    @ViewBuilder private func fundSection(_ r: YearReview, _ L: Ledger) -> some View {
        if !r.funds.isEmpty {
            Section {
                ForEach(r.funds) { f in
                    HStack(spacing: AppSpacing.control) {
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text(accountTitle(L, f.account))
                            Text(LS("年末余额 %@", money(f.balance, L.base))).font(.caption).foregroundStyle(.secondary).sensitive()
                        }
                        Spacer()
                        Amount(n: f.paidIn, c: L.base)
                    }
                }
            } header: {
                Text(LS("公积金与社保"))
            } footer: {
                Text(LS("右侧为全年缴存。"))
            }
        }
    }

    @ViewBuilder private func otherSection(_ r: YearReview, _ L: Ledger) -> some View {
        let reimb = r.advanced > 0.005 || r.reimbursed > 0.005 || r.reimbOwed > 0.005
        if r.subscriptions > 0.005 || reimb || !r.investment.isEmpty {
            Section {
                if r.subscriptions > 0.005 {
                    LabeledContent(LS("订阅")) { Amount(n: r.subscriptions, c: r.currency) }
                }
                if reimb {
                    LabeledContent(LS("报销：垫付")) { Amount(n: r.advanced, c: L.base) }
                    LabeledContent(LS("报销：已回款")) { Amount(n: r.reimbursed, c: L.base) }
                    if r.reimbOwed > 0.005 { LabeledContent(LS("年末待回款")) { Amount(n: r.reimbOwed, c: L.base) } }
                }
                ForEach(r.investment, id: \.account) { x in
                    LabeledContent(LS("投资收益：%@", accountTitle(L, x.account))) { Amount(n: x.amount, c: r.currency, signed: true) }
                }
            } header: {
                Text(LS("其他"))
            }
        }
    }
}

/// 概览: in December and January, a way into the year's review
struct YearReviewOverviewSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let today = Day.today()
        let m = Int(today.dropFirst(5).prefix(2)) ?? 0
        let forced = store.demoEnv["LEDGER_YEAR_CARD"] != nil
        if m == 12 || m == 1 || forced {
            let y = m == 1 ? String((Int(today.prefix(4)) ?? 2000) - 1) : String(today.prefix(4))
            Section {
                NavigationLink(value: YearReviewDest(year: y)) {
                    ReportRow(symbol: "sparkles", color: .orange, title: LS("%@ 年度回顾", y), detail: LS("全年收支、净资产、支出构成与大事"))
                }
            }
        }
    }
}
