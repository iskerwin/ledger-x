import SwiftUI
import LedgerKit

private enum KindFilter: String, CaseIterable {
    case all = "全部", expense = "支出", income = "收入", transfer = "转账"

    func matches(_ kind: TxKind) -> Bool {
        switch self {
        case .all: return true
        case .expense: return kind == .expense || kind == .refund
        case .income: return kind == .income
        case .transfer: return kind == .transfer
        }
    }
}

/// what the table's rows depend on: anything else redrawing the page doesn't work them out again
private struct LinesKey: Hashable {
    let ledger: ObjectIdentifier
    let text: String
    let period: ReportPeriod?
    let kind: KindFilter
    let day: String?
    let sort: [KeyPathComparator<EntryLine>]
}

struct JournalPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let scope: JournalScope?
    @Binding var searching: Bool
    @State private var text = ""
    @State private var period: ReportPeriod?
    @State private var kind = KindFilter.all
    @State private var day: String?
    @State private var choosingDay = false
    @State private var lines: [EntryLine] = []
    @State private var balances: [ObjectIdentifier: Inventory] = [:]
    @State private var widths = EntryWidths()
    @State private var selected = Set<String>()
    /// where a shift-click runs from
    @State private var anchor: String?
    @State private var sortOrder = [KeyPathComparator(\EntryLine.date, order: .reverse)]
    @FocusState private var listFocused: Bool
    @State private var tasks = EntryTasks()

    private var key: LinesKey {
        LinesKey(ledger: ObjectIdentifier(ledger), text: text, period: period, kind: kind, day: day, sort: sortOrder)
    }

    /// the one picked, open under its row; several picked have nothing single to show
    private var picked: Entry? {
        guard selected.count == 1, let id = selected.first else { return nil }
        return lines.first { $0.id == id }?.entry
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            if lines.isEmpty && !text.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                list
            }
        }
        .searchable(text: $text, isPresented: $searching, placement: .toolbar)
        .onAppear { rebuild() }
        .onChange(of: key) { rebuild() }
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
    }

    /// when, what kind, how many; a report's own span stays what it is
    private var filters: some View {
        HStack(spacing: 12) {
            if scope?.from == nil {
                Picker(selection: $period) {
                    Text("全部时间").tag(ReportPeriod?.none)
                    ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title).tag(ReportPeriod?.some($0)) }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .disabled(day != nil)
            }
            Picker(selection: $kind) {
                ForEach(KindFilter.allCases, id: \.self) { Text($0.rawValue) }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            Button { choosingDay = true } label: {
                Label(day.map { Day.dayLabel($0) } ?? "月历", systemImage: "calendar")
            }
            .popover(isPresented: $choosingDay) {
                DayPicker(title: "日期", day: Binding(get: { day ?? Day.today() }, set: {
                    day = $0
                    choosingDay = false
                }))
                .padding(12)
            }
            if day != nil {
                Button("回到当前期间", systemImage: "xmark.circle.fill") { day = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(lines.count) 笔").monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// rows of our own rather than a table: the amount keeps its width at the end, and the picked row opens in place
    private var list: some View {
        GeometryReader { geometry in
            let layout = widths.fit(EntryColumn.allCases, in: geometry.size.width)
            let columns = layout.columns
            VStack(spacing: 0) {
                EntryHeader(columns: columns, widths: layout.widths, sortOrder: $sortOrder)
                Divider()
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                VStack(spacing: 0) {
                                    EntryRow(line: line, ledger: ledger, columns: columns, widths: layout.widths, picked: selected.contains(line.id),
                                             account: heldAccount, balance: balances[ObjectIdentifier(line.entry)])
                                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                                        .onTapGesture { click(line.id) }
                                        .contextMenu { menu(line) }
                                    if picked.map({ $0.key == line.id }) == true {
                                        SourcePanel(entry: line.entry, ledger: ledger, config: config, folder: folder, tasks: $tasks)
                                    }
                                }
                                .id(line.id)
                            }
                        }
                        // ↑ ↓ go through the rows, as in a list: on the content, since the scroll view takes the arrows for scrolling
                        .focusable()
                        .focused($listFocused)
                        .focusEffectDisabled()
                        .onMoveCommand { direction in
                            guard !lines.isEmpty else { return }
                            let at = selected.count == 1 ? selected.first.flatMap { id in lines.firstIndex { $0.id == id } } ?? -1 : -1
                            let next: Int
                            switch direction {
                            case .up: next = max(0, at - 1)
                            case .down: next = min(lines.count - 1, at + 1)
                            default: return
                            }
                            selected = [lines[next].id]
                            anchor = lines[next].id
                            scroller.scrollTo(lines[next].id)
                        }
                        .onKeyPress(.return) {
                            guard let entry = picked, !entry.synthetic else { return .ignored }
                            tasks.edit(entry, ledger, config)
                            return .handled
                        }
                        .onDeleteCommand { tasks.deleting = picked.flatMap { $0.synthetic ? nil : $0 } }
                        .onExitCommand { selected = [] }
                    }
                }
            }
        }
        .onAppear { if !searching { listFocused = true } }
    }

    /// a click picks the row (again, puts it away); ⌘ adds or takes one, ⇧ runs from the last one picked
    private func click(_ id: String) {
        listFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let from = lines.firstIndex(where: { $0.id == anchor }),
                  let to = lines.firstIndex(where: { $0.id == id }) {
            selected = Set(lines[min(from, to)...max(from, to)].map(\.id))
        } else {
            selected = selected == [id] ? [] : [id]
            anchor = id
        }
    }

    @ViewBuilder private func menu(_ line: EntryLine) -> some View {
        let chosen = selected.contains(line.id) ? lines.filter { selected.contains($0.id) }.map(\.entry) : [line.entry]
        if chosen.count == 1, let entry = chosen.first {
            Button("编辑…") { tasks.edit(entry, ledger, config) }.disabled(entry.synthetic)
            Button("复制原文") { EntryTasks.copy(chosen) }
            Button("打开所在文件") { EntryTasks.open(entry, in: folder) }
            Divider()
            Button("删除…", role: .destructive) { tasks.deleting = entry }.disabled(entry.synthetic)
        } else {
            Button("复制 \(chosen.count) 笔原文") { EntryTasks.copy(chosen) }
        }
    }

    private func rebuild() {
        let query = TxQuery(text)
        let span: (String, String)? = day.map { ($0, $0) } ?? period?.span
        var built: [EntryLine] = []
        for entry in ledger.txns.reversed() {
            if let scope, !scope.matches(entry) { continue }
            if let span, entry.date < span.0 || entry.date > span.1 { continue }
            guard query.matches(entry, ledger) else { continue }
            let line = EntryLine(entry, ledger)
            if kind.matches(line.kind) { built.append(line) }
        }
        lines = built.sorted(using: sortOrder)
        balances = heldAccount.map { runningBalances(ledger, account: $0) } ?? [:]
        widths = EntryWidths.measure(lines, ledger, account: heldAccount, balances: balances)
        let shown = Set(lines.map(\.id))
        if !selected.isSubset(of: shown) { selected.formIntersection(shown) }
    }

    /// the account in view when what it holds adds up over time; a category only has totals for a period
    private var heldAccount: String? {
        scope?.account.flatMap { $0.hasPrefix("Assets") || $0.hasPrefix("Liabilities") ? $0 : nil }
    }
}

