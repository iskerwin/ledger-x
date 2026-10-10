import SwiftUI
import LedgerKit

// Links between transactions: open a link to see everything it ties together, and point out links
// that lost their other half or whose amounts do not add up.

struct LinkDest: Hashable { let link: String }
struct LinkIssuesDest: Hashable {}

extension Store {
    /// link problems in the current ledger (ignored ones left out), computed once per rebuild
    var linkProblems: [LinkIssue] {
        guard let L = L else { return [] }
        let all: [LinkIssue]
        if let c = Store.linkCache, c.0 == version { all = c.1 } else {
            all = linkIssues(L, subscriptions: subs)
            Store.linkCache = (version, all)
        }
        let ignored = ignoredLinkIssues
        return ignored.isEmpty ? all : all.filter { !ignored.contains($0.key) }
    }
    static var linkCache: (Int, [LinkIssue])?

    var ignoredLinkIssues: Set<String> { Set(Prefs.get(pk("link.ignored"), [String]())) }

    func linkProblems(for t: Entry) -> [LinkIssue] { linkProblems.filter { $0.txn === t } }

    func ignoreLinkIssue(_ i: LinkIssue) {
        var x = Prefs.get(pk("link.ignored"), [String]())
        x.append(i.key)
        Prefs.set(pk("link.ignored"), x)
        objectWillChange.send()
    }

    func clearIgnoredLinkIssues() {
        Prefs.set(pk("link.ignored"), [String]())
        objectWillChange.send()
    }

    /// add or remove `^link` on a transaction
    func linkEditOp(_ e: Entry, link: String, remove: Bool) -> Op? {
        let text = headerLinkEdit(e.src, link: link, remove: remove)
        guard text != e.src else { return nil }
        var op = Op(kind: .replace, path: e.file)
        op.old = e.src
        op.text = text
        op.date = e.date
        return op
    }

    /// one commit: put `link` on all of `txns`
    func addLink(_ link: String, to txns: [Entry], closing: () -> Void) async {
        var ops = txns.compactMap { linkEditOp($0, link: link, remove: false) }
        guard !ops.isEmpty else { closing(); return }
        ops[0].label = LS("关联 ^%@：%@ 笔", link, ops.count)
        for i in ops.indices.dropFirst() { ops[i].silent = true }
        await commit(ops, word: LS("已关联"), closing: closing)
    }

    func removeLink(_ link: String, from t: Entry) async {
        guard var op = linkEditOp(t, link: link, remove: true) else { return }
        op.label = LS("移除链接 ^%@：%@ %@", link, t.date, t.payee)
        // a refund's partner loses the link too
        let paired = pairedLinkOps(oldText: t.src, newText: op.text)
        await commit([op] + paired, word: LS("已移除链接"))
    }
}

// MARK: - transaction detail: grouped links

/// the transaction's links, each with the other transactions it ties to and their totals
struct LinkGroupsSection: View {
    @EnvironmentObject var store: Store
    let t: Entry
    let L: Ledger
    let D: Derived

    var body: some View {
        ForEach(t.links, id: \.self) { l in
            let all = (D.byLink[l] ?? []).filter { !$0.synthetic }
            let others = all.filter { $0 !== t }
            let figs = all.count > 1 ? linkFigures(l, all, L) : []
            Section {
                ForEach(others, id: \.id) { r in NavigationLink(value: TxDest(r)) { TxRow(t: r, showDate: true) } }
                if others.isEmpty {
                    Text(LS("没有其他交易使用这个链接")).font(.subheadline).foregroundStyle(.secondary)
                }
                if !figs.isEmpty { LinkFiguresRow(figs: figs) }
                if LinkRole.of(l) == .subscription, let s = store.subs.first(where: { $0.link == l }) {
                    NavigationLink(value: SubDetailDest(name: s.name)) { Label(LS("订阅：%@", s.name), systemImage: "repeat") }
                }
            } header: {
                HStack {
                    Text(LS("关联交易") + " · " + LinkRole.of(l).title)
                    Spacer()
                    Text("^" + l).lineLimit(1).textCase(nil)
                }
            }
        }
    }
}

