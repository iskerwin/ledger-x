import SwiftUI
import Charts
import LedgerKit

/// the budgets of a month or year in a table, and on the right the picked one's lines in the ledger and its entries
struct BudgetsPage: View {
    let ledger: Ledger
    @State private var byYear = false
    @State private var month = Day.ym(Day.today())
    @State private var picked: String?

    var body: some View {
        let key = byYear ? String(month.prefix(4)) : month
        let progress = budgetProgress(ledger, key: key)
        let chosen = progress.first { $0.budget.account == picked } ?? progress.first
        VStack(spacing: 0) {
            PeriodStepper(byYear: $byYear, month: $month)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            if progress.isEmpty {
                ContentUnavailableView("没有预算", systemImage: "chart.pie")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.page)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 16) {
                            if let total = budgetTotal(progress) {
                                Card(summary: true) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Headline(label: "剩余", value: money(total.remaining, total.currency), color: total.remaining < 0 ? .loss : .primary)
                                        SummaryFigures(items: [("预算", money(total.limit, total.currency), .primary), ("已花", money(total.spent, total.currency), .primary)])
                                    }
                                }
                            }
                            Card {
                                VStack(spacing: 0) {
                                    BudgetRow(cells: ["分类", "预算", "已花", "剩余"], ratio: nil, color: .secondary, picked: false)
                                        .padding(.bottom, 6)
                                    ForEach(progress) { item in
                                        Divider()
                                        BudgetRow(cells: [acctDisplay(item.budget.account), money(item.limit, item.budget.currency),
                                                          money(item.spent, item.budget.currency), money(item.remaining, item.budget.currency)],
                                                  ratio: item.ratio, color: item.over ? .loss : item.ahead ? .warn : .jade, picked: chosen?.id == item.id)
                                            .onTapGesture { picked = item.budget.account }
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                    if let chosen {
                        Divider()
                        BudgetSide(ledger: ledger, progress: chosen, span: PeriodStepper.span(byYear, month), title: PeriodStepper.title(byYear, month))
                            .frame(width: 320)
                    }
                }
                .background(Color.page)
            }
        }
    }
}

private struct BudgetRow: View {
    let cells: [String]
    /// how much of it is spent; nil on the heading
    let ratio: Double?
    let color: Color
    let picked: Bool

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell).frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
            }
            Group {
                if let ratio {
                    ProgressView(value: min(ratio, 1)).tint(color)
                } else {
                    Text("进度").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 120)
        }
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(ratio == nil ? Color.secondary : picked ? Color.white : Color.primary)
        .padding(.vertical, ratio == nil ? 0 : 8)
        .padding(.horizontal, 6)
        .background(picked ? Color.jade : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// the picked budget: its account, each line it has had in the ledger, and the way to what it counted
private struct BudgetSide: View {
    let ledger: Ledger
    let progress: BudgetProgress
    let span: (String, String)
    let title: String

    var body: some View {
        let account = progress.budget.account
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(acctDisplay(account)).font(.title3.weight(.semibold))
                    Text(account).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(budgets(ledger).filter { $0.account == account }.reversed().enumerated()), id: \.element.id) { index, budget in
                            if index > 0 { Divider() }
                            FigureRow(label: budget.date, caption: budget.period.name, value: money(budget.amount, budget.currency))
                        }
                    }
                }
                if let biggest = progress.biggest {
                    Card {
                        FigureRow(label: "最大一笔", caption: biggest.what + " · " + shortDay(biggest.date), value: money(biggest.amount, progress.budget.currency))
                    }
                }
                NavigationLink(value: JournalScope(title: acctDisplay(account) + " · " + title, account: account, from: span.0, to: span.1)) {
                    Label("查看\(acctDisplay(account))明细", systemImage: "list.bullet")
                }
                .buttonStyle(.link)
            }
            .padding(16)
        }
    }
}

