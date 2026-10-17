import SwiftUI
import UIKit
import LedgerKit

@MainActor
enum Haptics {
    static func selection() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// Capture the ledger and source when asking, not the row's position after a refresh.
@MainActor
struct EntryDeletion: Identifiable {
    let id = UUID()
    let locator: EntryLocator
    let ledgerID: String
    let title: String
    let message: String
    let onDeleted: () -> Void

    init(_ entry: Entry, ledgerID: String, onDeleted: @escaping () -> Void = {}) {
        locator = EntryLocator(entry)
        self.ledgerID = ledgerID
        self.onDeleted = onDeleted
        title = LS("删除 %@ %@？", entry.date, entryActionName(entry))
        switch entry.type {
        case .txn:
            message = LS("将删除整笔交易及其所有账户分录。删除后可在「最近改动」里撤回。")
        case .balance:
            message = LS("仅移除这一条余额断言，不删除交易。删除后可在「最近改动」里撤回。")
        case .document:
            message = LS("仅移除账本中的票据引用，保留实际附件文件。删除后可在「最近改动」里撤回。")
        case .custom where entry.name == "card-bill":
            message = LS("删除后恢复按账本估算账单；消费和还款记录保持不变。删除后可在「最近改动」里撤回。")
        default:
            message = LS("仅删除这一条记录。删除后可在「最近改动」里撤回。")
        }
        Haptics.warning()
    }
}

func entryActionName(_ entry: Entry) -> String {
    switch entry.type {
    case .txn:
        let summary = [entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " ")
        return summary.isEmpty ? LS("交易") : summary
    case .balance: return LS("余额断言") + " · " + (entry.account ?? "") + " · " + (entry.currency ?? "")
    case .note: return LS("备注") + " · " + (entry.account ?? "")
    case .document: return LS("票据") + " · " + ((entry.path ?? "") as NSString).lastPathComponent
    case .custom where entry.name == "card-bill": return LS("账单")
    default: return LS("记录")
    }
}

private struct EntryDeletionModifier: ViewModifier {
    @EnvironmentObject private var store: Store
    @Binding var request: EntryDeletion?
    @State private var busy = false

    func body(content: Content) -> some View {
        content
            .disabled(busy)
            .confirmationDialog(request?.title ?? "", isPresented: Binding(
                get: { request != nil }, set: { if !$0 { request = nil } }
            ), titleVisibility: .visible, presenting: request) { target in
                Button(LS("删除"), role: .destructive) {
                    guard !busy else { return }
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        guard store.cfg.id == target.ledgerID,
                              let entry = target.locator.resolve(in: store.L?.entries ?? []) else {
                            Haptics.error()
                            store.show(LS("记录或账本已变化，请重新打开后再试"))
                            return
                        }
                        // The Store also reparses pending file text before making the operation.
                        if await store.deleteDirective(entry, summary: entryActionName(entry)) {
                            target.onDeleted()
                        }
                    }
                }
                Button(LS("取消"), role: .cancel) {}
            } message: { target in
                Text(target.message)
            }
            .onChange(of: store.cfg.id) { _, _ in request = nil }
    }
}

/// Use on the List row, rather than on TxRow's inner labels, so native List gestures work.
private struct EntryActions: ViewModifier {
    @EnvironmentObject private var store: Store
    @Environment(\.push) private var push
    let entry: Entry
    var edit: (() -> Void)?
    @State private var deletion: EntryDeletion?
    @State private var source: EntrySourceTarget?
    @State private var opening = false

