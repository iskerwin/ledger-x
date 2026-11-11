import SwiftUI
import LedgerKit

/// the columns an entry's row can have, in their order; the amount is always there, last, in a width of its own
enum EntryColumn: CaseIterable {
    case date, payee, category, accounts, status, amount

    var title: String {
        switch self {
        case .date: return "日期"
        case .payee: return "收付款方"
        case .category: return "分类"
        case .accounts: return "账户"
        case .status: return "状态"
        case .amount: return "金额"
        }
    }

    /// what the payee column keeps, with its badge, before others give way
    static let payeeLeast: CGFloat = 160
}

/// how wide each column's content is, measured once for a list: the amount takes the width of its widest, never less;
/// the date too; the category and accounts up to a limit; the payee what's left
struct EntryWidths: Equatable {
    private var natural: [EntryColumn: CGFloat] = [:]

    /// thread-safe, so a long list is measured away from the main thread
    static func measure(_ rows: [JournalRow], balances: [ObjectIdentifier: Inventory] = [:]) -> EntryWidths {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let small = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        /// each text once; figures, set in even digits, only among the longest, as one with fewer characters can't be wider
        func widest(_ texts: [String], _ font: NSFont, figures: Bool = false) -> CGFloat {
            var seen = Set<String>()
            let longest = figures ? (texts.map(\.count).max() ?? 0) - 1 : 0
            return texts.reduce(0) { most, text in
                guard text.count >= longest, seen.insert(text).inserted else { return most }
                return max(most, width(text, font))
            }
        }
        let amounts = rows.flatMap { $0.amounts.map(\.text) }
        let captions = rows.flatMap { row in
            row.charged.map(\.text) + (balances[ObjectIdentifier(row.entry)].map { balance in balance.order.map { money(balance.amounts[$0] ?? 0, $0) } } ?? [])
        }
        let gap: CGFloat = 16
        var widths = EntryWidths()
        widths.natural[.date] = max(widest(rows.map { shortDay($0.date) }, digits, figures: true), width("日期", body)) + gap
        widths.natural[.category] = min(max(widest(rows.map(\.category), body), width("分类", body)) + gap, 160)
        widths.natural[.accounts] = min(max(widest(rows.map(\.accounts), body), width("账户", body)) + gap, 220)
        // nothing to show in it, no column
        widths.natural[.status] = rows.contains(where: \.marked) ? 90 : 0
        widths.natural[.amount] = max(widest(amounts, digits, figures: true), widest(captions, small, figures: true), width("金额", body)) + gap + 4
        return widths
    }

    /// the columns of `wanted` that fit `width`, and how wide each is: the accounts narrow first, then go, then the category, then the status
    func fit(_ wanted: [EntryColumn], in width: CGFloat) -> (columns: [EntryColumn], widths: [EntryColumn: CGFloat]) {
        var shown = wanted.filter { $0 != .status || (natural[.status] ?? 0) > 0 }
        var widths = natural
        func need() -> CGFloat { shown.filter { $0 != .payee }.reduce(EntryColumn.payeeLeast) { $0 + (widths[$1] ?? 0) } }
        if need() > width, shown.contains(.accounts) { widths[.accounts] = max(100, (widths[.accounts] ?? 0) - (need() - width)) }
        for column in [EntryColumn.accounts, .category, .status] where need() > width { shown.removeAll { $0 == column } }
        return (shown, widths)
    }
}

extension AmountTone {
    var color: Color {
        switch self {
        case .loss: return .loss
        case .gain: return .gain
        case .neutral: return .secondary
        }
    }
}