extension Entry {
    var key: String { "\(file):\(line)" }

    /// where it went: its category, or for what has none the accounts the money went through
    var route: String {
        let categories = postings.filter { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }
        return moneyRoute(self).filter { account in !categories.contains { $0.account == account } }.map(acctDisplay).joined(separator: " → ")
    }

    func isCategory(_ posting: Posting) -> Bool {
        posting.account.hasPrefix("Expenses:") || posting.account.hasPrefix("Income:")
    }

    /// as in the phone's journal: what moved in the account being looked through, else a transfer's amount, else what was
    /// spent or earned in each currency as booked. A transfer that paid a fee shows both what it moved and the fee
    func shownAmounts(_ ledger: Ledger, account: String? = nil) -> [(String, Color)] {
        if let account {
            return sums(postings.filter { $0.account == account || $0.account.hasPrefix(account + ":") }, negate: false).map(signed)
        }
        let shown = classify(self, ledger)
        if shown.kind == .transfer { return [(money(shown.amount, shown.currency ?? "CNY"), .secondary)] }
        let spent = sums(postings.filter(isCategory), negate: true).map(signed)
        if let moved = transferWithFee(self) { return [(money(moved.amount, moved.currency), .secondary)] + spent }
        return spent
    }

    /// what the account was charged in another currency, for checking against the bank
    func charged(_ ledger: Ledger) -> [(String, Double)] {
        guard classify(self, ledger).kind != .transfer else { return [] }
        let own = sums(postings.filter(isCategory), negate: true)
        return sums(postings.filter { !isCategory($0) && !$0.account.hasPrefix("Equity:") }, negate: false)
            .filter { paid in !own.contains { $0.0 == paid.0 } }
    }

    private func signed(_ amount: (String, Double)) -> (String, Color) {
        (signedMoney(amount.1, amount.0), amount.1 < 0 ? .loss : .gain)
    }

    /// per currency, in the order they first appear (amounts too small to show left out)
    private func sums(_ postings: [Posting], negate: Bool) -> [(String, Double)] {
        var order: [String] = [], totals: [String: Double] = [:]
        for posting in postings {
            guard let units = posting.units, let currency = posting.currency else { continue }
            if totals[currency] == nil { order.append(currency) }
            totals[currency, default: 0] += negate ? -units : units
        }
        return order.compactMap { abs(totals[$0]!) > 0.004 ? ($0, totals[$0]!) : nil }
    }
}