    private var writable: Bool { !entry.synthetic && !entry.file.isEmpty && !entry.src.trimmed.isEmpty }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if writable {
                    // A regular red button avoids List's optimistic removal before confirmation.
                    Button { askDelete() } label: { Label(LS("删除"), systemImage: "trash") }.tint(.red)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if writable {
                    Button { openEdit() } label: { Label(LS("编辑"), systemImage: "pencil") }.tint(.orange)
                }
            }
            .contextMenu {
                if writable {
                    Button { openEdit() } label: { Label(LS("编辑"), systemImage: "pencil") }
                }
                Menu {
                    Button { copy(entry.src) } label: { Label(LS("复制源文本"), systemImage: "doc.on.clipboard") }
                    if entry.type == .txn, !entry.synthetic {
                        Button { duplicate() } label: { Label(LS("复制为新交易"), systemImage: "plus.square.on.square") }
                        if let L = store.L {
                            let amount = classify(entry, L)
                            Button { copy(money(amount.amount, amount.currency ?? "CNY")) } label: { Label(LS("复制金额"), systemImage: "number") }
                        }
                    } else if entry.type == .balance {
                        Button { copy(money(entry.number, entry.currency ?? "CNY")) } label: { Label(LS("复制金额"), systemImage: "number") }
                    }
                    if let account = entry.account {
                        Button { copy(account) } label: { Label(LS("复制账户名称"), systemImage: "building.columns") }
                    }
                } label: { Label(LS("复制"), systemImage: "doc.on.doc") }
                if push != nil {
                    Menu {
                        if entry.type == .txn {
                            if !entry.synthetic, let L = store.L, classify(entry, L).kind == .expense {
                                Button { refund() } label: { Label(LS("退款"), systemImage: "arrow.uturn.backward") }
                            }
                            Button { push?(TxDest(entry)) } label: { Label(LS("交易详情"), systemImage: "list.bullet.rectangle") }
                            ForEach(Array(Set(entry.postings.map(\.account))).sorted(), id: \.self) { account in
                                Button(acctDisplay(account)) { push?(AccountDest(name: account)) }
                            }
                        } else if let account = entry.account {
                            Button { push?(AccountDest(name: account)) } label: { Label(LS("查看账户"), systemImage: "building.columns") }
                        }
                    } label: { Label(LS("相关操作"), systemImage: "arrow.triangle.branch") }
                }
                Menu {
                    Button { source = EntrySourceTarget(entry: entry, ledgerID: store.cfg.id, editing: false) } label: { Label(LS("查看原文"), systemImage: "doc.text") }
                    if writable {
                        Button { source = EntrySourceTarget(entry: entry, ledgerID: store.cfg.id, editing: true) } label: { Label(LS("编辑源文本"), systemImage: "chevron.left.forwardslash.chevron.right") }
                    }
                    if let url = store.githubURL(entry.file, line: entry.line) {
                        Link(destination: url) { Label(LS("在网页中打开"), systemImage: "arrow.up.right.square") }
                    }
                } label: { Label(LS("源文件"), systemImage: "doc.text") }
                if writable {
                    Divider()
                    Button(role: .destructive) { askDelete() } label: { Label(LS("删除"), systemImage: "trash") }
                }
            }
            .accessibilityActions {
                if writable {
                    Button(LS("编辑")) { openEdit() }
                    Button(LS("删除")) { askDelete() }
                }
            }
            .entryDeletion($deletion)
            .sheet(item: $source) { EntrySourceSheet(target: $0) }
            .disabled(opening)
    }

    private func askDelete() {
        deletion = EntryDeletion(entry, ledgerID: store.cfg.id)
    }

    private func openEdit() {
        guard !opening else { return }
        if let edit = edit { Haptics.selection(); edit(); return }
        guard entry.type == .txn else {
            Haptics.selection()
            source = EntrySourceTarget(entry: entry, ledgerID: store.cfg.id, editing: true)
            return
        }
        let ledgerID = store.cfg.id
        let locator = EntryLocator(entry)
        opening = true
        Task { @MainActor in
            defer { opening = false }
            guard store.cfg.id == ledgerID, let current = locator.resolve(in: store.L?.entries ?? []) else {
                Haptics.error(); store.show(LS("记录或账本已变化，请重新打开后再试")); return
            }
            if !(await store.beginEdit(current)), store.cfg.id == ledgerID {
                Haptics.selection()
                source = EntrySourceTarget(entry: current, ledgerID: ledgerID, editing: true)
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.success()
        store.show(LS("已复制到剪贴板"))
    }

    private func refund() {
        guard let L = store.L, let D = store.D else { return }
        store.draft = refundDraft(entry, L, D, defaultFunding: store.defaultFunding)
        store.openAdd()
        store.show(LS("已生成退款草稿，请核对金额后保存"))
    }

    private func duplicate() {
        guard let L = store.L, let D = store.D else { return }
        var draft = draftFromTxn(entry, kind: nil, L, D, defaultFunding: store.defaultFunding)
        draft.date = Day.today()
        store.draft = draft
        store.openAdd()
        store.show(LS("已载入为新交易，请核对金额与日期"))
    }
}

struct EntrySourceTarget: Identifiable {
    let id = UUID()
    let entry: Entry
    let ledgerID: String
    let editing: Bool
}

/// Fallback for entries a visual form cannot represent, preserving comments and metadata.
struct EntrySourceSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: EntrySourceTarget
    @State private var text = ""
    @State private var original: String?
    @State private var ledgerID: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(target.entry.file) {
                    if target.editing {
                        CodeTextView(text: $text, language: .beancount, fontSize: 12.5, fitsContent: true)
                            .frame(minHeight: 180)
                    } else { MonoText(text: target.entry.src) }
                }
                if let error = error { Section { Text(error).foregroundStyle(Color.loss) } }
            }
            .keyboardDone()
            .navigationTitle(target.editing ? LS("编辑源文本") : LS("查看原文"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("完成")) { dismiss() }.disabled(busy) }
                if target.editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LS("保存")) { save() }.disabled(busy || original == nil || text.trimmed.isEmpty || text == original)
                    }
                }
            }
            .disabled(busy)
            .interactiveDismissDisabled(busy)
            .task {
                guard ledgerID == nil else { return }
                guard target.ledgerID == store.cfg.id else { dismiss(); return }
                ledgerID = target.ledgerID
                original = await store.entryText(target.entry)
                text = original ?? target.entry.src
                if original == nil { error = LS("记录或账本已变化，请重新打开后再试") }
            }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
        }
    }

    private func save() {
        guard !busy, let original = original, ledgerID == store.cfg.id else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let entry = target.entry
            guard await store.entryText(entry) == original, ledgerID == store.cfg.id else {
                error = LS("记录或账本已变化，请重新打开后再试"); Haptics.error(); return
            }
            // Keep one entry of the same kind; a text editor must not silently turn it into a batch.
            let parsed = parseFile(text, file: entry.file)
            guard parsed.errors.isEmpty, parsed.entries.count == 1,
                  parsed.includes.isEmpty, parsed.options.isEmpty, parsed.plugins.isEmpty,
                  parsed.entries.first?.type == entry.type,
                  entry.type != .custom || parsed.entries.first?.name == entry.name else {
                error = LS("请保留一条同类型记录，并检查源文本格式"); Haptics.error(); return
            }
            guard let ops = await store.replaceOps(old: original, path: entry.file, date: entry.date,
                summary: entryActionName(entry), newText: text, transaction: entry.type == .txn), ledgerID == store.cfg.id else { return }
            if await store.commit(ops, word: LS("已更新"), checked: true) { dismiss() }
        }
    }
}

extension View {
    func entryActions(_ entry: Entry, edit: (() -> Void)? = nil) -> some View {
        modifier(EntryActions(entry: entry, edit: edit))
    }

    @ViewBuilder
    func entryActions(_ entry: Entry?, edit: (() -> Void)? = nil) -> some View {
        if let entry = entry { entryActions(entry, edit: edit) } else { self }
    }

    func entryDeletion(_ request: Binding<EntryDeletion?>) -> some View {
        modifier(EntryDeletionModifier(request: request))
    }
}