/// what the spendable accounts will hold over the next 30, 60 or 90 days, its lowest point, and what comes in and goes out on the way
struct ForecastPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    @AppStorage("forecastDays") private var days = 30

    var body: some View {
        let result = forecast(ledger, days: days, payslips: config?.payslips ?? [], largeExpense: config?.largeExpense ?? 2000)
        ReportScaffold {
            Picker(selection: $days) {
                ForEach([30, 60, 90], id: \.self) { Text("\($0) 天").tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        } content: {
            if result.accounts.isEmpty {
                ContentUnavailableView("没有可用的账户", systemImage: "chart.line.uptrend.xyaxis")
            } else {
                summary(result)
                events(result)
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle("计入的账户")
                        ForEach(result.accounts, id: \.self) { account in
                            Divider()
                            FigureRow(label: accountTitle(ledger, account), value: "")
                        }
                        Divider()
                        FigureRow(label: "日常支出", caption: "日均", value: money(result.dailySpend, result.currency))
                    }
                }
            }
        }
    }

    private func summary(_ result: Forecast) -> some View {
        let lowest = result.lowest
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                Headline(label: "\(days) 天后约", value: money(result.end, result.currency), color: result.end < 0 ? .loss : .primary)
                Chart {
                    ForEach(result.points) { point in
                        LineMark(x: .value("日期", Day.date(point.date) ?? Date()), y: .value("余额", point.value))
                            .foregroundStyle(Color.jade)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    }
                    PointMark(x: .value("日期", Day.date(lowest.date) ?? Date()), y: .value("余额", lowest.value))
                        .foregroundStyle(Color.warn)
                        .symbolSize(60)
                }
                .chartYAxis(.hidden)
                .frame(height: 180)
                SummaryFigures(items: [("今天可用", money(result.start, result.currency), .primary),
                                       ("最低 · " + Day.dayLabel(lowest.date), money(lowest.value, result.currency), lowest.value < 0 ? .loss : .primary)])
            }
        }
    }

    private func events(_ result: Forecast) -> some View {
        // what's left after each, as it goes
        var left = result.start
        let rows = result.events.sorted { $0.date < $1.date }.map { event -> (ForecastEvent, Double) in
            left += event.amount
            return (event, left)
        }
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("预计收支")
                ForEach(rows, id: \.0.id) { row in
                    Divider()
                    HStack(spacing: 12) {
                        Text(shortDay(row.0.date)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(row.0.title).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(signedMoney(row.0.amount, result.currency)).monospacedDigit().foregroundStyle(row.0.amount < 0 ? Color.loss : Color.gain)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// what subscriptions cost, the charges due but not in the ledger, every subscription, and regular payments that look like one
struct SubscriptionsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @State private var notice: String?

    var body: some View {
        let subs = subscriptions(ledger)
        let active = subs.filter { $0.status == .active }
        let due = subscriptionsDue(ledger, subs: subs)
        let ignored = Set(config?.subsIgnored ?? [])
        let candidates = subscriptionCandidates(ledger, subs: subs).filter { !ignored.contains($0.id) }
        let year = String(Day.today().prefix(4))
        ReportScaffold {
            Card(summary: true) {
                SummaryFigures(items: [("月均", money(active.reduce(0.0) { $0 + inBase(ledger, $1.monthly, $1.currency) }, ledger.base), .primary),
                                       ("\(year) 年已付", money(subs.reduce(0.0) { $0 + inBase(ledger, $1.paid(in: year), $1.currency) }, ledger.base), .primary),
                                       ("订阅中", "\(active.count)", .primary)])
            }
            if !due.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle("待记账")
                        ForEach(due) { item in
                            Divider()
                            FigureRow(label: item.sub.name, caption: shortDay(item.date) + " 应扣费 · 未入账", value: money(item.sub.amount, item.sub.currency), color: .warn)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle("订阅")
                    ForEach(subs.sorted { ($0.status == .active ? 0 : 1, $0.name) < ($1.status == .active ? 0 : 1, $1.name) }) { sub in
                        Divider()
                        NavigationLink(value: JournalScope(title: sub.name, account: nil, link: sub.link)) {
                            FigureRow(label: sub.name, caption: caption(sub), value: money(sub.amount, sub.currency), color: sub.status == .active ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !candidates.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle("可能的订阅")
                        ForEach(candidates) { candidate in
                            Divider()
                            HStack(spacing: 12) {
                                FigureRow(label: candidate.payee, caption: "\(candidate.period.name) · \(candidate.count) 笔 · \(candidate.first) 起",
                                          value: money(candidate.amount, candidate.currency))
                                Button("忽略") { ignore(candidate) }
                            }
                        }
                    }
                }
            }
        }
        .alert(notice ?? "", isPresented: $notice.present()) {}
    }

    private func caption(_ sub: Subscription) -> String {
        guard sub.status == .active else { return sub.status.name }
        let next = sub.due(onOrAfter: Day.shift(Day.today(), 1))
        return sub.period.name + " · " + accountTitle(ledger, sub.paymentAccount) + " · 下次 " + shortDay(next)
    }

    /// set aside for good, on every device: ledger-x.json, as the phone keeps it
    private func ignore(_ candidate: SubCandidate) {
        do {
            let save = try prepareFolderConfig(folder: folder) { config in
                var ids = config.subsIgnored ?? []
                if !ids.contains(candidate.id) { ids.append(candidate.id) }
                config.subsIgnored = ids
            }.get()
            try commitFolderSave(save, folder: folder)
        } catch {
            notice = error.localizedDescription
        }
    }
}
