import SwiftUI
import LedgerKit

struct JournalPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let scope: JournalScope?
    @Binding var searching: Bool
    @State private var text = ""
    @State private var selected: String?
    @FocusState private var listFocused: Bool
    @State private var editing: EditedEntry?
    @State private var deleting: Entry?
    @State private var review: FolderSave?
    @State private var notice: String?

    private struct EditedEntry: Identifiable {
        let id = UUID()
        let draft: Draft
    }

    var body: some View {
        let query = TxQuery(text)
        let rows = ledger.txns.reversed().filter { (scope?.matches($0) ?? true) && query.matches($0, ledger) }
        let balances = heldAccount.map { runningBalances(ledger, account: $0) }
        Group {
            if rows.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                List(selection: $selected) {
                    ForEach(days(of: rows), id: \.first?.date) { day in
                        Section {
                            ForEach(day, id: \.key) { JournalRow(entry: $0, ledger: ledger, account: heldAccount, balance: balances?[ObjectIdentifier($0)]) }
                        } header: {
                            DayHeader(entries: day, ledger: ledger)
                        }
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .onAppear { if !searching { listFocused = true } }
                // the system's own: double-click or Return for the primary action
                .contextMenu(forSelectionType: String.self) { keys in
                    if let entry = rows.first(where: { keys.contains($0.key) }) {
                        Button("编辑…") { edit(entry) }
                        Button("复制原文") { copySource(entry) }
                        Button("打开所在文件") { openFile(entry) }
                        Divider()
                        Button("删除…", role: .destructive) { deleting = entry }
                    }
                } primaryAction: { keys in
                    if let entry = rows.first(where: { keys.contains($0.key) }) { edit(entry) }
                }
                .onDeleteCommand { deleting = rows.first { $0.key == selected } }
            }
        }
        .searchable(text: $text, isPresented: $searching, placement: .toolbar)
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

    /// the account in view when what it holds adds up over time; a category only has totals for a period
    private var heldAccount: String? {
        scope?.account.flatMap { $0.hasPrefix("Assets") || $0.hasPrefix("Liabilities") ? $0 : nil }
    }

    /// entries come newest first, so each day's are together
    private func days(of rows: [Entry]) -> [[Entry]] {
        var days: [[Entry]] = []
        for entry in rows {
            if days.last?.first?.date == entry.date { days[days.count - 1].append(entry) } else { days.append([entry]) }
        }
        return days
    }

    private func present<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func edit(_ entry: Entry) {
        if let draft = folderEditDraft(entry, ledger, Derived(ledger)) {
            editing = EditedEntry(draft: draft)
        } else {
            notice = "这笔交易在 Mac 上还不能编辑，请在手机上修改"
        }
    }

    private func copySource(_ entry: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.src.trimmingCharacters(in: .newlines), forType: .string)
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

private extension Entry {
    var key: String { "\(file):\(line)" }
}

/// as the phone's: the day, the year when it isn't this one, and what came in and went out that day
private struct DayHeader: View {
    let entries: [Entry]
    let ledger: Ledger

    var body: some View {
        let day = entries[0].date
        let year = day.prefix(4) != Day.today().prefix(4) ? " " + day.prefix(4) : ""
        HStack(spacing: 16) {
            Text(Day.dayLabel(day) + year)
            Spacer()
            Text(totals).monospacedDigit().lineLimit(1)
        }
    }

    private var totals: String {
        var out = 0.0, inn = 0.0
        for entry in entries {
            let shown = classify(entry, ledger)
            switch shown.kind {
            case .expense, .refund: out -= shown.amount
            case .income: inn += shown.amount
            default: break
            }
        }
        return [inn != 0 ? "收入 " + money(inn, ledger.base) : nil, out != 0 ? "支出 " + money(out, ledger.base) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// as the phone's: who and the note, where it went underneath; the amount, and what the account holds after it underneath
private struct JournalRow: View {
    let entry: Entry
    let ledger: Ledger
    /// the account being looked through: what moved in it, to read against the balance underneath
    let account: String?
    let balance: Inventory?

    var body: some View {
        let tags = entry.tags.filter { $0 != "transfer" && $0 != "fx" }
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.payee.isEmpty ? (entry.narration.isEmpty ? "（无收付款方）" : entry.narration) : entry.payee)
                        .lineLimit(1)
                        .layoutPriority(3)
                    if !entry.payee.isEmpty && !entry.narration.isEmpty {
                        Text(entry.narration)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    if entry.flag == "!" { RowTag(text: "待确认", color: .orange).layoutPriority(2) }
                    if entry.synthetic { RowTag(text: "pad", color: .secondary).layoutPriority(2) }
                    if !tags.isEmpty {
                        // only where they fit whole, so a long tag doesn't cut the payee down
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                RowTag(text: "#" + tags[0], color: .secondary)
                                if tags.count > 1 { RowTag(text: "+\(tags.count - 1)", color: .secondary) }
                            }
                            RowTag(text: "#\(tags.count)", color: .secondary)
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .layoutPriority(2)
                    }
                }
                Text(route + withWhom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(amounts, id: \.0) { amount in
                    Text(amount.0).monospacedDigit().foregroundStyle(amount.1)
                }
                ForEach(charged, id: \.0) { paid in
                    Text(money(paid.1, paid.0))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
        }
        .padding(.vertical, 3)
    }

    private var route: String {
        let categories = entry.postings.filter { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }
        if transferWithFee(entry) == nil, let category = categories.first { return acctDisplay(category.account) }
        return moneyRoute(entry).filter { account in !categories.contains { $0.account == account } }.map(acctDisplay).joined(separator: " → ")
    }

    /// " · 五姨、王五": who the personal receivable lines are with
    private var withWhom: String {
        var names: [String] = []
        for posting in entry.postings where isPersonal(posting.account) {
            if let name = postingPerson(posting), !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "" : " · " + names.joined(separator: "、")
    }

    /// as in the phone's journal: what moved in the account being looked through, else a transfer's amount, else what was
    /// spent or earned in each currency as booked. A transfer that paid a fee shows both what it moved and the fee
    private var amounts: [(String, Color)] {
        if let account {
            return sums(entry.postings.filter { $0.account == account || $0.account.hasPrefix(account + ":") }, negate: false).map(signed)
        }
        let shown = classify(entry, ledger)
        if shown.kind == .transfer { return [(money(shown.amount, shown.currency ?? "CNY"), .secondary)] }
        let spent = sums(entry.postings.filter(isCategory), negate: true).map(signed)
        if let moved = transferWithFee(entry) { return [(money(moved.amount, moved.currency), .secondary)] + spent }
        return spent
    }

    /// what the account was charged in another currency, for checking against the bank
    private var charged: [(String, Double)] {
        guard account == nil, classify(entry, ledger).kind != .transfer else { return [] }
        let own = sums(entry.postings.filter(isCategory), negate: true)
        return sums(entry.postings.filter { !isCategory($0) && !$0.account.hasPrefix("Equity:") }, negate: false)
            .filter { paid in !own.contains { $0.0 == paid.0 } }
    }

    private func isCategory(_ posting: Posting) -> Bool {
        posting.account.hasPrefix("Expenses:") || posting.account.hasPrefix("Income:")
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

private struct RowTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}
