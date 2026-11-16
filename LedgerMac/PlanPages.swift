import SwiftUI
import Charts
import LedgerKit

/// the budgets of a month or year in a table, and beside it the picked one: its last six months, its lines in the ledger and the way to its entries
struct BudgetsPage: View {
    let ledger: Ledger
    let folder: URL
    /// the window's time: a year's budgets for a year or all time, else the month's
    let period: ViewPeriod
    @State private var picked: String?
    @State private var managing = false

    var body: some View {
        let byYear = period.byYear, month = period.anchor
        let key = byYear ? String(month.prefix(4)) : month
        let progress = ledger.budgetProgressKept(key)
        let chosen = progress.first { $0.budget.account == picked } ?? progress.first
        ReportScaffold {
            if progress.isEmpty {
                ContentUnavailableView(LS("没有预算"), systemImage: "chart.pie")
            } else {
                if let total = budgetTotal(progress) {
                    Card(summary: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            Headline(label: LS("剩余"), value: money(total.remaining, total.currency), color: total.remaining < 0 ? .loss : .primary)
                            SummaryFigures(items: [(LS("预算"), money(total.limit, total.currency), .primary), (LS("已花"), money(total.spent, total.currency), .primary),
                                                   (LS("超支"), LS("%@ 项", progress.filter(\.over).count), progress.contains(where: \.over) ? .loss : .primary)])
                        }
                    }
                }
                SideBySide(weights: [2, 1]) {
                    Card {
                        VStack(spacing: 0) {
                            BudgetRow(cells: [LS("分类"), LS("预算"), LS("已花"), LS("剩余")], ratio: nil, color: .secondary, picked: false)
                                .padding(.bottom, 6)
                            ForEach(progress) { item in
                                Divider()
                                BudgetRow(cells: [acctDisplay(item.budget.account), money(item.limit, item.budget.currency),
                                                  money(item.spent, item.budget.currency), money(item.remaining, item.budget.currency)],
                                          ratio: item.ratio, color: item.over ? .chartLoss : item.ahead ? .warn : .jade, picked: chosen?.id == item.id)
                                    .onTapGesture { picked = item.budget.account }
                            }
                        }
                    }
                    if let chosen {
                        BudgetSide(ledger: ledger, progress: chosen, byYear: byYear, month: month)
                    }
                }
            }
        }
        .toolbar { ToolbarItem { Button(LS("管理预算"), systemImage: "slider.horizontal.3") { managing = true } } }
        .sheet(isPresented: $managing) { BudgetManager(ledger: ledger, folder: folder) }
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
                    // drawn, not the system's bar: on the selection's green a green bar can't be told from it
                    GeometryReader { geometry in
                        Capsule().fill(picked ? Color.white.opacity(0.3) : Color.primary.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(picked ? Color.white : color).frame(width: geometry.size.width * min(max(ratio, 0), 1))
                            }
                    }
                    .frame(height: 4)
                } else {
                    Text(LS("进度")).frame(maxWidth: .infinity, alignment: .leading)
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

/// the picked budget: what went out in its last six months, each line it has had in the ledger, its largest entry and the way to what it counted
private struct BudgetSide: View {
    let ledger: Ledger
    let progress: BudgetProgress
    let byYear: Bool
    let month: String

    var body: some View {
        let account = progress.budget.account
        let span = MonthOrYear.span(byYear, month)
        let months = (0..<6).map { Day.addMonth(byYear ? String(span.1.prefix(7)) : month, $0 - 5) }
        let recent = months.map { month in ledger.budgetProgressKept(month).first { $0.budget.account == account }?.spent ?? 0 }
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: acctDisplay(account)) { Text(LS("近 6 个月")).foregroundStyle(.secondary) }
                Chart(Array(zip(months, recent)), id: \.0) { item in
                    BarMark(x: .value(LS("月"), String(Int(item.0.suffix(2)) ?? 0) + LS("月")), y: .value(LS("支出"), item.1))
                        .foregroundStyle(Color.jade.opacity(item.0 == months.last ? 1 : 0.45))
                        .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .frame(height: 96)
                .padding(.bottom, 8)
                FigureRow(label: LS("近 6 个月月均"), value: money(recent.reduce(0, +) / 6, progress.budget.currency))
                if let biggest = progress.biggest {
                    Divider()
                    FigureRow(label: LS("最大一笔"), caption: biggest.what + " · " + shortDay(biggest.date), value: money(biggest.amount, progress.budget.currency))
                }
                ForEach(ledger.budgetsKept().filter { $0.account == account }.reversed()) { budget in
                    Divider()
                    FigureRow(label: budget.date, caption: budget.period.name, value: money(budget.amount, budget.currency))
                }
                Divider()
                NavigationLink(value: JournalScope(title: acctDisplay(account) + " · " + MonthOrYear.title(byYear, month), account: account, from: span.0, to: span.1)) {
                    Label(LS("查看%@明细", acctDisplay(account)), systemImage: "list.bullet")
                }
                .buttonStyle(.link)
                .padding(.top, 8)
            }
        }
    }
}

