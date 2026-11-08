import SwiftUI
import LedgerKit

/// one row of the table, with what it sorts by worked out once
private struct JournalLine: Identifiable {
    let entry: Entry
    let id: String
    let date: String
    let payee: String
    let category: String
    let accounts: String
    let amount: Double
    let kind: TxKind

    init(_ entry: Entry, _ ledger: Ledger) {
        self.entry = entry
        id = entry.key
        date = entry.date
        payee = entry.payee.isEmpty ? (entry.narration.isEmpty ? "（无收付款方）" : entry.narration) : entry.payee
        category = shownCategory(entry).map(acctDisplay) ?? "转账"
        accounts = entry.route
        let shown = classify(entry, ledger)
        amount = shown.amount
        kind = shown.kind
    }
}

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
    let sort: [KeyPathComparator<JournalLine>]
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
    @State private var lines: [JournalLine] = []
    @State private var balances: [ObjectIdentifier: Inventory] = [:]
    @State private var selected = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\JournalLine.date, order: .reverse)]
    @State private var columns = TableColumnCustomization<JournalLine>()
    @AppStorage("journalColumns") private var savedColumns = Data()
    @AppStorage("journalDetail") private var showsDetail = true
    @FocusState private var listFocused: Bool
    @State private var editing: EditedEntry?
    @State private var deleting: Entry?
    @State private var review: FolderSave?
    @State private var notice: String?

    private struct EditedEntry: Identifiable {
        let id = UUID()
        let draft: Draft
    }

    private var key: LinesKey {
        LinesKey(ledger: ObjectIdentifier(ledger), text: text, period: period, kind: kind, day: day, sort: sortOrder)
    }

    /// the one picked; several picked have nothing single to show
    private var picked: Entry? {
        guard selected.count == 1, let id = selected.first else { return nil }
        return lines.first { $0.id == id }?.entry
    }

    var body: some View {
        // a column of its own beside the table: an inspector lets the table run on under it, its last columns hidden there
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filters
                Divider()
                if lines.isEmpty && !text.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    table
                }
            }
            if showsDetail {
                Divider()
                // always there, so picking a row moves nothing
                Group {
                    if let entry = picked {
                        EntryDetail(entry: entry, ledger: ledger, edit: { edit(entry) }, copy: { copySource([entry]) }, open: { openFile(entry) }, delete: { deleting = entry })
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 300)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsDetail.toggle() } label: { Label("详情", systemImage: "sidebar.right") }
                    .help("详情")
            }
        }
        .searchable(text: $text, isPresented: $searching, placement: .toolbar)
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<JournalLine>.self, from: savedColumns) { columns = saved }
            rebuild()
        }
        .onChange(of: key) { rebuild() }
        .onChange(of: columns) { savedColumns = (try? JSONEncoder().encode(columns)) ?? Data() }
        .sheet(item: $editing) { NewEntrySheet(ledger: ledger, config: config, folder: folder, editing: $0.draft) }
        .alert("删除这笔交易？", isPresented: present($deleting), presenting: deleting) { entry in
            Button("删除", role: .destructive) { delete(entry) }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text(deleteMessage(entry))
        }
        .alert(review?.issues.first?.title ?? "", isPresented: present($review), presenting: review) { save in
            if !save.issues.contains(where: \.blocking) {
                Button("仍然删除", role: .destructive) { write(save) }
            }
            Button("取消", role: .cancel) {}
        } message: { save in
            Text(save.issues.map(\.detail).joined(separator: "\n"))
        }
        .alert(notice ?? "", isPresented: present($notice)) {}
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

    private var table: some View {
        Table(lines, selection: $selected, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("日期", value: \.date) { line in
                Text(shortDate(line.date)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 72, max: 110)
            .customizationID("date")
            TableColumn("收付款方", value: \.payee) { line in
                PayeeCell(entry: line.entry, ledger: ledger, title: line.payee)
            }
            .width(min: 160, ideal: 280)
            .customizationID("payee")
            TableColumn("分类", value: \.category) { line in
                Text(line.category).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 130)
            .customizationID("category")
            TableColumn("账户", value: \.accounts) { line in
                Text(line.accounts + withWhom(line.entry)).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 170)
            .customizationID("accounts")
            TableColumn("状态") { line in
                StatusCell(entry: line.entry)
            }
            .width(min: 40, ideal: 90)
            .customizationID("status")
            TableColumn("金额", value: \.amount) { line in
                AmountCell(entry: line.entry, ledger: ledger, account: heldAccount, balance: balances[ObjectIdentifier(line.entry)])
            }
            .width(min: 90, ideal: 120)
            .alignment(.trailing)
            .customizationID("amount")
        }
        .focused($listFocused)
        .onAppear { if !searching { listFocused = true } }
        // the system's own: double-click or Return for the primary action
        .contextMenu(forSelectionType: String.self) { keys in
            let chosen = lines.filter { keys.contains($0.id) }.map(\.entry)
            if chosen.count == 1, let entry = chosen.first {
                Button("编辑…") { edit(entry) }.disabled(entry.synthetic)
                Button("复制原文") { copySource(chosen) }
                Button("打开所在文件") { openFile(entry) }
                Divider()
                Button("删除…", role: .destructive) { deleting = entry }.disabled(entry.synthetic)
            } else if !chosen.isEmpty {
                Button("复制 \(chosen.count) 笔原文") { copySource(chosen) }
            }
        } primaryAction: { keys in
            if keys.count == 1, let entry = lines.first(where: { keys.contains($0.id) })?.entry, !entry.synthetic { edit(entry) }
        }
        .onDeleteCommand { deleting = picked }
    }

    private func rebuild() {
        let query = TxQuery(text)
        let span: (String, String)? = day.map { ($0, $0) } ?? period?.span
        var built: [JournalLine] = []
        for entry in ledger.txns.reversed() {
            if let scope, !scope.matches(entry) { continue }
            if let span, entry.date < span.0 || entry.date > span.1 { continue }
            guard query.matches(entry, ledger) else { continue }
            let line = JournalLine(entry, ledger)
            if kind.matches(line.kind) { built.append(line) }
        }
        lines = built.sorted(using: sortOrder)
        balances = heldAccount.map { runningBalances(ledger, account: $0) } ?? [:]
        let shown = Set(lines.map(\.id))
        if !selected.isSubset(of: shown) { selected.formIntersection(shown) }
    }

    /// the account in view when what it holds adds up over time; a category only has totals for a period
    private var heldAccount: String? {
        scope?.account.flatMap { $0.hasPrefix("Assets") || $0.hasPrefix("Liabilities") ? $0 : nil }
    }

    /// "11/08", with the year when it isn't this one
    private func shortDate(_ date: String) -> String {
        let short = date.dropFirst(5).replacingOccurrences(of: "-", with: "/")
        return date.prefix(4) == Day.today().prefix(4) ? short : date.replacingOccurrences(of: "-", with: "/")
    }

    /// " · 五姨、王五": who the personal receivable lines are with
    private func withWhom(_ entry: Entry) -> String {
        var names: [String] = []
        for posting in entry.postings where isPersonal(posting.account) {
            if let name = postingPerson(posting), !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "" : " · " + names.joined(separator: "、")
    }

    private func present<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func edit(_ entry: Entry) {
        if let draft = folderEditDraft(entry, ledger, folderDerived(ledger, config: config)) {
            editing = EditedEntry(draft: draft)
        } else {
            notice = "这笔交易在 Mac 上还不能编辑，请在手机上修改"
        }
    }

    private func copySource(_ entries: [Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries.map { $0.src.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n"), forType: .string)
    }

    /// shown in the Finder when nothing is set to open a `.bean` file
    private func openFile(_ entry: Entry) {
        let url = folder.appendingPathComponent(entry.file)
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func deleteMessage(_ entry: Entry) -> String {
        let summary = [entry.date, entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " ")
        let linked = ledger.txns.filter { !$0.synthetic && $0.src != entry.src && !Set($0.links).isDisjoint(with: entry.links) }.count
        return linked == 0 ? summary : summary + "\n它和另外 \(linked) 笔交易有关联"
    }

    private func delete(_ entry: Entry) {
        let folder = folder
        Task { @MainActor in
            switch await Task.detached(operation: { prepareFolderDelete(entry, folder: folder) }).value {
            case .failure(let error): notice = error.message
            case .success(let save):
                if save.issues.isEmpty { write(save) } else { review = save }
            }
        }
    }

    private func write(_ save: FolderSave) {
        do {
            try commitFolderSave(save, folder: folder)
        } catch {
            notice = error.localizedDescription
        }
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

/// the picked entry beside the list, as the phone's page for it: who, how much, the accounts and category; what can be done with it stays at the bottom
private struct EntryDetail: View {
    let entry: Entry
    let ledger: Ledger
    let edit: () -> Void
    let copy: () -> Void
    let open: () -> Void
    let delete: () -> Void
    @State private var showsSource = false

    var body: some View {
        let shown = classify(entry, ledger)
        let tags = entry.tags
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        CategoryBadge(entry: entry, ledger: ledger)
                        Text(entry.payee.isEmpty ? (entry.narration.isEmpty ? "交易" : entry.narration) : entry.payee)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    ForEach(entry.shownAmounts(ledger), id: \.0) { amount in
                        Text(amount.0)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(amount.1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    ForEach(entry.charged(ledger), id: \.0) { paid in
                        Text("实付 " + money(paid.1, paid.0)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(Day.dayLabel(entry.date) + (entry.date.prefix(4) != Day.today().prefix(4) ? " " + entry.date.prefix(4) : ""))
                            .foregroundStyle(.secondary)
                        if entry.flag == "!" { RowTag(text: "待确认", color: .orange) }
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 4) { ForEach(tags, id: \.self) { RowTag(text: "#" + $0, color: .secondary) } }
                    }
                }
                Divider()
                ForEach(Array(accounts(shown.kind).enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.0) { Text(row.1).lineLimit(1) }
                }
                ForEach(Array(Set(entry.postings.compactMap { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") ? $0.account : advanceCategory($0) })).sorted(), id: \.self) { account in
                    LabeledContent("分类") { Text(acctDisplay(account)).lineLimit(1) }
                }
                if !entry.payee.isEmpty && !entry.narration.isEmpty {
                    LabeledContent("摘要") { Text(entry.narration).lineLimit(3) }
                }
                // the source has every amount in it
                if !KitPrivacy.masked {
                    DisclosureGroup("Beancount 原文", isExpanded: $showsSource) {
                        Text(entry.src.trimmingCharacters(in: .newlines))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("编辑…", action: edit).disabled(entry.synthetic)
                Spacer()
                Menu("更多") {
                    Button("复制原文", action: copy)
                    Button("打开所在文件", action: open)
                    Divider()
                    Button("删除…", role: .destructive, action: delete).disabled(entry.synthetic)
                }
                .fixedSize()
            }
            .padding(12)
            .background(.bar)
        }
    }

    /// an advance reads as what paid for it: the line waiting to be paid back isn't an account it moved to
    private func accounts(_ kind: TxKind) -> [(String, String)] {
        let advances = entry.postings.filter { advanceCategory($0) != nil }.map(\.account)
        let held = moneyRoute(entry).filter { !$0.hasPrefix("Expenses:") && !$0.hasPrefix("Income:") && !$0.hasPrefix("Equity:") && !advances.contains($0) }
        return held.enumerated().map { index, account in
            let label = !advances.isEmpty || kind == .expense ? "付款账户" : kind == .transfer ? (index == 0 ? "转出账户" : "转入账户") : "收款账户"
            return (label, accountTitle(ledger, account))
        }
    }
}

/// who, on its category's colour, and the note under it
private struct PayeeCell: View {
    let entry: Entry
    let ledger: Ledger
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            CategoryBadge(entry: entry, ledger: ledger, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if !entry.payee.isEmpty && !entry.narration.isEmpty {
                    Text(entry.narration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 待确认, pad, and the first tag with how many more
private struct StatusCell: View {
    let entry: Entry

    var body: some View {
        let tags = entry.tags.filter { $0 != "transfer" && $0 != "fx" }
        HStack(spacing: 4) {
            if entry.flag == "!" { RowTag(text: "待确认", color: .orange) }
            if entry.synthetic { RowTag(text: "pad", color: .secondary) }
            // a narrow column cuts the tag short: a count alone reads as a tag of its own
            if let first = tags.first { RowTag(text: "#" + first, color: .secondary, shortens: true) }
            if tags.count > 1 { RowTag(text: "+\(tags.count - 1)", color: .secondary) }
        }
    }
}

/// the amount, and what the account holds after it underneath
private struct AmountCell: View {
    let entry: Entry
    let ledger: Ledger
    /// the account being looked through: what moved in it, to read against the balance underneath
    let account: String?
    let balance: Inventory?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            ForEach(entry.shownAmounts(ledger, account: account), id: \.0) { amount in
                // red or green doesn't read on the selection's colour
                Text(amount.0).monospacedDigit().foregroundStyle(prominence == .increased ? .white : amount.1)
            }
            if account == nil {
                ForEach(entry.charged(ledger), id: \.0) { paid in
                    Text(money(paid.1, paid.0)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let balance {
                ForEach(balance.order, id: \.self) { currency in
                    Text(money(balance.amounts[currency] ?? 0, currency))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("余额")
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct RowTag: View {
    let text: String
    let color: Color
    /// cut short where the column is narrow, rather than spill out of it
    var shortens = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: !shortens, vertical: true)
    }
}
