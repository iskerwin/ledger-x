import SwiftUI
import LedgerKit

// Links between transactions: open a link to see everything it ties together, and point out links
// that lost their other half or whose amounts do not add up.

struct LinkDest: Hashable { let link: String }

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

/// a "choose the other transactions" fix: put `link` on the picked ones (and on `t` when it has none yet)
struct LinkPick: Identifiable {
    let t: Entry
    let link: String
    let includeSelf: Bool
    var id: String { link }
}

extension View {
    /// ask before taking a link off a transaction (lives on the detail page, not in a List section)
    func linkRemovalDialog(_ removing: Binding<LinkPick?>, store: Store) -> some View {
        confirmationDialog(LS("从这笔交易移除 ^%@？", removing.wrappedValue?.link ?? ""),
                           isPresented: Binding(get: { removing.wrappedValue != nil }, set: { if !$0 { removing.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: removing.wrappedValue) { r in
            Button(LS("移除链接"), role: .destructive) { Task { await store.removeLink(r.link, from: r.t) } }
        } message: { _ in
            Text(LS("只修改这笔交易的第一行，金额和分录不变。"))
        }
    }
}

/// what to do about a link problem from the transaction it is on. The sheets live on the detail page:
/// a sheet attached to a List section is copied onto every row, and goes away with the row.
struct LinkIssueSection: View {
    @EnvironmentObject var store: Store
    let t: Entry
    @Binding var pick: LinkPick?
    @Binding var subPick: Entry?
    @Binding var removing: LinkPick?

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
        }
    }

    @ViewBuilder
    private func fixes(_ i: LinkIssue) -> some View {
        switch i.kind {
        case .refundAlone, .refundNoPurchase:
            if let l = i.link {
                Button(LS("选择原交易")) { pick = LinkPick(t: t, link: l, includeSelf: false) }
                Button(LS("移除链接"), role: .destructive) { removing = LinkPick(t: t, link: l, includeSelf: false) }
            }
        case .refundUnlinked:
            Button(LS("选择原交易")) { pick = LinkPick(t: t, link: newRefundLink(t, taken: Set(store.D?.allLinks ?? [])), includeSelf: true) }
        case .subUnknown:
            Button(LS("关联到订阅")) { subPick = t }
            if let l = i.link { Button(LS("移除链接"), role: .destructive) { removing = LinkPick(t: t, link: l, includeSelf: false) } }
        case .single:
            if let l = i.link {
                Button(LS("选择关联交易")) { pick = LinkPick(t: t, link: l, includeSelf: false) }
                Button(LS("移除链接"), role: .destructive) { removing = LinkPick(t: t, link: l, includeSelf: false) }
            }
        default:
            EmptyView()
        }
        Button(LS("忽略")) { store.ignoreLinkIssue(i) }
    }
}

/// choose the transactions that should share the link, check what will change, then one commit
struct LinkPickSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let pick: LinkPick
    @State private var picked: Set<Int> = []
    @State private var confirming = false
    /// the ledger the picker's row numbers refer to (a sync while picking must not shift them)
    @State private var snapshot: Ledger?

    var body: some View {
        let t = pick.t
        let exp = t.postings.first { $0.account.hasPrefix("Expenses:") }
        let linked = Set((store.D?.byLink[pick.link] ?? []).map { $0.id }).union([t.id])
        NavigationStack {
            TxPicker(hint: SubHint(payee: t.payee.isEmpty ? t.narration : t.payee, name: t.narration,
                                   account: exp?.account ?? "", amount: abs(exp?.units ?? 0)),
                     exclude: linked, picked: $picked)
                .navigationTitle(LinkRole.of(pick.link) == .refund ? LS("选择原交易") : LS("选择关联交易"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LS("下一步")) { confirming = true }.disabled(picked.isEmpty)
                    }
                }
                .navigationDestination(isPresented: $confirming) {
                    LinkConfirmView(pick: pick, chosen: chosen) { dismiss() }
                }
        }
        .onAppear { if snapshot == nil { snapshot = store.L } }
    }

    private var chosen: [Entry] {
        guard let L = snapshot ?? store.L else { return [] }
        return picked.sorted().compactMap { $0 >= 0 && $0 < L.txns.count ? L.txns[$0] : nil }
    }
}

/// what linking will change: each transaction's first line before and after, and the totals afterwards
struct LinkConfirmView: View {
    @EnvironmentObject var store: Store
    let pick: LinkPick
    let chosen: [Entry]
    let close: () -> Void
    @State private var saving = false
    /// a new link can be renamed before it is written; an existing one stays as it is
    @State private var name: String

    init(pick: LinkPick, chosen: [Entry], close: @escaping () -> Void) {
        self.pick = pick; self.chosen = chosen; self.close = close
        _name = State(initialValue: pick.link)
    }

    private var link: String { name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^", with: "") }
    /// empty = fine
    private var nameProblem: String {
        if !isValidLink(link) { return LS("链接只能包含英文字母、数字和 - _ / .") }
        if link != pick.link, store.D?.byLink[link] != nil { return LS("这个链接已被其他交易使用") }
        return ""
    }

    var body: some View {
        let targets = (pick.includeSelf ? [pick.t] : []) + chosen
        let link = self.link
        let role = LinkRole.of(link)
        let existing = (store.D?.byLink[link] ?? []).filter { !$0.synthetic }
        var group = existing
        for e in targets where !group.contains(where: { $0 === e }) { group.append(e) }
        let figs = store.L.map { linkFigures(link, group, $0) } ?? []
        let net = figs.last?.value ?? 0
        let problem = nameProblem
        return List {
            Section {
                if pick.includeSelf {
                    LabeledContent(LS("链接")) {
                        TextField("refund-…", text: $name)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }
                    if !problem.isEmpty { Text(problem).font(.footnote).foregroundStyle(Color.loss) }
                } else {
                    LabeledContent(LS("链接"), value: "^" + link)
                }
                LabeledContent(LS("用途"), value: role.title)
                LabeledContent(LS("关联后共"), value: LS("%@ 笔", group.count))
                if !figs.isEmpty { LinkFiguresRow(figs: figs) }
                if role == .refund && net < -0.005 {
                    Label(LS("退款合计大于原价，请确认选择的是否是对应的原交易"), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Color.warn)
                }
            } header: {
                Text(LS("关联结果"))
            }
            Section {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 6) {
                        TxRow(t: e, showDate: true)
                        let before = e.src.components(separatedBy: "\n").first ?? ""
                        let after = headerLinkEdit(e.src, link: link, remove: false).components(separatedBy: "\n").first ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            Text("− " + before).foregroundStyle(Color.loss)
                            Text("+ " + after).foregroundStyle(Color.gain)
                        }
                        .font(.caption2.monospaced())
                        .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(LS("将修改 %@ 笔交易", targets.count))
            } footer: {
                Text(LS("只在每笔交易的第一行加上链接，金额和分录不变；所有修改在一次提交中完成，提交前会再做账本检查。"))
            }
        }
        .navigationTitle(LS("确认关联"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                saving = true
                Task {
                    await store.addLink(link, to: targets, closing: close)
                    saving = false
                }
            } label: {
                Text(saving ? LS("提交中…") : LS("确认关联")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding().disabled(saving || targets.isEmpty || !problem.isEmpty)
            .background(.bar)
        }
        .interactiveDismissDisabled(saving)
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