/// what the spendable accounts will hold over the next 30, 60 or 90 days, its lowest point, and what comes in and goes out on the way
struct ForecastPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    @AppStorage("forecastDays") private var days = 30

    var body: some View {
        let result = ledger.forecastKept(days: days, payslips: config?.payslips ?? [], largeExpense: config?.largeExpense ?? 2000)
        ReportScaffold {
            Picker(selection: $days) {
                ForEach([30, 60, 90], id: \.self) { Text(LS("%@ 天", $0)).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        } content: {
            if result.accounts.isEmpty {
                ContentUnavailableView(LS("没有可用的账户"), systemImage: "chart.line.uptrend.xyaxis")
            } else {
                summary(result)
                SideBySide {
                    events(result)
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle(LS("计入的账户"))
                            ForEach(result.accounts, id: \.self) { account in
                                Divider()
                                FigureRow(label: accountTitle(ledger, account), value: "")
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(_ result: Forecast) -> some View {
        let lowest = result.lowest
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                Headline(label: LS("%@ 天后约", days), value: money(result.end, result.currency), color: result.end < 0 ? .loss : .primary)
                Chart {
                    ForEach(result.points) { point in
                        LineMark(x: .value(LS("日期"), Day.date(point.date) ?? Date()), y: .value(LS("余额"), point.value))
                            .foregroundStyle(Color.jade)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    }
                    PointMark(x: .value(LS("日期"), Day.date(lowest.date) ?? Date()), y: .value(LS("余额"), lowest.value))
                        .foregroundStyle(Color.warn)
                        .symbolSize(60)
                }
                .chartYAxis(.hidden)
                .frame(height: 180)
                SummaryFigures(items: [(LS("今天可用"), money(result.start, result.currency), .primary),
                                       (LS("最低 · ") + Day.dayLabel(lowest.date), money(lowest.value, result.currency), lowest.value < 0 ? .loss : .primary),
                                       (LS("日常支出 · 日均"), money(result.dailySpend, result.currency), .primary)])
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
                CardTitle(LS("预计收支"))
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

struct SubStateTarget: Identifiable {
    let id = UUID()
    let sub: Subscription
    let status: SubStatus
}

/// what subscriptions cost, the charges due but not in the ledger, every subscription, and regular payments that look like one
struct SubscriptionsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @State private var notice: String?
    @State private var editing: SubDraft?
    @State private var stateChange: SubStateTarget?
    @State private var deleting: Subscription?
    /// 记一笔扣费 opens the entry window as 记一笔 does
    @State private var tasks = EntryTasks()
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    /// what the save being asked about is called in 编辑 › 撤销
    @State private var step = ""

    var body: some View {
        let subs = ledger.subscriptionsKept()
        let active = subs.filter { $0.status == .active }
        let due = ledger.subscriptionsDueKept()
        let ignored = Set(config?.subsIgnored ?? [])
        let candidates = ledger.subscriptionCandidatesKept().filter { !ignored.contains($0.id) }
        let year = String(Day.today().prefix(4))
        let dueTotal = due.reduce(0.0) { $0 + inBase(ledger, $1.sub.amount, $1.sub.currency) }
        ReportScaffold {
            Card(summary: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Headline(label: LS("每月约"), value: money(active.reduce(0.0) { $0 + inBase(ledger, $1.monthly, $1.currency) }, ledger.base))
                    SummaryFigures(items: [(LS("%@ 年已付", year), money(subs.reduce(0.0) { $0 + inBase(ledger, $1.paid(in: year), $1.currency) }, ledger.base), .primary),
                                           (LS("订阅中"), LS("%@ 个", active.count), .primary),
                                           (LS("待记账"), money(dueTotal, ledger.base), due.isEmpty ? .primary : .warn)])
                }
            }
            SideBySide(weights: [2, 1]) {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(LS("订阅"))
                        ForEach(subs.sorted { ($0.status == .active ? 0 : 1, $0.name) < ($1.status == .active ? 0 : 1, $1.name) }) { sub in
                            Divider()
                            HStack(spacing: 8) {
                                NavigationLink(value: JournalScope(title: sub.name, account: nil, link: sub.link)) {
                                    FigureRow(label: sub.name, caption: caption(sub), value: money(sub.amount, sub.currency), color: sub.status == .active ? .primary : .secondary)
                                }
                                .buttonStyle(.plain)
                                Menu { actions(sub) } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel(LS("订阅操作"))
                            }
                            .contextMenu { actions(sub) }
                        }
                    }
                }
                // both kept when empty, so the column doesn't change with them
                VStack(spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle(title: LS("待记账")) { Text(money(dueTotal, ledger.base)).monospacedDigit().foregroundStyle(.secondary) }
                            ForEach(due) { item in
                                Divider()
                                HStack(spacing: 12) {
                                    FigureRow(label: item.sub.name, caption: shortDay(item.date) + LS(" 应扣费"), value: money(item.sub.amount, item.sub.currency), color: .warn)
                                    Button(LS("记一笔")) { record(item.sub) }
                                }
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle(title: LS("可能的订阅")) { Text(LS("%@ 个", candidates.count)).foregroundStyle(.secondary) }
                            ForEach(candidates) { candidate in
                                Divider()
                                HStack(spacing: 12) {
                                    FigureRow(label: candidate.payee, caption: LS("%@ · %@ 笔 · %@ 起", candidate.period.name, candidate.count, candidate.first),
                                              value: money(candidate.amount, candidate.currency))
                                    Button(LS("加入…")) { editing = SubDraft(candidate) }
                                    Button(LS("忽略")) { ignore(candidate) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert(notice ?? "", isPresented: $notice.present()) {}
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
        .toolbar { ToolbarItem { Button(LS("添加订阅"), systemImage: "plus") { editing = SubDraft(currency: ledger.base) } } }
        .sheet(item: $editing) { SubscriptionEditor(draft: $0, ledger: ledger, config: config, folder: folder) }
        .sheet(item: $stateChange) { SubscriptionStateEditor(sub: $0.sub, status: $0.status, folder: folder) }
        .confirmationDialog(LS("删除订阅「%@」？", deleting?.name ?? ""), isPresented: $deleting.present(), titleVisibility: .visible, presenting: deleting) { sub in
            let n = sub.charges.filter { $0.txn.links.contains(sub.link) }.count
            Button(n > 0 ? LS("删除，并移除 %@ 笔交易的链接", n) : LS("删除"), role: .destructive) { write(.delete(name: sub.name, unlink: true), LS("删除订阅")) }
            if n > 0 { Button(LS("删除，保留交易上的链接")) { write(.delete(name: sub.name, unlink: false), LS("删除订阅")) } }
        } message: { _ in
            Text(LS("删除这个订阅的全部记录，扣费交易本身保留。不再续费时建议改为「取消订阅」。"))
        }
        .folderReview(writer, $review, step: step) {}
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
    }

    private var writer: FolderWriter { FolderWriter(folder: folder, busy: $busy, message: $message, review: $review) }

    private func write(_ change: SubscriptionChange, _ step: String) {
        self.step = step
        writer.prepare(change, step: step)
    }

    /// the phone's actions on a subscription, from its ⋯ or a right-click
    @ViewBuilder private func actions(_ sub: Subscription) -> some View {
        if sub.status == .active {
            let next = sub.nextCharge(onOrAfter: Day.today())
            Button(sub.manual ? LS("记一笔续费…") : LS("记一笔扣费…")) { record(sub) }
            Button(LS("调价或更改…")) { editing = SubDraft(sub, mode: .change) }
            Button(LS("调整到期日…")) { editing = SubDraft(dueOf: sub) }
            Button(LS("跳过下一期（%@）", next)) { write(.skip(name: sub.name, due: next), LS("跳过一期")) }
            Button(LS("暂停…")) { stateChange = SubStateTarget(sub: sub, status: .paused) }
        } else {
            Button(LS("恢复订阅…")) { var d = SubDraft(sub, mode: .change); d.status = .active; editing = d }
        }
        Button(LS("修正记录…")) { editing = SubDraft(sub, mode: .correct) }
        Divider()
        if sub.status == .active {
            Button(LS("取消订阅…"), role: .destructive) { stateChange = SubStateTarget(sub: sub, status: .cancelled) }
        }
        Button(LS("删除订阅…"), role: .destructive) { deleting = sub }
    }

    private func record(_ sub: Subscription) {
        if let draft = subscriptionChargeDraft(sub, ledger, config) {
            tasks.editing = EntryTasks.Edited(draft: draft)
        } else {
            notice = LS("请先为「%@」设置支出科目和付款账户", sub.name)
        }
    }

    private func caption(_ sub: Subscription) -> String {
        guard sub.status == .active else { return sub.status.name }
        let next = sub.due(onOrAfter: Day.shift(Day.today(), 1))
        return sub.period.name + " · " + accountTitle(ledger, sub.paymentAccount) + LS(" · 下次 ") + shortDay(next)
    }

    /// set aside for good, on every device: ledger-x.json, as the phone keeps it
    private func ignore(_ candidate: SubCandidate) {
        do {
            let save = try prepareFolderConfig(folder: folder) { config in
                var ids = config.subsIgnored ?? []
                if !ids.contains(candidate.id) { ids.append(candidate.id) }
                config.subsIgnored = ids
            }.get()
            try SaveUndo.commit(save, folder: folder, name: LS("忽略订阅"))
        } catch {
            notice = error.localizedDescription
        }
    }
}
