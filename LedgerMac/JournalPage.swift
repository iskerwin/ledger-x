import SwiftUI
import LedgerKit

struct JournalPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @State private var text = ""
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
        let rows = ledger.txns.reversed().filter { query.matches($0, ledger) }
        Group {
            if rows.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                List(rows.indices, id: \.self) { index in
                    JournalRow(entry: rows[index], ledger: ledger)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { edit(rows[index]) }
                        .contextMenu {
                            Button(chinese ? "编辑…" : "Edit…") { edit(rows[index]) }
                            Button(chinese ? "删除…" : "Delete…", role: .destructive) { deleting = rows[index] }
                        }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $text, placement: .toolbar)
        .sheet(item: $editing) { NewEntrySheet(ledger: ledger, config: config, folder: folder, editing: $0.draft) }
        .alert(chinese ? "删除这笔交易？" : "Delete this entry?", isPresented: present($deleting), presenting: deleting) { entry in
            Button(chinese ? "删除" : "Delete", role: .destructive) { delete(entry) }
            Button(chinese ? "取消" : "Cancel", role: .cancel) {}
        } message: { entry in
            Text([entry.date, entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " "))
        }
        .alert(review?.issues.first?.title ?? "", isPresented: present($review), presenting: review) { save in
            if !save.issues.contains(where: \.blocking) {
                Button(chinese ? "仍然删除" : "Delete Anyway", role: .destructive) { write(save) }
            }
            Button(chinese ? "取消" : "Cancel", role: .cancel) {}
        } message: { save in
            Text(save.issues.map(\.detail).joined(separator: "\n"))
        }
        .alert(notice ?? "", isPresented: present($notice)) {}
    }

    private func present<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func edit(_ entry: Entry) {
        if let draft = folderEditDraft(entry, ledger, Derived(ledger)) {
            editing = EditedEntry(draft: draft)
        } else {
            notice = chinese ? "这笔交易在 Mac 上还不能编辑，请在手机上修改" : "This entry can't be edited on the Mac yet: change it on your phone"
        }
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

private struct JournalRow: View {
    let entry: Entry
    let ledger: Ledger

    var body: some View {
        HStack(spacing: 16) {
            Text(entry.date)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(entry.payee.isEmpty ? entry.narration : entry.payee)
                .lineLimit(1)
            if !entry.payee.isEmpty && !entry.narration.isEmpty {
                Text(entry.narration)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing) {
                ForEach(amounts, id: \.self) { Text($0).monospacedDigit() }
            }
            .foregroundStyle(isTransfer ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private var isTransfer: Bool { classify(entry, ledger).kind == .transfer }

    /// as in the phone's journal: a transfer's amount, else what was spent or earned in each currency as booked
    private var amounts: [String] {
        let shown = classify(entry, ledger)
        if shown.kind == .transfer { return [money(shown.amount, shown.currency ?? "CNY")] }
        var order: [String] = [], sums: [String: Double] = [:]
        for posting in entry.postings where posting.account.hasPrefix("Expenses:") || posting.account.hasPrefix("Income:") {
            guard let units = posting.units, let currency = posting.currency else { continue }
            if sums[currency] == nil { order.append(currency) }
            sums[currency, default: 0] -= units
        }
        return order.map { signedMoney(sums[$0]!, $0) }
    }
}
