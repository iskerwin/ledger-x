import SwiftUI
import LedgerKit

/// 报销 on one page, as on the phone: what's waiting, the batches still open, what's waiting to be claimed, and the years settled
struct ReimbursementsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL

    var body: some View {
        let derived = folderDerived(ledger, config: config)
        let waiting = derived.unclaimed
        let batches = reimbBatches(ledger)
        let open = batches.filter { !$0.settled }
        let settled = batches.filter(\.settled)
        let receivable = config?.receivable ?? "Assets:Receivable:Reimbursement"
        let owed = (ledger.final[receivable] ?? [:]).reduce(0.0) { $0 + inBase(ledger, $1.value, $1.key) }
        ReportScaffold {
            Card(summary: true) {
                SummaryFigures(items: [("待报销", money(waiting.reduce(0.0) { $0 + inBase(ledger, $1.amount, $1.currency, on: $1.t.date) }, ledger.base), .primary),
                                       ("进行中", "\(open.count) 张", .primary),
                                       ("报销应收余额", money(owed, ledger.base), .primary)])
            }
            if !open.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle("进行中")
                        ForEach(open) { batch in
                            Divider()
                            NavigationLink(value: JournalScope(title: batchTitle(batch), account: nil, link: batch.link)) {
                                FigureRow(label: batchTitle(batch), caption: "\(shortDay(batch.first))–\(shortDay(batch.last)) · \(batch.count) 笔",
                                          value: (batch.kind == .float ? "剩 " : "待回款 ") + money(abs(batch.balance), batch.currency))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            EntryListCard(entries: Array(waiting.map(\.t).reversed()), ledger: ledger, config: config, folder: folder) {
                CardTitle("待报销 · \(waiting.count) 笔")
            }
            if !settled.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle("已结清")
                        ForEach(years(settled), id: \.0) { year in
                            Divider()
                            FigureRow(label: "\(year.0) 年", caption: "\(year.1.count) 张单子",
                                      value: money(year.1.reduce(0.0) { $0 + inBase(ledger, $1.advanced, $1.currency, on: $1.last) }, ledger.base))
                        }
                    }
                }
            }
        }
    }

    private func batchTitle(_ batch: ReimbBatch) -> String {
        batch.kind == .float ? "备用金" + (batch.payer.isEmpty ? "" : " · " + batch.payer) : (batch.payer.isEmpty ? batch.link : batch.payer)
    }

    private func years(_ batches: [ReimbBatch]) -> [(String, [ReimbBatch])] {
        Dictionary(grouping: batches) { String($0.last.prefix(4)) }.sorted { $0.key > $1.key }
    }
}

/// the employers paying a salary, and the picked one's months in a year: each month opens in place with its source
struct SalaryPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @State private var picked: String?

    var body: some View {
        let slips = ledger.txns.filter { $0.links.contains { $0.hasPrefix("salary-") } && payslipFigures($0, ledger) != nil }
        let employers = employerNames(slips)
        SplitPage {
            ForEach(employers, id: \.self) { name in
                let last = slips.last { $0.payee == name }
                PickRow(title: name, caption: last.map { "上次 " + String($0.date.prefix(7)) } ?? "", picked: (picked ?? employers.first) == name) { picked = name }
            }
        } detail: {
            if let name = picked ?? employers.first {
                EmployerDetail(ledger: ledger, config: config, folder: folder, name: name, slips: slips.filter { $0.payee == name }).id(name)
            }
        }
    }

    /// as ledger-x.json lists them, then any others paid, the latest first
    private func employerNames(_ slips: [Entry]) -> [String] {
        var names = (config?.payslips ?? []).map(\.employer)
        for entry in slips.reversed() where !entry.payee.isEmpty && !names.contains(entry.payee) { names.append(entry.payee) }
        return names
    }
}

