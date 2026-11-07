import SwiftUI
import LedgerKit

struct JournalPage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @Binding var scope: JournalScope?
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
        Group {
            if rows.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                List(selection: $selected) {
                    ForEach(days(of: rows), id: \.first?.date) { day in
                        Section(day[0].date) {
                            ForEach(day, id: \.key) { JournalRow(entry: $0, ledger: ledger) }
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
        .safeAreaInset(edge: .top) {
            if let scope {
                HStack {
                    Text(scope.title).lineLimit(1)
                    Spacer(minLength: 16)
                    Button { self.scope = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("显示全部")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
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

private struct JournalRow: View {
    let entry: Entry
    let ledger: Ledger

    var body: some View {
        HStack(spacing: 16) {
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
