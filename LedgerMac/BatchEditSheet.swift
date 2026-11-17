import SwiftUI
import LedgerKit

/// several entries picked in a table, changed at once as on the phone: an account replaced, a tag or a link added
struct BatchRequest: Identifiable {
    let id = UUID()
    let entries: [Entry]
}

private enum BatchMode: CaseIterable {
    case account, tag, link

    var title: String {
        switch self {
        case .account: return LS("改科目")
        case .tag: return LS("加标签")
        case .link: return LS("加链接")
        }
    }
}

struct BatchEditSheet: View {
    let request: BatchRequest
    let ledger: Ledger
    let folder: URL
    @State private var mode = BatchMode.account
    @State private var from = ""
    @State private var to = ""
    @State private var word = ""
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    private var entries: [Entry] { request.entries }

    /// the accounts the picked entries use, the most used first
    private var used: [String] {
        var count: [String: Int] = [:]
        for entry in entries { for posting in entry.postings { count[posting.account, default: 0] += 1 } }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    private var edit: BatchEdit {
        switch mode {
        case .account: return .account(from: from, to: to)
        case .tag: return .tag(BatchEdit.word(word))
        case .link: return .link(BatchEdit.word(word))
        }
    }

    var body: some View {
        let affected = edit.affected(entries)
        VStack(alignment: .leading, spacing: 16) {
            Text(LS("批量编辑")).font(.headline)
            Form {
                Picker(LS("操作"), selection: $mode) {
                    ForEach(BatchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(LS("已选 %@ 笔交易", entries.count)).foregroundStyle(.secondary)
                switch mode {
                case .account:
                    Picker(LS("原科目"), selection: $from) {
                        Text(LS("选择")).tag("")
                        ForEach(used, id: \.self) { Text(acctDisplay($0)).tag($0) }
                    }
                    Picker(LS("新科目"), selection: $to) {
                        Text(LS("选择")).tag("")
                        ForEach(ledger.accounts.keys.filter { ledger.accounts[$0]?.close == nil }.sorted(), id: \.self) { Text(acctDisplay($0)).tag($0) }
                    }
                case .tag:
                    TextField(LS("标签"), text: $word, prompt: Text("#"))
                case .link:
                    TextField(LS("链接"), text: $word, prompt: Text("^"))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(LS("应用到 %@ 笔交易", affected)) { apply(affected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !edit.ready || affected == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { from = used.first { !$0.hasPrefix("Assets:") && !$0.hasPrefix("Liabilities:") } ?? "" }
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
        .folderReview(writer, $review, step: LS("批量编辑")) { dismiss() }
    }

    private var writer: FolderWriter {
        FolderWriter(folder: folder, busy: $busy, message: $message, review: $review)
    }

    private func apply(_ affected: Int) {
        let what: String
        switch edit {
        case .account(let from, let to): what = acctLabel(from) + " → " + acctLabel(to)
        case .tag(let word): what = "#" + word
        case .link(let word): what = "^" + word
        }
        let label = LS("批量编辑 %@ 笔：%@", affected, what)
        writer.prepare(entries, edit, label: label, step: LS("批量编辑")) { dismiss() }
    }
}