/// the names over the columns; a click on one sorts by it, again the other way
struct EntryHeader: View {
    let columns: [EntryColumn]
    let widths: [EntryColumn: CGFloat]
    @Binding var sortOrder: [KeyPathComparator<JournalRow>]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                EntryCell(column: column, width: widths[column]) {
                    if column.comparator(.forward) != nil {
                        Button { sort(column) } label: {
                            HStack(spacing: 3) {
                                Text(column.title)
                                if let order = order(column) {
                                    Image(systemName: order == .forward ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(column.title)
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 26)
    }

    /// the way the rows run by this column, when they do
    private func order(_ column: EntryColumn) -> SortOrder? {
        guard let first = sortOrder.first else { return nil }
        return first == column.comparator(.forward) ? .forward : first == column.comparator(.reverse) ? .reverse : nil
    }

    /// newest or largest first; again, the other way
    private func sort(_ column: EntryColumn) {
        if let comparator = column.comparator(order(column) == .reverse ? .forward : .reverse) { sortOrder = [comparator] }
    }
}

extension EntryColumn {
    func comparator(_ order: SortOrder) -> KeyPathComparator<JournalRow>? {
        switch self {
        case .date: return KeyPathComparator(\JournalRow.date, order: order)
        case .payee: return KeyPathComparator(\JournalRow.payee, order: order)
        case .category: return KeyPathComparator(\JournalRow.category, order: order)
        case .accounts: return KeyPathComparator(\JournalRow.accounts, order: order)
        case .status: return nil
        case .amount: return KeyPathComparator(\JournalRow.amount, order: order)
        }
    }
}

/// a column's place in a row: its width, or what's left for who
private struct EntryCell<Content: View>: View {
    let column: EntryColumn
    /// nil for the payee, which takes what's left
    let width: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        let width = column == .payee ? nil : self.width
        content
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: width == nil ? EntryColumn.payeeLeast : nil, maxWidth: width ?? .infinity,
                   alignment: column == .amount ? .trailing : .leading)
            .frame(width: width)
    }
}

/// an entry on one line; picked, it opens under itself with its source
struct EntryRow: View {
    let line: JournalRow
    let ledger: Ledger
    let columns: [EntryColumn]
    let widths: [EntryColumn: CGFloat]
    let picked: Bool
    /// what the account being looked through holds after it
    var balance: Inventory?
    /// each account line under it, as Fava's postings
    var postings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns, id: \.self) { column in
                    EntryCell(column: column, width: widths[column]) { cell(column) }
                }
            }
            .frame(minHeight: 38)
            if postings && !line.entry.postings.isEmpty {
                PostingLines(entry: line.entry, amountWidth: widths[.amount] ?? 80, picked: picked)
                    // under the payee, past its badge
                    .padding(.leading, (widths[.date] ?? 60) + 40)
            }
        }
        .foregroundStyle(picked ? Color.white : Color.primary)
        .background(picked ? Color.jade : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func cell(_ column: EntryColumn) -> some View {
        let quiet = picked ? Color.white.opacity(0.8) : Color.secondary
        switch column {
        case .date: Text(shortDay(line.date)).monospacedDigit().foregroundStyle(quiet)
        case .payee: PayeeCell(line: line, ledger: ledger, picked: picked)
        case .category: Text(line.category).foregroundStyle(quiet)
        case .accounts: Text(line.accounts).foregroundStyle(quiet)
        case .status: StatusCell(entry: line.entry)
        case .amount: AmountCell(line: line, balance: balance, picked: picked)
        }
    }
}

/// entries on a card in the journal's rows, each opening in place with its source; narrow, all but who and how much go
struct EntryListCard<Header: View>: View {
    let entries: [Entry]
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    var columns: [EntryColumn] = [.date, .payee, .category, .amount]
    /// the account being looked through: what moved in it
    var account: String?
    @ViewBuilder var header: Header
    @State private var open: String?
    @State private var tasks = EntryTasks()

    var body: some View {
        let lines = entries.map { JournalRow($0, ledger, account: account) }
        let widths = EntryWidths.measure(lines)
        // the card's width isn't known here: as many columns as fit
        let full = widths.fit(columns, in: .infinity), least = widths.fit(columns, in: 0)
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 8)
                ForEach(lines) { line in
                    let entry = line.entry
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        EntryRow(line: line, ledger: ledger, columns: full.columns, widths: full.widths, picked: open == entry.key)
                        EntryRow(line: line, ledger: ledger, columns: least.columns, widths: least.widths, picked: open == entry.key)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { open = open == entry.key ? nil : entry.key }
                    if open == entry.key {
                        SourcePanel(entry: entry, ledger: ledger, config: config, folder: folder, tasks: $tasks)
                    }
                }
            }
        }
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
    }
}

/// what's being done to an entry from a list of them: the form, deleting it, and what a save would break
struct EntryTasks {
    struct Edited: Identifiable {
        let id = UUID()
        let draft: Draft
    }

