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

/// how the rows in sight look besides the list: the table draws them again when it changes
private struct TableLook: Hashable {
    let generation: Int
    let columns: [EntryColumn]
    let widths: [EntryColumn: CGFloat]
    let hidden: Bool
}

/// what the table's rows depend on: anything else redrawing the page doesn't work them out again
private struct LinesKey: Hashable {
    let ledger: ObjectIdentifier
    let text: String
    let period: ViewPeriod
    let account: String?
    let kind: KindFilter
    let sort: [KeyPathComparator<JournalRow>]
}

/// what the table shows, worked out away from the main thread
private struct Built {
    /// counts the lists worked out, for the table to know a new one
    var generation = 0
    var lines: [JournalRow] = []
    var balances: [ObjectIdentifier: Inventory] = [:]
    var widths = EntryWidths()
}

struct JournalPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    /// what a row counted, a level down; the window's time and account apply only to the whole journal
    let scope: JournalScope?
    let period: ViewPeriod
    let account: String?
    @Binding var searching: Bool
    @State private var text = ""
    @State private var kind = KindFilter.all
    @State private var built = Built()
    @State private var selected = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\JournalRow.date, order: .reverse)]
    @AppStorage("hideAmounts") private var hideAmounts = false
    @State private var tasks = EntryTasks()

    private var key: LinesKey {
        LinesKey(ledger: ObjectIdentifier(ledger), text: text, period: period, account: account, kind: kind, sort: sortOrder)
    }

    private var lines: [JournalRow] { built.lines }

    /// the one picked, open under its row; several picked have nothing single to show
    private var pickedID: String? { selected.count == 1 ? selected.first : nil }

    private var picked: Entry? {
        pickedID.flatMap { id in lines.first { $0.id == id }?.entry }
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
        // a change made while the last one is still being worked out takes its place
        .task(id: key) { await rebuild() }
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
    }

    /// what kind, how many; when and which account are the window's, in the toolbar
    private var filters: some View {
        HStack(spacing: 12) {
            Picker(selection: $kind) {
                ForEach(KindFilter.allCases, id: \.self) { Text($0.rawValue) }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("\(lines.count) 笔").monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// our own rows on an AppKit table: the amount keeps its width at the end, the picked row opens in place, and only
    /// the rows in sight are drawn
    private var list: some View {
        GeometryReader { geometry in
            let layout = built.widths.fit(EntryColumn.allCases, in: geometry.size.width)
            let columns = layout.columns
            VStack(spacing: 0) {
                EntryHeader(columns: columns, widths: layout.widths, sortOrder: $sortOrder)
                Divider()
                EntryTable(lines: lines,
                           look: TableLook(generation: built.generation, columns: columns, widths: layout.widths, hidden: hideAmounts),
                           selected: $selected,
                           row: { line, index, picked in
                               AnyView(EntryRow(line: line, ledger: ledger, columns: columns, widths: layout.widths, picked: picked,
                                                balance: built.balances[ObjectIdentifier(line.entry)])
                                   .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035)))
                           },
                           panel: { line in AnyView(SourcePanel(entry: line.entry, ledger: ledger, config: config, folder: folder, tasks: $tasks)) },
                           menu: menu,
                           open: {
                               guard let entry = picked, !entry.synthetic else { return }
                               tasks.edit(entry, ledger, config)
                           },
                           delete: { tasks.deleting = picked.flatMap { $0.synthetic ? nil : $0 } },
                           focus: !searching)
            }
        }
    }

    private func menu(_ chosen: [JournalRow]) -> [TableMenuItem] {
        let entries = chosen.map(\.entry)
        guard entries.count == 1, let entry = entries.first else {
            return [TableMenuItem(title: "复制 \(entries.count) 笔原文") { EntryTasks.copy(entries) }]
        }
        return [TableMenuItem(title: "编辑…", enabled: !entry.synthetic) { tasks.edit(entry, ledger, config) },
                TableMenuItem(title: "复制原文") { EntryTasks.copy(entries) },
                TableMenuItem(title: "打开所在文件") { EntryTasks.open(entry, in: folder) },
                .divider,
                TableMenuItem(title: "删除…", enabled: !entry.synthetic) { tasks.deleting = entry }]
    }

    /// the rows of the whole ledger are worked out once for it; picking from them, sorting and measuring them happen
    /// off the main thread, so typing in the search box doesn't wait for them
    private func rebuild() async {
        let ledger = ledger, scope = shownScope, kind = kind, sortOrder = sortOrder, held = heldAccount
        let query = TxQuery(text)
        let span: (String, String)? = self.scope == nil ? period.span : nil
        let next = await Task.detached { () -> Built in
            let lines = journalRows(ledger, account: held).filter { line in
                let entry = line.entry
                if let scope, !scope.matches(entry) { return false }
                if let span, entry.date < span.0 || entry.date > span.1 { return false }
                return kind.matches(line.kind) && query.matches(entry, ledger)
            }
            .sorted(using: sortOrder)
            let balances = held.map { account in ledger.memoized("runningBalances|" + account) { runningBalances(ledger, account: account) } } ?? [:]
            return Built(lines: lines, balances: balances, widths: EntryWidths.measure(lines, balances: balances))
        }.value
        guard !Task.isCancelled else { return }
        var fresh = next
        fresh.generation = built.generation + 1
        built = fresh
        let shown = Set(next.lines.map(\.id))
        if !selected.isSubset(of: shown) { selected.formIntersection(shown) }
    }

    /// a row's entries, else the account picked for the whole journal
    private var shownScope: JournalScope? {
        scope ?? account.map { JournalScope(title: "", account: $0) }
    }

    /// the account in view when what it holds adds up over time; a category only has totals for a period
    private var heldAccount: String? {
        shownScope?.account.flatMap { $0.hasPrefix("Assets") || $0.hasPrefix("Liabilities") ? $0 : nil }
    }
}

extension Entry {
    var key: String { "\(file):\(line)" }
}
