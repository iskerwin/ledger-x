import SwiftUI
import Charts
import LedgerKit

/// The top of 报表: three plain questions about a month — where the money went, what changed against the month
/// before, how long the money lasts — before the full reports. Amounts in the operating currency, each at its day.
struct ReportsInsights: View {
    @Environment(Store.self) var store
    @Binding var path: NavigationPath
    @State private var month = Day.ym(Day.today())
    /// which way the month last moved, for the side its name comes in from
    @AppStorage("ledger.reports.question") private var question = "where"

    var body: some View {
        if let L = store.L {
            // in the header, not a row: a row is clipped to the section's larger corners, which cut the capsules' ends
            Section {
            } header: {
                VStack(spacing: AppSpacing.control) {
                    monthBar
                    Picker(LS("问题"), selection: $question) {
                        Text(LS("钱花在哪")).tag("where")
                        Text(LS("比以前如何")).tag("change")
                        Text(LS("还能用多久")).tag("last")
                    }
                    .pickerStyle(.segmented)
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .listRowInsets(EdgeInsets())
            }
            // screenshots: which question is open
            .onAppear { if let q = store.demoEnv["LEDGER_QUESTION"] { question = q } }
            .ledgerControls("reports.insights", value: Binding(get: {
                var context = BrowseContext(); context.month = month; context.filters = [question]; return context
            }, set: { month = $0.month; question = $0.filters.first ?? "where" }))
            switch question {
            case "change": changeCard(L)
            case "last": lastCard(L)
            default: whereCard(L)
            }
        }
    }

    // MARK: the month

    private var monthBar: some View {
        let now = Day.ym(Day.today())
        return PeriodBar(title: Day.monthLabel(month), key: month, backTitle: LS("本月"), away: month != now, canGoOn: month < now,
                         widest: PeriodBar.widestMonth(month),
                         step: { k in month = min(now, Day.addMonth(month, k)) }, toNow: { month = now })
            .monthSwipe(back: { month = Day.addMonth(month, -1) }, forward: month >= now ? nil : { month = Day.addMonth(month, 1) })
            .accessibilityElement(children: .contain).accessibilityIdentifier("reports.monthbar")
    }

    /// spending by category group in [from, to], in the operating currency
    private func spending(_ L: Ledger, from: String, to: String) -> (byCat: [String: Double], byCatPayee: [String: [String: (Double, Int)]]) {
        let s = store.D?.categorySpend(from: from, to: to) ?? categorySpend(L, from: from, to: to)
        var payee: [String: [String: (Double, Int)]] = [:]
        for (group, rows) in s.byCatPayee {
            var one: [String: (Double, Int)] = [:]
            for (who, row) in rows { one[who] = (row.amount, row.count) }
            payee[group] = one
        }
        return (s.byCat, payee)
    }

    /// a card's title: the icon in the theme's colour, the words in the text colour (the same on all three)
    private func cardTitle(_ text: String, _ icon: String) -> some View {
        Label { Text(text).foregroundStyle(.primary) } icon: { Image(systemName: icon).foregroundStyle(Color.jade) }
            .font(.headline)
    }

    private func monthEnd(_ m: String) -> String { Day.shift(Day.addMonth(m, 1) + "-01", -1) }

    // MARK: 钱花在哪

    private static let palette: [Color] = [.jade, .mint, .blue, .orange, .purple, .gray]

    @ViewBuilder
    private func whereCard(_ L: Ledger) -> some View {
        let s = spending(L, from: month + "-01", to: min(monthEnd(month), Day.today())).byCat
        let rows = s.filter { $0.value > 0.005 }.sorted { $0.value > $1.value }
        let total = rows.reduce(0.0) { $0 + $1.value }
        let top = Array(rows.prefix(5))
        let rest = total - top.reduce(0.0) { $0 + $1.value }
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                cardTitle(LS("支出构成"), "chart.bar.fill")
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(month == Day.ym(Day.today()) ? LS("本月支出") : LS("%@支出", Day.monthLabel(month))).font(.caption).foregroundStyle(.secondary)
                    Text(money(total, L.base)).font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit().rollingNumber(total).sensitive()
                }
                if total > 0.005 {
                    GeometryReader { geo in
                        HStack(spacing: AppSpacing.detail) {
                            ForEach(Array(top.enumerated()), id: \.offset) { i, r in
                                Self.palette[i % Self.palette.count].frame(width: max(2, geo.size.width * r.value / total - 2))
                            }
                            if rest > 0.005 { Color.gray.opacity(0.4).frame(width: max(2, geo.size.width * rest / total - 2)) }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 12)
                    ForEach(Array(top.enumerated()), id: \.offset) { i, r in
                        Button { store.showInJournal(.report(month: month, account: r.key)) } label: {
                            HStack(spacing: AppSpacing.icon) {
                                Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 9, height: 9)
                                // the bar above already shows the shares: the row gives its room to the name
                                Text(catLabel(r.key)).lineLimit(1)
                                Spacer(minLength: AppSpacing.icon)
                                Text(money(r.value, L.base)).monospacedDigit().font(.subheadline).frame(minWidth: 86, alignment: .trailing).sensitive()
                                Text(String(format: "%.1f%%", r.value / total * 100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                    }
                    if rest > 0.005 {
                        Text(LS("其余 %@ 个分类 %@", rows.count - top.count, money(rest, L.base))).font(.caption).foregroundStyle(.secondary).sensitive()
                    }
                } else {
                    Text(LS("这个月还没有支出")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(AppSpacing.content)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .cardRow()
        }
    }

    // MARK: 比以前如何

    @ViewBuilder
    private func changeCard(_ L: Ledger) -> some View {
        // this month so far against the same days of the month before (whole months for a past month)
        let today = Day.today()
        let current = month == Day.ym(today)
        let to = current ? today : monthEnd(month)
        let prevMonth = Day.addMonth(month, -1)
        let day = Int(to.suffix(2)) ?? 28
        let prevTo = min(monthEnd(prevMonth), prevMonth + "-" + String(format: "%02d", day))
        let now = spending(L, from: month + "-01", to: to)
        let before = spending(L, from: prevMonth + "-01", to: current ? prevTo : monthEnd(prevMonth))
        let keys = Set(now.byCat.keys).union(before.byCat.keys)
        let deltas = keys.map { k in (k, (now.byCat[k] ?? 0) - (before.byCat[k] ?? 0)) }.filter { abs($0.1) > 0.005 }.sorted { $0.1 > $1.1 }
        let totalNow = now.byCat.values.reduce(0, +), totalBefore = before.byCat.values.reduce(0, +)
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                cardTitle(current ? LS("本月变化") : LS("%@的变化", Day.monthLabel(month)), "chart.bar.xaxis")
                Text(current ? LS("和上月同期（1 日到 %@ 日）比", String(day)) : LS("和%@比", Day.monthLabel(prevMonth)))
                    .font(.caption).foregroundStyle(.secondary)
                if let up = deltas.first, up.1 > 0.005 {
                    let who = (now.byCatPayee[up.0] ?? [:]).map { ($0.key, $0.value.0 - (before.byCatPayee[up.0]?[$0.key]?.0 ?? 0), $0.value.1) }
                        .max { $0.1 < $1.1 }
                    let count = (now.byCatPayee[up.0] ?? [:]).values.reduce(0) { $0 + $1.1 }
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("%@比上月同期多", catLabel(up.0))).font(.subheadline)
                        Text(money(up.1, L.base)).heroAmount().foregroundStyle(Color.warn).monospacedDigit().rollingNumber(up.1).sensitive()
                        HStack(spacing: AppSpacing.control) {
                            if let w = who { Text(LS("主要来自%@ · 共 %@ 笔", w.0, count)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Button {
                                store.showInJournal(.report(month: month, account: up.0))
                            } label: { Label(LS("查看这 %@ 笔", count), systemImage: "list.bullet").labelStyle(ControlLabelStyle()) }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                            .foregroundStyle(Color.jade)
                            .background(Color.jade.soft, in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text(LS("没有哪个分类比上月同期花得多")).font(.subheadline).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: AppSpacing.control) {
                    Text(LS("合计")).foregroundStyle(.secondary)
                    Spacer()
                    Text(money(totalNow, L.base) + "  " + signedMoney(totalNow - totalBefore, L.base))
                        .monospacedDigit().foregroundStyle(totalNow > totalBefore ? Color.warn : Color.gain).sensitive()
                }
                .font(.subheadline)
                ForEach(Array(deltas.prefix(3).filter { $0.1 > 0 } + deltas.suffix(2).filter { $0.1 < 0 }), id: \.0) { d in
                    Button { store.showInJournal(.report(month: month, account: d.0)) } label: {
                        HStack(spacing: AppSpacing.control) {
                            Text(catLabel(d.0))
                            Spacer()
                            Text(signedMoney(d.1, L.base)).monospacedDigit().foregroundStyle(d.1 > 0 ? Color.warn : Color.gain).sensitive()
                        }
                        .font(.subheadline)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppSpacing.content)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .cardRow()
        }
    }

    // MARK: 还能用多久

    @ViewBuilder
    private func lastCard(_ L: Ledger) -> some View {
        if let f = store.forecastCached(days: 30, daily: true) {
        Section {
            Button { path.append(ForecastDest()) } label: {
                VStack(alignment: .leading, spacing: AppSpacing.icon) {
                    cardTitle(LS("未来 30 天可用资金"), "wallet.bifold")
                    HStack(alignment: .bottom, spacing: AppSpacing.control) {
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text(money(f.end, L.base)).heroAmount().monospacedDigit().rollingNumber(f.end).sensitive()
                            Text(LS("预计最低 %@（%@）", money(f.lowest.value, L.base), Day.dayLabel(f.lowest.date)))
                                .font(.caption).foregroundStyle(.secondary).sensitive()
                        }
                        Spacer(minLength: 8)
                        Chart(f.points, id: \.date) { p in
                            AreaMark(x: .value("d", p.date), y: .value("v", p.value)).foregroundStyle(Color.jade.opacity(0.12))
                            LineMark(x: .value("d", p.date), y: .value("v", p.value)).foregroundStyle(Color.jade)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(width: 130, height: 56)
                        .sensitive()
                        // a picture of the numbers read out beside it
                        .accessibilityHidden(true)
                    }
                    Text(LS("从今天的可用余额 %@ 起，计入工资、订阅、信用卡账单和日常开销（日均 %@）。", money(f.start, L.base), money(f.dailySpend, L.base)))
                        .font(.caption).foregroundStyle(.secondary).sensitive()
                }
                .padding(AppSpacing.content)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardRow()
        }
        }
    }
}
