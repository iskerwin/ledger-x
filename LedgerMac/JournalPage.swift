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
    let sort: [KeyPathComparator<JournalRow>]
}

/// what the table shows, worked out away from the main thread
private struct Built {
    var lines: [JournalRow] = []
    var balances: [ObjectIdentifier: Inventory] = [:]
    var widths = EntryWidths()
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
    @State private var built = Built()
    @State private var selected = Set<String>()
    /// where a shift-click runs from
    @State private var anchor: String?
    @State private var sortOrder = [KeyPathComparator(\JournalRow.date, order: .reverse)]
    @FocusState private var listFocused: Bool
    @State private var tasks = EntryTasks()

    private var key: LinesKey {
        LinesKey(ledger: ObjectIdentifier(ledger), text: text, period: period, kind: kind, day: day, sort: sortOrder)
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
            let layout = built.widths.fit(EntryColumn.allCases, in: geometry.size.width)
            let columns = layout.columns, pickedID = pickedID
            VStack(spacing: 0) {
                EntryHeader(columns: columns, widths: layout.widths, sortOrder: $sortOrder)
                Divider()
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(lines.indices, id: \.self) { index in
                                let line = lines[index]
                                VStack(spacing: 0) {
                                    EntryRow(line: line, ledger: ledger, columns: columns, widths: layout.widths, picked: selected.contains(line.id),
                                             balance: built.balances[ObjectIdentifier(line.entry)])
                                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                                        .onTapGesture { click(line.id) }
                                        .contextMenu { menu(line) }
                                    if pickedID == line.id {
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

    @ViewBuilder private func menu(_ line: JournalRow) -> some View {
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

    /// the rows of the whole ledger are worked out once for it; picking from them, sorting and measuring them happen
    /// off the main thread, so typing in the search box doesn't wait for them
    private func rebuild() async {
        let ledger = ledger, scope = scope, kind = kind, sortOrder = sortOrder, held = heldAccount
        let query = TxQuery(text)
        let span: (String, String)? = day.map { ($0, $0) } ?? period?.span
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
        built = next
        let shown = Set(next.lines.map(\.id))
        if !selected.isSubset(of: shown) { selected.formIntersection(shown) }
    }

    /// the account in view when what it holds adds up over time; a category only has totals for a period
    private var heldAccount: String? {
        scope?.account.flatMap { $0.hasPrefix("Assets") || $0.hasPrefix("Liabilities") ? $0 : nil }
    }
}

extension Entry {
    var key: String { "\(file):\(line)" }
}