private struct EmployerDetail: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let name: String
    let slips: [Entry]
    @State private var year = String(Day.today().prefix(4))
    @State private var open: String?
    @State private var tasks = EntryTasks()

    var body: some View {
        let years = Array(Set(slips.map { String($0.date.prefix(4)) })).sorted(by: >)
        let shown = slips.filter { $0.date.hasPrefix(year) }.reversed().compactMap { entry in payslipFigures(entry, ledger).map { Slip(entry: entry, figures: $0) } }
        let sum = { (part: (PayslipFigures) -> Double) in shown.reduce(0.0) { $0 + part($1.figures) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(name).font(.title2.weight(.semibold))
                    Spacer()
                    if years.count > 1 {
                        Picker(selection: $year) {
                            ForEach(years.prefix(6), id: \.self) { Text($0).tag($0) }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Card(summary: true) {
                    SummaryFigures(items: [("税前", money(sum(\.gross), ledger.base), .primary),
                                           ("个税", money(sum(\.tax), ledger.base), .primary),
                                           ("实发", money(sum(\.net), ledger.base), .gain)])
                }
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        SlipRow(cells: ["月份", "应发", "扣款", "个税", "实发"], heading: true)
                            .padding(.bottom, 6)
                        ForEach(shown) { slip in
                            let entry = slip.entry, figures = slip.figures
                            Divider()
                            SlipRow(cells: [String(entry.date.prefix(7)), money(figures.gross, ledger.base), money(figures.deductions, ledger.base),
                                            money(figures.tax, ledger.base), money(figures.net, ledger.base)], heading: false, picked: open == entry.key)
                                .onTapGesture { open = open == entry.key ? nil : entry.key }
                            if open == entry.key {
                                SourcePanel(entry: entry, ledger: ledger, config: config, folder: folder, tasks: $tasks)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { if let latest = years.first, !years.contains(year) { year = latest } }
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
    }
}

private struct Slip: Identifiable {
    let entry: Entry
    let figures: PayslipFigures
    var id: String { entry.key }
}

private struct SlipRow: View {
    let cells: [String]
    let heading: Bool
    var picked = false

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(heading ? Color.secondary : picked ? Color.white : Color.primary)
        .padding(.vertical, heading ? 0 : 8)
        .padding(.horizontal, 6)
        .background(picked ? Color.jade : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// the events, going on first; the picked one's totals, by category, and its entries opening in place
struct EventsPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @State private var picked: String?

    var body: some View {
        let today = Day.today()
        let events = ledgerEvents(ledger)
        let going = events.filter { $0.start <= today && ($0.end.map { $0 >= today } ?? true) }
        let ended = events.filter { event in !going.contains { $0.tag == event.tag } }
        let receivable = config?.receivable ?? "Assets:Receivable:Reimbursement"
        SplitPage {
            ForEach([("进行中", going), ("已结束", ended)], id: \.0) { section in
                if !section.1.isEmpty {
                    Text(section.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
                    ForEach(section.1) { event in
                        let summary = eventSummary(ledger, event.tag, reimbursement: receivable)
                        PickRow(title: event.title, caption: "#\(event.tag) · \(shortDay(event.start)) 起 · \(summary.txns.count) 笔",
                                trailing: money(summary.total, ledger.base), picked: (picked ?? events.first?.tag) == event.tag) { picked = event.tag }
                    }
                }
            }
        } detail: {
            if let event = events.first(where: { $0.tag == (picked ?? events.first?.tag) }) {
                EventDetail(ledger: ledger, config: config, folder: folder, event: event, summary: eventSummary(ledger, event.tag, reimbursement: receivable))
                    .id(event.tag)
            }
        }
    }
}

private struct EventDetail: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let event: LedgerEvent
    let summary: EventSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.title2.weight(.semibold))
                    Text("#\(event.tag) · \(event.start)" + (event.end.map { " – \($0)" } ?? " 起")).foregroundStyle(.secondary)
                }
                Card(summary: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        Headline(label: "一共", value: money(summary.total, ledger.base))
                        SummaryFigures(items: [("其中未报销", money(summary.unpaid, ledger.base), .primary),
                                               ("自己的支出", money(summary.spent, ledger.base), .primary)])
                    }
                }
                if !summary.byCategory.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            CardTitle("分类")
                            ForEach(summary.byCategory, id: \.account) { item in
                                Divider()
                                FigureRow(label: acctDisplay(item.account), value: money(item.amount, ledger.base))
                            }
                        }
                    }
                }
                EntryListCard(entries: Array(summary.txns.reversed()), ledger: ledger, config: config, folder: folder,
                              columns: [.date, .payee, .category, .accounts, .amount]) {
                    CardTitle("交易")
                }
            }
            .padding(20)
        }
    }
}
