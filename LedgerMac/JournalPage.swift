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

/// what else the journal lists besides the ledger's transactions, as Fava's entry filters
private enum Shown: String, CaseIterable {
    case txn, pad, balance, note, document

    var title: String {
        switch self {
        case .txn: return "交易"
        case .pad: return "pad"
        case .balance: return "余额断言"
        case .note: return "备注"
        case .document: return "文档"
        }
    }

    /// what a new window shows
    static let usual = "txn,pad"
}

/// what the table's rows depend on: anything else redrawing the page doesn't work them out again
private struct LinesKey: Hashable {
    let ledger: ObjectIdentifier
    let text: String
    let period: ViewPeriod
    let account: String?
    let kind: KindFilter
    let shown: String
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
    /// the window's search, as Fava's filter: the reports read the same
    @Binding var text: String
    /// what's typed, once typing pauses: what the list keeps to
    let query: String
    @State private var kind = KindFilter.all
    @State private var built = Built()
    @State private var selected = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\JournalRow.date, order: .reverse)]
    /// the kinds of entry listed, by name, comma-separated
    @AppStorage("journalShown") private var shownRaw = Shown.usual
    /// each entry's account lines under it
    @AppStorage("journalPostings") private var postings = false
    @State private var tasks = EntryTasks()

    private var key: LinesKey {
        LinesKey(ledger: ObjectIdentifier(ledger), text: query, period: period, account: account, kind: kind, shown: shownRaw, sort: sortOrder)
    }

    private var lines: [JournalRow] { built.lines }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            if lines.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                list
            }
        }
        .filtering($text, $searching)
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
            HStack(spacing: 4) {
                ForEach(Shown.allCases, id: \.self) { item in
                    Toggle(item.title, isOn: showing(item)).toggleStyle(.button)
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                Toggle("分录", isOn: $postings).toggleStyle(.button)
            }
            .controlSize(.small)
            Spacer()
            Text("\(lines.count) 笔").monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        EntryList(lines: lines, generation: built.generation, balances: built.balances, widths: built.widths,
                  ledger: ledger, config: config, folder: folder, sortOrder: $sortOrder, selected: $selected, tasks: $tasks,
                  postings: postings, focus: !searching)
    }

    private var shown: Set<Shown> { Set(shownRaw.split(separator: ",").compactMap { Shown(rawValue: String($0)) }) }

    private func showing(_ item: Shown) -> Binding<Bool> {
        Binding(get: { shown.contains(item) }, set: { on in
            var next = shown
            if on { next.insert(item) } else { next.remove(item) }
            shownRaw = Shown.allCases.filter(next.contains).map(\.rawValue).joined(separator: ",")
        })
    }

    /// the rows of the whole ledger are worked out once for it; picking from them, sorting and measuring them happen
    /// off the main thread, so typing in the search box doesn't wait for them
    private func rebuild() async {
        let ledger = ledger, scope = shownScope, kind = kind, sortOrder = sortOrder, held = heldAccount, shown = shown
        let query = TxQuery(self.query)
        let span: (String, String)? = self.scope == nil ? period.span : nil
        let next = await Task.detached { () -> Built in
            let transactions = journalRows(ledger, account: held).filter { line in
                let entry = line.entry
                guard shown.contains(entry.synthetic ? .pad : .txn) else { return false }
                if let scope, !scope.matches(entry) { return false }
                if let span, entry.date < span.0 || entry.date > span.1 { return false }
                return kind.matches(line.kind) && query.matches(entry, ledger)
            }
            // what's on an account: none for a kind of transaction, a search, or a reimbursement's batch
            let wanted = shown.subtracting([.txn, .pad])
            let directives = wanted.isEmpty || kind != .all || !query.isEmpty || scope?.link != nil ? [] :
                journalDirectives(ledger, account: scope?.account).filter { line in
                    let date = line.entry.date
                    return wanted.contains { $0.rawValue == line.directive?.rawValue }
                        && (span.map { date >= $0.0 && date <= $0.1 } ?? true)
                        && (scope?.from.map { date >= $0 } ?? true) && (scope?.to.map { date <= $0 } ?? true)
                }
            let lines = (transactions + directives).sorted(using: sortOrder)
            let balances = held.map { ledger.runningBalancesKept($0) } ?? [:]
            return Built(lines: lines, balances: balances, widths: EntryWidths.measure(lines, balances: balances))
        }.value
        guard !Task.isCancelled else { return }
        var fresh = next
        fresh.generation = built.generation + 1
        built = fresh
        let listed = Set(next.lines.map(\.id))
        if !selected.isSubset(of: listed) { selected.formIntersection(listed) }
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