    struct Review: Identifiable {
        let id = UUID()
        let save: FolderSave
        /// what goes ahead anyway, as the button says it
        let verb: String
        let done: () -> Void
    }

    var editing: Edited?
    var deleting: Entry?
    var review: Review?
    var notice: String?

    mutating func edit(_ entry: Entry, _ ledger: Ledger, _ config: LedgerXConfig?) {
        if let draft = folderEditDraft(entry, ledger, folderDerived(ledger, config: config)) {
            editing = Edited(draft: draft)
        } else {
            notice = "表单装不下这笔交易，请用「修改原文」修改"
        }
    }

    static func copy(_ entries: [Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries.map { $0.src.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n"), forType: .string)
    }

    /// shown in the Finder when nothing is set to open a `.bean` file
    static func open(_ entry: Entry, in folder: URL) {
        let url = folder.appendingPathComponent(entry.file)
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

extension View {
    /// the form, the question before deleting, and what a save would break, for a page that lists entries
    func entryTasks(_ tasks: Binding<EntryTasks>, ledger: Ledger, config: LedgerXConfig?, folder: URL) -> some View {
        sheet(item: tasks.editing) { NewEntrySheet(ledger: ledger, config: config, folder: folder, editing: $0.draft) }
            .alert("删除这笔交易？", isPresented: tasks.deleting.present(), presenting: tasks.wrappedValue.deleting) { entry in
                Button("删除", role: .destructive) { deleteEntry(entry, tasks, folder: folder) }
                Button("取消", role: .cancel) {}
            } message: { entry in
                Text(deleteMessage(entry, ledger))
            }
            .alert(tasks.wrappedValue.review?.save.issues.first?.title ?? "", isPresented: tasks.review.present(), presenting: tasks.wrappedValue.review) { review in
                if !review.save.issues.contains(where: \.blocking) {
                    Button(review.verb, role: .destructive) { commitEntrySave(review.save, tasks, folder: folder, done: review.done) }
                }
                Button("取消", role: .cancel) {}
            } message: { review in
                Text(review.save.issues.map(\.detail).joined(separator: "\n"))
            }
            .alert(tasks.wrappedValue.notice ?? "", isPresented: tasks.notice.present()) {}
    }
}

extension Binding {
    /// shown while there is something in it; put away, nothing
    func present<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

private func deleteMessage(_ entry: Entry, _ ledger: Ledger) -> String {
    let summary = [entry.date, entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " ")
    let linked = ledger.txns.filter { !$0.synthetic && $0.src != entry.src && !Set($0.links).isDisjoint(with: entry.links) }.count
    return linked == 0 ? summary : summary + "\n它和另外 \(linked) 笔交易有关联"
}

private func deleteEntry(_ entry: Entry, _ tasks: Binding<EntryTasks>, folder: URL) {
    Task { @MainActor in
        switch await Task.detached(operation: { prepareFolderDelete(entry, folder: folder) }).value {
        case .failure(let error): tasks.wrappedValue.notice = error.message
        case .success(let save):
            if save.issues.isEmpty {
                commitEntrySave(save, tasks, folder: folder) {}
            } else {
                tasks.wrappedValue.review = EntryTasks.Review(save: save, verb: "仍然删除", done: {})
            }
        }
    }
}

private func commitEntrySave(_ save: FolderSave, _ tasks: Binding<EntryTasks>, folder: URL, done: () -> Void) {
    do {
        try commitFolderSave(save, folder: folder)
        done()
    } catch {
        tasks.wrappedValue.notice = error.localizedDescription
    }
}

/// under a picked row: its source, read only until 修改原文, so a stray key doesn't change the ledger. Saved on the same path
/// as the form (the text checked, aligned and put in that entry's place); refused, the text stays as typed with the reason
struct SourcePanel: View {
    let entry: Entry
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @Binding var tasks: EntryTasks
    /// what's typed, while changing it
    @State private var text: String?
    @State private var message = ""
    @State private var saving = false
    @FocusState private var typing: Bool

    private let mono = Font.system(size: 12, design: .monospaced)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if text != nil {
                    TextEditor(text: Binding(get: { text ?? "" }, set: { text = $0 }))
                        .font(mono)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: lines * 17 + 16)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.jade))
                        .focused($typing)
                        .onAppear { typing = true }
                } else if !KitPrivacy.masked {
                    // the source has every amount in it
                    Text(source)
                        .font(mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(Color.loss)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if text != nil {
                    Button("保存", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(saving)
                    Button("取消") {
                        text = nil
                        message = ""
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("修改原文") { text = source }
                        .disabled(!entry.editable || KitPrivacy.masked)
                    Menu("更多") {
                        Button("编辑…") { tasks.edit(entry, ledger, config) }.disabled(!entry.editable)
                        Button("复制原文") { EntryTasks.copy([entry]) }
                        Button("打开所在文件") { EntryTasks.open(entry, in: folder) }
                        Divider()
                        Button("删除…", role: .destructive) { tasks.deleting = entry }.disabled(!entry.editable)
                    }
                    .fixedSize()
                }
            }
            .controlSize(.small)
            .frame(width: 84, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .background(Color.jade.opacity(0.08))
        .onChange(of: entry.src) {
            // saved, or changed elsewhere: what's shown is the file's again
            if text == nil { message = "" }
        }
    }

    private var source: String { entry.src.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var lines: CGFloat { CGFloat(max((text ?? source).components(separatedBy: "\n").count, 3)) }

    private func save() {
        guard let typed = text else { return }
        var draft = folderSourceDraft(entry)
        draft.raw = typed
        saving = true
        message = ""
        let folder = folder
        Task { @MainActor in
            let result = await Task.detached { prepareFolderSave(draft, folder: folder) }.value
            saving = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let save):
                if save.issues.isEmpty {
                    write(save)
                } else {
                    tasks.review = EntryTasks.Review(save: save, verb: "仍然保存") { text = nil }
                }
            }
        }
    }

    private func write(_ save: FolderSave) {
        do {
            try commitFolderSave(save, folder: folder)
            text = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

/// an entry's account lines, each account with what moved in it, the amounts in the amount column
private struct PostingLines: View {
    let entry: Entry
    let amountWidth: CGFloat
    let picked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entry.postings.indices, id: \.self) { index in
                let posting = entry.postings[index]
                HStack(spacing: 8) {
                    Text(acctDisplay(posting.account)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(posting.units.map { money($0, posting.currency ?? "") } ?? "")
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: amountWidth - 16, alignment: .trailing)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(picked ? Color.white.opacity(0.8) : Color.secondary)
        .padding(.trailing, 8)
        .padding(.bottom, 6)
    }
}

/// a balance assertion, a note or a document, on a badge like a category's
private struct DirectiveBadge: View {
    let type: EntryType
    let failed: Bool

    var body: some View {
        let symbol = type == .balance ? (failed ? "exclamationmark.triangle" : "checkmark.seal") : type == .document ? "doc" : "note.text"
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(failed ? Color.loss : Color.gray, in: RoundedRectangle(cornerRadius: 24 * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// who, on its category's colour, and the note under it
private struct PayeeCell: View {
    let line: JournalRow
    let ledger: Ledger
    let picked: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let directive = line.directive {
                DirectiveBadge(type: directive, failed: line.failed)
            } else {
                CategoryBadge(entry: line.entry, ledger: ledger, size: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(line.payee).lineLimit(1)
                if !line.note.isEmpty {
                    Text(line.note)
                        .font(.caption)
                        .foregroundStyle(picked ? Color.white.opacity(0.8) : Color.secondary)
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
    let line: JournalRow
    let balance: Inventory?
    let picked: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            // a transfer that paid a fee can show the same currency twice
            ForEach(line.amounts.indices, id: \.self) { index in
                let amount = line.amounts[index]
                // red or green doesn't read on the selection's colour
                Text(amount.text).monospacedDigit().foregroundStyle(picked ? .white : amount.tone.color)
            }
            ForEach(line.charged.indices, id: \.self) { index in
                let paid = line.charged[index]
                Text(paid.text).font(.caption).monospacedDigit().foregroundStyle(picked ? Color.white.opacity(0.8) : .secondary)
            }
            if let balance {
                ForEach(balance.order, id: \.self) { currency in
                    Text(money(balance.amounts[currency] ?? 0, currency))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(picked ? Color.white.opacity(0.8) : .secondary)
                        .help("余额")
                }
            }
        }
        .lineLimit(1)
    }
}

struct RowTag: View {
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