struct LinkFiguresRow: View {
    let figs: [LinkFigure]
    var body: some View {
        HStack(alignment: .top) {
            ForEach(Array(figs.enumerated()), id: \.offset) { i, f in
                if i > 0 { Spacer() }
                VStack(alignment: i == 0 ? .leading : i == figs.count - 1 ? .trailing : .center, spacing: 2) {
                    Text(f.label).font(.caption).foregroundStyle(.secondary)
                    Text(money(f.value)).font(.subheadline.weight(.semibold).monospacedDigit()).sensitive()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - transaction detail: problems and fixes

/// what to do about a link problem from the transaction it is on
struct LinkIssueSection: View {
    @EnvironmentObject var store: Store
    let t: Entry
    @State private var pick: LinkPick?
    @State private var subPick: Entry?
    @Binding var subDraft: SubDraft?

    struct LinkPick: Identifiable {
        let link: String
        /// also put the link on the transaction itself (it had none yet)
        let includeSelf: Bool
        var id: String { link }
    }

    var body: some View {
        let issues = store.linkProblems(for: t)
        if !issues.isEmpty {
            Section {
                ForEach(issues) { i in
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.title).font(.subheadline.weight(.semibold))
                                Text(i.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: i.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(i.isError ? Color.loss : Color.warn)
                        }
                        HStack(spacing: 8) { fixes(i) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(LS("链接检查"))
            }
            .sheet(item: $pick) { p in
                LinkPickSheet(t: t, link: p.link) { picked in
                    await store.addLink(p.link, to: (p.includeSelf ? [t] : []) + picked, closing: { pick = nil })
                }
            }
            .sheet(item: $subPick) { e in
                SubPickSheet(t: e) { if let L = store.L { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { subDraft = SubDraft(e, L) } } }
            }
        }
    }

    @ViewBuilder
    private func fixes(_ i: LinkIssue) -> some View {
        switch i.kind {
        case .refundAlone, .refundNoPurchase:
            if let l = i.link {
                Button(LS("选择原交易")) { pick = LinkPick(link: l, includeSelf: false) }
                Button(LS("移除链接"), role: .destructive) { Task { await store.removeLink(l, from: t) } }
            }
        case .refundUnlinked:
            Button(LS("选择原交易")) { pick = LinkPick(link: newRefundLink(t), includeSelf: true) }
        case .subUnknown:
            Button(LS("关联到订阅")) { subPick = t }
            if let l = i.link { Button(LS("移除链接"), role: .destructive) { Task { await store.removeLink(l, from: t) } } }
        case .single:
            if let l = i.link {
                Button(LS("选择关联交易")) { pick = LinkPick(link: l, includeSelf: false) }
                Button(LS("移除链接"), role: .destructive) { Task { await store.removeLink(l, from: t) } }
            }
        default:
            EmptyView()
        }
        Button(LS("忽略")) { store.ignoreLinkIssue(i) }
    }
}

/// choose the transactions that should share `link` with `t`
struct LinkPickSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let t: Entry
    let link: String
    let done: ([Entry]) async -> Void
    @State private var picked: Set<Int> = []
    @State private var saving = false

    var body: some View {
        let exp = t.postings.first { $0.account.hasPrefix("Expenses:") }
        let linked = Set((store.D?.byLink[link] ?? []).map { $0.id }).union([t.id])
        NavigationStack {
            TxPicker(hint: SubHint(payee: t.payee.isEmpty ? t.narration : t.payee, name: t.narration,
                                   account: exp?.account ?? "", amount: abs(exp?.units ?? 0)),
                     exclude: linked, picked: $picked)
                .navigationTitle(LinkRole.of(link) == .refund ? LS("选择原交易") : LS("选择关联交易"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LS("关联")) {
                            guard let L = store.L else { return }
                            let es = picked.sorted().compactMap { $0 < L.txns.count ? L.txns[$0] : nil }
                            saving = true
                            Task { await done(es); saving = false }
                        }
                        .disabled(picked.isEmpty || saving)
                    }
                }
        }
    }
}

// MARK: - one link

struct LinkDetailView: View {
    @EnvironmentObject var store: Store
    let link: String

    var body: some View {
        if let L = store.L, let D = store.D {
            let all = (D.byLink[link] ?? []).filter { !$0.synthetic }.sorted { $0.date < $1.date }
            let figs = linkFigures(link, all, L)
            let issues = store.linkProblems.filter { $0.link == link }
            List {
                Section {
                    LabeledContent(LS("用途"), value: LinkRole.of(link).title)
                    LabeledContent(LS("交易"), value: LS("%@ 笔", all.count))
                    if !figs.isEmpty { LinkFiguresRow(figs: figs) }
                    if LinkRole.of(link) == .subscription, let s = store.subs.first(where: { $0.link == link }) {
                        NavigationLink(value: SubDetailDest(name: s.name)) { Label(LS("订阅：%@", s.name), systemImage: "repeat") }
                    }
                }
                if !issues.isEmpty {
                    Section(LS("链接检查")) {
                        ForEach(issues) { i in LinkIssueRow(i: i) }
                    }
                }
                Section(LS("交易")) {
                    ForEach(all, id: \.id) { r in NavigationLink(value: TxDest(r)) { TxRow(t: r, showDate: true) } }
                }
            }
            .navigationTitle("^" + link)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ProgressView()
        }
    }
}

struct LinkIssueRow: View {
    @EnvironmentObject var store: Store
    let i: LinkIssue
    var body: some View {
        NavigationLink(value: TxDest(i.txn)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: i.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(i.isError ? Color.loss : Color.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.title).font(.subheadline)
                    Text(i.txn.date + " · " + (i.txn.payee.isEmpty ? i.txn.narration : i.txn.payee)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(i.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .swipeActions { Button(LS("忽略")) { store.ignoreLinkIssue(i) }.tint(.gray) }
    }
}

/// every link problem in the ledger
struct LinkIssuesView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let issues = store.linkProblems
        let errors = issues.filter { $0.isError }, warnings = issues.filter { !$0.isError }
        let ignored = store.ignoredLinkIssues.count
        List {
            if issues.isEmpty {
                Label(LS("未发现链接问题"), systemImage: "checkmark.seal").foregroundStyle(Color.gain)
            }
            if !errors.isEmpty {
                Section(LS("错误 · %@", errors.count)) { ForEach(errors) { LinkIssueRow(i: $0) } }
            }
            if !warnings.isEmpty {
                Section(LS("提醒 · %@", warnings.count)) { ForEach(warnings) { LinkIssueRow(i: $0) } }
            }
            Section {
                if ignored > 0 { Button(LS("恢复已忽略的 %@ 项", ignored)) { store.clearIgnoredLinkIssues() } }
            } footer: {
                Text(LS("检查退款、报销和订阅链接：链接只剩一笔、找不到原交易或垫付、金额对不上、科目不一致，以及带 #refund / #reimbursement 却没有链接的交易。左滑可忽略。"))
            }
        }
        .navigationTitle(LS("链接检查"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
