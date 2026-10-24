import SwiftUI
import Charts
import LedgerKit

/// 明细's month calendar, opened above the list: the month's totals, then the days, a dot in the theme colour on
/// those with spending and a green one on those with income; tap a day for its sheet. It counts what the list shows
/// (the same search and account filter).
struct JournalCalendar: View {
    @EnvironmentObject var store: Store
    let L: Ledger
    /// the transactions the list would show, newest first
    let entries: [Entry]
    /// filtered to one account: amounts on that account instead of spending / income
    let account: String?
    /// the day opened (its sheet), on a full theme-coloured disc
    let picked: String?
    let pick: (String) -> Void
    @State private var month = Day.ym(Day.today())

    struct DayTotal { var out = 0.0; var inn = 0.0; var n = 0 }

    /// spending in the theme colour, income in the app's gain colour, everywhere on this calendar
    static var spend: Color { Color.jade }
    static var earn: Color { Color.gain }
    /// a day with entries that are neither (transfers, advances, reimbursements): not shown as empty
    static var other: Color { Color.secondary.opacity(0.6) }

    private var byDay: [String: DayTotal] {
        var m: [String: DayTotal] = [:]
        let prefix = month
        for t in entries where t.date.hasPrefix(prefix) {
            var d = m[t.date] ?? DayTotal()
            d.n += 1
            // the same reading as the overview: transfers, advances and others' AA parts aren't spending
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: d.out -= c.amount
            case .income: d.inn += c.amount
            default: break
            }
            m[t.date] = d
        }
        return m
    }

    var body: some View {
        let totals = byDay
        let out = totals.values.reduce(0) { $0 + $1.out }, inn = totals.values.reduce(0) { $0 + $1.inn }
        var marks: [String: [Color]] = [:]
        for (d, x) in totals {
            let dots = [x.out > 0.005 ? Self.spend : nil, x.inn > 0.005 ? Self.earn : nil].compactMap { $0 }
            if !dots.isEmpty { marks[d] = dots } else if x.n > 0 { marks[d] = [Self.other] }
        }
        return VStack(spacing: AppSpacing.icon) {
            // equal columns, each centred: a month's longer amounts don't push 收入 sideways
            FigureRow(items: [
                .init(label: LS("支出"), value: money(out, L.base, 0), color: Self.spend),
                .init(label: LS("收入"), value: money(inn, L.base, 0), color: Self.earn),
                .init(label: LS("结余"), value: money(inn - out, L.base, 0), color: inn - out < 0 ? Color.loss : Color.primary),
            ], alignment: .center)
            .padding(.vertical, AppSpacing.detail)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.figures")
            MonthCalendar(marks: marks, month: $month, selected: picked, last: Day.today(), describe: { d in
                totals[d].flatMap { x in
                    let parts = [x.out > 0.005 ? LS("支出 ") + money(x.out) : nil, x.inn > 0.005 ? LS("收入 ") + money(x.inn) : nil].compactMap { $0 }
                    return parts.isEmpty ? (x.n > 0 ? LS("%@ 笔其他交易", x.n) : nil) : parts.joined(separator: " ")
                }
            }, pick: pick)
            legend
        }
        .onAppear(perform: follow)
        .onChange(of: entries.first?.date) { _, _ in follow() }
    }

    /// after the search changed: show the latest month with something in it, if this one has nothing
    private func follow() {
        guard !entries.contains(where: { $0.date.hasPrefix(month) }), let latest = entries.first else { return }
        month = Day.ym(latest.date)
    }

    /// what the dots mean, under the days
    private var legend: some View {
        HStack(spacing: AppSpacing.control) {
            HStack(spacing: AppSpacing.detail) {
                Circle().fill(Self.spend).frame(width: 6, height: 6)
                Text(LS("支出"))
            }
            HStack(spacing: AppSpacing.detail) {
                Circle().fill(Self.earn).frame(width: 6, height: 6)
                Text(LS("收入"))
            }
            HStack(spacing: AppSpacing.detail) {
                Circle().fill(Self.other).frame(width: 6, height: 6)
                Text(LS("其他交易"))
            }
            Spacer()
            Text(LS("点日期看当天明细"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}


/// One month calendar for the whole app, drawn like the system's but compact (about 38 pt a week instead of 50):
/// the day in the rounded face, today on a light theme-coloured disc, the open day on a full one, and up to three
/// dots under each day in its colours. Swiped or stepped from month to month. Days are "YYYY-MM-DD", months "YYYY-MM".
struct MonthCalendar: View {
    /// the dots under each day, left to right (spending in the theme colour, then income in green, or grey)
    var marks: [String: [Color]]
    /// the month on screen; changed here to move the calendar, set by it when the user swipes or steps
    @Binding var month: String
    /// the open day (its sheet, or the list narrowed to it), on a full theme-coloured disc
    var selected: String? = nil
    /// the first and last days that can be picked (the journal goes back years and up to today; coming charges
    /// start today)
    var first: String = "2000-01-01"
    var last: String
    /// what VoiceOver reads after the date ("支出 ¥12.00"), when there is something
    var describe: (String) -> String? = { _ in nil }
    var pick: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// the page the pager is on; kept apart from `month` so a swipe in progress and a step from outside
    /// (the arrows, 今天, a new search) each move the other without a loop
    @State private var page: String?

    var body: some View {
        VStack(spacing: AppSpacing.icon) {
            header
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, w in
                    Text(w).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            // the months side by side, paged as the system's calendar is: the month follows the finger and snaps
            // into place; built only near the one on screen. Six weeks high, so short months don't jump.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(months, id: \.self) { m in
                        weeks(m).containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .frame(height: 6 * Self.weekHeight + 5 * AppSpacing.detail)
            .onAppear { if page == nil { page = month } }
            .onChange(of: page) { _, p in if let p, p != month { month = p } }
            .onChange(of: month) { _, m in
                guard page != m else { return }
                withAnimation(reduceMotion ? nil : AppMotion.standard) { page = m }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.month")
    }

    /// a week's row: the day's disc and its dots
    private static let weekHeight: CGFloat = 38

    /// every month that can be shown, oldest first
    private var months: [String] {
        var out: [String] = [], m = Day.ym(first)
        let end = Day.ym(last)
        while m <= end { out.append(m); m = Day.addMonth(m, 1) }
        return out
    }

    private var header: some View {
        let now = Day.ym(Day.today())
        return PeriodBar(title: Day.monthLabel(month), key: month, backTitle: LS("今天"),
                         away: month != now && now >= Day.ym(first) && now <= Day.ym(last),
                         canGoBack: Day.addMonth(month, -1) >= Day.ym(first), canGoOn: Day.addMonth(month, 1) <= Day.ym(last),
                         capsule: false, backID: "calendar.today", widest: PeriodBar.widestMonth(month), step: step, toNow: { month = now })
    }

    private func step(_ k: Int) {
        let next = Day.addMonth(month, k)
        guard next >= Day.ym(first), next <= Day.ym(last) else { return }
        month = next
    }

    /// weekday names starting on the locale's first day of the week
    private var weekdays: [String] {
        let names = KitLocale.chinese ? Array("日一二三四五六").map(String.init) : ["S", "M", "T", "W", "T", "F", "S"]
        let start = Calendar.current.firstWeekday - 1
        return (0..<7).map { names[(start + $0) % 7] }
    }

    /// a month's weeks, only as many rows as it needs (at the top of its six-week page)
    private func weeks(_ month: String) -> some View {
        let count = Int(Day.monthEnd(month).suffix(2)) ?? 30
        let wd = Day.date(month + "-01").map { Day.calendar.component(.weekday, from: $0) } ?? 1
        let lead = (wd - Calendar.current.firstWeekday + 7) % 7
        let days: [String?] = Array(repeating: nil, count: lead) + (1...count).map { month + String(format: "-%02d", $0) }
        let rows = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let today = Day.today()
        return VStack(spacing: AppSpacing.detail) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        if i < rows[r].count, let d = rows[r][i] { cell(d, today: today) } else { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
        }
    }

    private func cell(_ d: String, today: String) -> some View {
        let open = d >= first && d <= last
        let isToday = d == today, isSelected = d == selected
        let dots = marks[d] ?? []
        return Button { pick(d) } label: {
            VStack(spacing: 3) {
                Text(String(Int(d.suffix(2)) ?? 0))
                    .font(.system(.callout, design: .rounded).weight(isToday || isSelected ? .bold : .medium).monospacedDigit())
                    // the days in the theme colour; today on a light disc, the open day on a full one, the rest greyed
                    .foregroundStyle(isSelected ? Color.onJade : open ? Color.jade : Color.secondary.opacity(0.45))
                    .frame(width: 30, height: 30)
                    .background(isSelected ? Color.jade : isToday ? Color.jade.soft : Color.clear, in: Circle())
                HStack(spacing: 3) {
                    ForEach(Array(dots.prefix(3).enumerated()), id: \.offset) { _, c in Circle().fill(c).frame(width: 5, height: 5) }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .accessibilityLabel(Day.dayLabel(d) + (describe(d).map { " " + $0 } ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// a day's totals beside its date, each named: 支出 ¥918.64, or 收入 ¥… · 支出 ¥… on a day with both
struct DayTotalsText: View {
    let out: Double
    let inn: Double

    var body: some View {
        let parts = [inn != 0 ? LS("收入 ") + money(inn) : nil, out != 0 ? LS("支出 ") + money(out) : nil].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).sensitive()
        }
    }
}

struct CalendarDay: Identifiable { let day: String; var id: String { day } }

/// a day picked on the journal's calendar: its income, spending and net, a bar for each currency, then its
/// transactions (and the documents of that day); half the screen, pulled up to all of it
struct CalendarDaySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    let day: String
    /// the day's transactions, as filtered in the journal
    let entries: [Entry]
    let account: String?
    let documents: [Entry]
    /// a transaction tapped: the sheet closes and the journal opens it
    let open: (Entry) -> Void
    @State private var viewing: DocItem?

    var body: some View {
        var out = 0.0, inn = 0.0
        for t in entries {
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: out -= c.amount
            case .income: inn += c.amount
            default: break
            }
        }
        let flows = flowsByCurrency(entries)
        return NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.control) {
                        HStack(spacing: AppSpacing.control) {
                            Figure(label: LS("收入"), value: money(inn, L.base), color: .gain)
                            Spacer()
                            Figure(label: LS("支出"), value: money(out, L.base), color: JournalCalendar.spend)
                            Spacer()
                            Figure(label: LS("纯利"), value: money(inn - out, L.base), color: inn - out < 0 ? Color.loss : Color.primary, alignment: .trailing)
                        }
                        .sensitive()
                        if !flows.isEmpty { FlowBars(flows: flows) }
                    }
                    .padding(.vertical, AppSpacing.detail)
                } footer: {
                    if flows.count > 1 { Text(LS("上面的合计折算为 %@；条形图按原币种。", L.base)) }
                }
                Section(LS("交易 · %@ 笔", entries.count)) {
                    if entries.isEmpty { Text(LS("这一天没有交易")).foregroundStyle(.secondary) }
                    ForEach(entries, id: \.id) { t in
                        Button { open(t) } label: {
                            HStack(spacing: AppSpacing.control) {
                                TxRow(t: t, account: account)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !documents.isEmpty {
                    Section(LS("票据")) {
                        ForEach(documents, id: \.id) { d in
                            let path = documentRepoPath(d)
                            Button { if let p = path { viewing = DocItem(path: p) } } label: {
                                HStack(spacing: AppSpacing.icon) {
                                    Image(systemName: "doc.text").foregroundStyle(Color.jade)
                                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                        Text(((d.path ?? "") as NSString).lastPathComponent).lineLimit(1)
                                        if let a = d.account { Text(acctDisplay(a)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                }
                            }
                            .disabled(path == nil)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Day.dayLabel(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) } } }
            .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
        }
    }
}

/// income and spending side by side for each currency, the net as a thin line over them, amounts at the ends
struct FlowBars: View {
    let flows: [CurrencyFlow]

    var body: some View {
        let inc = LS("收入"), exp = LS("支出"), net = LS("纯利")
        Chart {
            ForEach(flows, id: \.currency) { f in
                BarMark(x: .value("金额", f.income), y: .value("币种", f.currency), height: .ratio(0.32))
                    .foregroundStyle(by: .value("类型", inc))
                    .position(by: .value("类型", inc), axis: .vertical)
                    .annotation(position: .trailing) { label(f.income) }
                    .accessibilityLabel(f.currency + " " + inc).accessibilityValue(money(f.income, f.currency))
                BarMark(x: .value("金额", f.expenses), y: .value("币种", f.currency), height: .ratio(0.32))
                    .foregroundStyle(by: .value("类型", exp))
                    .position(by: .value("类型", exp), axis: .vertical)
                    .annotation(position: .trailing) { label(f.expenses) }
                    .accessibilityLabel(f.currency + " " + exp).accessibilityValue(money(f.expenses, f.currency))
                BarMark(x: .value("金额", f.net), y: .value("币种", f.currency), height: .fixed(3))
                    .foregroundStyle(by: .value("类型", net))
                    .accessibilityLabel(f.currency + " " + net).accessibilityValue(money(f.net, f.currency))
            }
            RuleMark(x: .value("零", 0)).foregroundStyle(Color.secondary.opacity(0.5))
        }
        // the calendar's colours: spending in the theme colour, income green, the net a plain line
        .chartForegroundStyleScale([inc: JournalCalendar.earn, exp: JournalCalendar.spend, net: Color.primary.opacity(0.6)])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel() } }
        .frame(height: CGFloat(flows.count) * 64 + 44)
        .sensitive(xAxis: true)
    }

    private func label(_ v: Double) -> some View {
        Text(abs(v) < 0.005 ? "" : masked(fmtNum(v))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
}
