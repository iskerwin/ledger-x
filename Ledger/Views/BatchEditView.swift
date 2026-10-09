import SwiftUI
import LedgerKit

enum BatchMode: String, CaseIterable, Identifiable {
    case account, tag, link
    var id: String { rawValue }
    var name: String {
        switch self {
        case .account: return LS("改科目")
        case .tag: return LS("加标签")
        case .link: return LS("加链接")
        }
    }
}

/// change an account, add a tag or a link on several transactions at once
struct BatchEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let entries: [Entry]
    @State var mode: BatchMode
    var done: () -> Void = {}
    @State private var from = ""
    @State private var to = ""
    @State private var word = ""
    @State private var picking = false
    @State private var working = false

    private var accounts: [String] {
        var c: [String: Int] = [:]
        for t in entries { for p in t.postings { c[p.account, default: 0] += 1 } }
        return c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
    }

    private var cleanWord: String {
        word.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#^")).replacingOccurrences(of: " ", with: "-")
    }

    private var affected: Int {
        switch mode {
        case .account: return entries.filter { t in t.postings.contains { $0.account == from } }.count
        case .tag: return entries.filter { !$0.tags.contains(cleanWord) }.count
        case .link: return entries.filter { !$0.links.contains(cleanWord) }.count
        }
    }

    private var ready: Bool {
        switch mode {
        case .account: return !from.isEmpty && isAccountName(to) && from != to
        case .tag, .link: return !cleanWord.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(LS("操作"), selection: $mode) {
                        ForEach(BatchMode.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(LS("已选 %@ 笔交易", entries.count))
                }
                switch mode {
                case .account:
                    Section {
                        Picker(LS("原科目"), selection: $from) {
                            Text(LS("选择")).tag("")
                            ForEach(accounts, id: \.self) { Text(acctLabel($0)).tag($0) }
                        }
                        Button { picking = true } label: {
                            LabeledContent(LS("新科目"), value: to.isEmpty ? LS("选择") : acctDisplay(to))
                        }
                        .foregroundStyle(.primary)
                    } footer: {
                        Text(LS("只替换完全相同的科目，不影响其子科目。"))
                    }
                case .tag, .link:
                    Section {
                        TextField(mode == .tag ? "trip-tokyo" : "invoice-2026-10", text: $word)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                        if let D = store.D, mode == .link, !D.allLinks.isEmpty {
                            ChipRow { ForEach(D.allLinks.suffix(12).reversed(), id: \.self) { l in Chip(label: "^" + l, selected: cleanWord == l) { word = l } } }
                        }
                    } footer: {
                        Text(mode == .tag ? LS("在交易标题行末尾添加 #标签。") : LS("在交易标题行末尾添加 ^链接，相关交易会在详情页互相显示。"))
                    }
                }
                Section {
                    Button {
                        Task { await apply() }
                    } label: {
                        HStack {
                            Text(LS("应用到 %@ 笔交易", affected)).fontWeight(.semibold)
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!ready || affected == 0 || working)
                }
            }
            .keyboardDone()
            .navigationTitle(LS("批量编辑"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
            .sheet(isPresented: $picking) {
                AccountPicker(title: LS("新科目"), prefixes: ["Expenses:", "Income:", "Assets:", "Liabilities:", "Equity:"], current: to, allowAny: true) { to = $0 }
            }
            .onAppear { if from.isEmpty { from = accounts.first { $0.hasPrefix("Expenses:") } ?? "" } }
        }
    }

    private func transform(_ block: String) -> String? {
        var lines = block.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        switch mode {
        case .account:
            var changed = false
            for i in lines.indices.dropFirst() {
                let l = lines[i]
                let body = l.trimmingCharacters(in: .whitespaces)
                let flagged = body.hasPrefix("! ") || body.hasPrefix("* ")
                let name = (flagged ? String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces) : body).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if name == from, let r = l.range(of: from) {
                    lines[i] = l.replacingCharacters(in: r, with: to)
                    changed = true
                }
            }
            return changed ? alignText(lines.joined(separator: "\n")) : nil
        case .tag, .link:
            let add = (mode == .tag ? " #" : " ^") + cleanWord
            if lines[0].components(separatedBy: " ").contains(add.trimmingCharacters(in: .whitespaces)) { return nil }
            var head = lines[0]
            while head.hasSuffix(" ") { head.removeLast() }
            lines[0] = head + add
            return lines.joined(separator: "\n")
        }
    }

    private func apply() async {
        working = true
        defer { working = false }
        var ops: [Op] = []
        var cache: [String: [String]] = [:]
        let label = LS("批量编辑 %@ 笔：%@", affected, mode == .account ? acctLabel(from) + " → " + acctLabel(to) : (mode == .tag ? "#" : "^") + cleanWord)
        for t in entries.sorted(by: { $0.date < $1.date }) {
            if cache[t.file] == nil { cache[t.file] = (try? await store.fileText(t.file))?.components(separatedBy: "\n") }
            guard let lines = cache[t.file], t.endLine < lines.count else { continue }
            let old = lines[t.startLine...t.endLine].joined(separator: "\n")
            guard let new = transform(old) else { continue }
            var op = Op(kind: .replace, path: t.file)
            op.old = old
            op.text = new
            op.date = t.date
            op.label = ops.isEmpty ? label : nil
            op.summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
            op.silent = ops.isEmpty ? nil : true
            ops.append(op)
        }
        guard !ops.isEmpty else { store.show(LS("没有需要修改的交易")); return }
        dismiss()
        done()
        await store.commit(ops, word: LS("已修改 %@ 笔", ops.count))
    }
}
