import SwiftUI
import LedgerKit

/// points at a transaction by position, and by its text so it survives a re-sync
struct TxDest: Hashable {
    let id: Int
    let key: String
    init(_ t: Entry) { id = t.id; key = TxDest.key(t) }
    static func key(_ t: Entry) -> String { t.date + "\u{1}" + t.src }
}
struct AccountDest: Hashable { let name: String }
struct EditDest: Hashable {
    let id: Int
    let key: String
    init(_ t: Entry) { id = t.id; key = TxDest.key(t) }
}

extension Store {
    func txn(_ id: Int, key: String) -> Entry? {
        guard let L = L else { return nil }
        if id >= 0, id < L.txns.count, TxDest.key(L.txns[id]) == key { return L.txns[id] }
        return L.txns.first { TxDest.key($0) == key }
    }
}

struct TxRow: View {
    @EnvironmentObject var store: Store
    let t: Entry
    var account: String? = nil
    var balance: String? = nil
    var showDate = false

    var body: some View {
        if let L = store.L, let D = store.D {
            let c = classify(t, L)
            let cat = t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(t.payee.isEmpty ? (t.narration.isEmpty ? LS("（无收付款方）") : t.narration) : t.payee).lineLimit(1)
                        if !t.payee.isEmpty && !t.narration.isEmpty { Text(t.narration).foregroundStyle(.secondary).lineLimit(1) }
                        if t.flag == "!" { Tag(text: LS("待确认"), warn: true) }
                        if t.synthetic { Tag(text: "pad") }
                        ForEach(t.tags.filter { $0 != "transfer" }, id: \.self) { Tag(text: "#" + $0) }
                    }
                    .font(.body)
                    Text((showDate ? t.date + "  " : "") + (cat.map { acctDisplay($0.account) } ?? t.postings.map { D.shortName($0.account) }.joined(separator: " → ")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    amountView(c)
                    if let b = balance { Text(b).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive() }
                }
            }
        }
    }

    @ViewBuilder
    private func amountView(_ c: Classified) -> some View {
        if let a = account {
            let ps = t.postings.filter { $0.account == a || $0.account.hasPrefix(a + ":") }
            let byC = Dictionary(grouping: ps, by: { $0.currency ?? "" }).mapValues { list in list.reduce(0.0) { $0 + ($1.units ?? 0) } }
            HStack(spacing: 6) {
                ForEach(byC.keys.sorted(), id: \.self) { cc in Amount(n: byC[cc]!, c: cc, signed: true, color: true) }
            }
        } else if c.kind == .transfer {
            Text(money(c.amount, c.currency ?? "CNY")).monospacedDigit().foregroundStyle(.secondary).sensitive()
        } else {
            Amount(n: c.amount, signed: true, color: true)
        }
    }
}

struct Tag: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(warn ? Color.orange.opacity(0.18) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .lineLimit(1)
    }
}

/// a parsed search box: every word must match
struct TxQuery {
    enum Word { case flag, tag(String), link(String), gt(Double), lt(Double), amount(Double, String), date(String), text(String) }
    let words: [Word]

    init(_ q: String) {
        words = q.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).map { w0 -> Word in
            let w = String(w0)
            if w == "!" { return .flag }
            if w.hasPrefix("#") { return .tag(String(w.dropFirst())) }
            if w.hasPrefix("^") { return .link(String(w.dropFirst())) }
            if w.range(of: #"^[<>]?\d+(\.\d+)?$"#, options: .regularExpression) != nil {
                let n = Double(w.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))) ?? 0
                if w.hasPrefix(">") { return .gt(n) }
                if w.hasPrefix("<") { return .lt(n) }
                return .amount(n, w)
            }
            if w.range(of: #"^\d{4}-\d{2}(-\d{2})?$"#, options: .regularExpression) != nil { return .date(w) }
            return .text(w)
        }
    }

    var isEmpty: Bool { words.isEmpty }

    func matches(_ t: Entry) -> Bool {
        for w in words {
            switch w {
            case .flag: if t.flag != "!" { return false }
            case .tag(let x): if !t.tags.contains(where: { $0.contains(x) }) { return false }
            case .link(let x): if !t.links.contains(where: { $0.contains(x) }) { return false }
            case .gt(let n): if !t.postings.contains(where: { abs($0.units ?? 0) > n }) { return false }
            case .lt(let n): if !t.postings.allSatisfy({ abs($0.units ?? 0) < n }) { return false }
            case .amount(let n, let raw):
                if !(t.postings.contains(where: { abs(abs($0.units ?? 0) - n) < 0.005 }) || t.date.contains(raw)) { return false }
            case .date(let d): if !t.date.hasPrefix(d) { return false }
            case .text(let x):
                let lw = x.lowercased()
                if !((t.payee + " " + t.narration).lowercased().contains(lw) || t.postings.contains(where: { $0.account.lowercased().contains(lw) || acctDisplay($0.account).contains(x) })) { return false }
            }
        }
        return true
    }
}

struct JournalView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @State private var q = ""
    @State private var limit = 150
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var batch: BatchMode?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L { list(L) } else { ProgressView() }
            }
            .navigationTitle(LS("明细"))
            .toolbar {
                StandardToolbar()
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? LS("完成") : LS("选择")) {
                        withAnimation { selecting.toggle(); selected = [] }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if selecting { batchBar } }
            .sheet(item: $batch) { m in
                BatchEditSheet(entries: selectedEntries, mode: m) { selecting = false; selected = [] }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: LS("收付款方、摘要、科目、#标签、金额、2026-09"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: q) { _, _ in limit = 150 }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0) }
            .subscriptionDestinations()
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name) }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            if let q = store.demoEnv["LEDGER_QUERY"] { self.q = q }
            if store.demoEnv["LEDGER_SELECT"] != nil, let L = store.L {
                selecting = true
                selected = Set(search(L).prefix(4).map { TxDest.key($0) })
            }
            if let l = store.demoEnv["LEDGER_OPEN_LINK"], let L = store.L, path.isEmpty,
               let t = L.txns.first(where: { $0.links.contains(l) }) {
                path.append(TxDest(t))
            }
            if store.demoEnv["LEDGER_OPEN_TX"] != nil, let L = store.L, path.isEmpty {
                let id = L.txns.lastIndex(where: { isComplex($0) && !$0.synthetic }) ?? L.txns.count - 1
                path.append(TxDest(L.txns[id]))
            }
        }
    }

    private var selectedEntries: [Entry] {
        guard let L = store.L else { return [] }
        return L.txns.filter { !$0.synthetic && selected.contains(TxDest.key($0)) }
    }

    private var batchBar: some View {
        HStack(spacing: 10) {
            Button {
                if let L = store.L {
                    let keys = search(L).prefix(limit).filter { !$0.synthetic }.map { TxDest.key($0) }
                    selected = selected.count >= keys.count ? [] : Set(keys)
                }
            } label: { Text(LS("全选")).font(.subheadline) }
            Text(LS("已选 %@ 笔", selected.count)).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(BatchMode.allCases) { m in Button(m.name) { batch = m } }
            } label: {
                Label(LS("批量编辑"), systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var account: String? {
        get { store.journalAccount }
        nonmutating set { store.journalAccount = newValue }
    }

    @ViewBuilder
    private func list(_ L: Ledger) -> some View {
        let matches = search(L)
        let shown = Array(matches.prefix(limit))
        let sums = totals(matches, L)
        let days = groupByDay(shown)
        List {
            Section {
                ChipRow {
                    if let a = account { Chip(label: acctDisplay(a) + " ✕", selected: true) { account = nil } }
                    ForEach(["#reimbursed", "#refund", "#transfer", "#fx", "!"], id: \.self) { x in
                        Chip(label: x == "!" ? LS("! 待确认") : x, selected: q == x) { q = q == x ? "" : x }
                    }
                }
                HStack {
                    Text(LS("%@ 笔", matches.count)).foregroundStyle(.secondary)
                    Spacer()
                    Group {
                        if sums.0 != 0 { Text(LS("支出 ") + money(sums.0)) }
                        if sums.1 != 0 { Text(LS("收入 ") + money(sums.1)) }
                    }
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                }
                .font(.footnote)
            }
            ForEach(days, id: \.0) { group in
                daySection(group.0, group.1, L)
            }
            if matches.count > shown.count {
                Button(LS("加载更多（%@ 笔）", min(300, matches.count - shown.count))) { limit += 300 }.frame(maxWidth: .infinity)
            }
            if matches.isEmpty { Text(LS("无匹配交易")).foregroundStyle(.secondary) }
        }
        .listStyle(.insetGrouped)
    }

    private func search(_ L: Ledger) -> [Entry] {
        var out: [Entry] = []
        let a = account
        let query = TxQuery(q.trimmed)
        for t in L.txns.reversed() {
            if let a = a, !t.postings.contains(where: { $0.account == a || $0.account.hasPrefix(a + ":") }) { continue }
            if query.matches(t) { out.append(t) }
        }
        return out
    }

    private func totals(_ ts: [Entry], _ L: Ledger) -> (Double, Double) {
        var out = 0.0, inn = 0.0
        for t in ts {
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: out -= c.amount
            case .income: inn += c.amount
            default: break
            }
        }
        return (out, inn)
    }

    private func daySection(_ day: String, _ ts: [Entry], _ L: Ledger) -> some View {
        var out = 0.0
        for x in ts {
            let c = classify(x, L)
            if c.kind == .expense || c.kind == .refund { out -= c.amount }
        }
        let year = day.prefix(4) != Day.today().prefix(4) ? " " + day.prefix(4) : ""
        return Section {
            ForEach(ts, id: \.id) { t in
                if selecting {
                    let key = TxDest.key(t)
                    Button {
                        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(key) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(key) ? Color.jade : Color.secondary)
                            TxRow(t: t, account: account)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(t.synthetic)
                } else {
                    NavigationLink(value: TxDest(t)) { TxRow(t: t, account: account) }
                }
            }
        } header: {
            HStack {
                Text(Day.dayLabel(day) + year)
                Spacer()
                if out != 0 { Text(money(out)).monospacedDigit().sensitive() }
            }
        }
    }

    private func groupByDay(_ ts: [Entry]) -> [(String, [Entry])] {
        var out: [(String, [Entry])] = []
        for t in ts {
            if let last = out.last, last.0 == t.date { out[out.count - 1].1.append(t) } else { out.append((t.date, [t])) }
        }
        return out
    }
}

// MARK: - detail

struct TxDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let dest: TxDest
    @State private var subDraft: SubDraft?
    @State private var subPick: Entry?

    var body: some View {
        if let L = store.L, let D = store.D, let t = store.txn(dest.id, key: dest.key) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.payee.isEmpty ? (t.narration.isEmpty ? LS("交易") : t.narration) : t.payee).font(.title2.weight(.semibold))
                        Text(t.date + (!t.payee.isEmpty && !t.narration.isEmpty ? " · " + t.narration : "")).foregroundStyle(.secondary)
                        if !t.tags.isEmpty {
                            HStack { ForEach(t.tags, id: \.self) { Tag(text: "#" + $0) } }
                        }
                    }
                    .padding(.vertical, 4)
                    // links: open one to see everything it ties together
                    ForEach(t.links, id: \.self) { l in
                        let n = (D.byLink[l] ?? []).filter { !$0.synthetic }.count
                        NavigationLink(value: LinkDest(link: l)) {
                            HStack {
                                Label("^" + l, systemImage: "link").lineLimit(1)
                                Spacer()
                                Text(LinkRole.of(l).title + " · " + LS("%@ 笔", n)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                LinkIssueSection(t: t, subDraft: $subDraft)
                Section(LS("分录")) {
                    ForEach(Array(t.postings.enumerated()), id: \.offset) { pair in
                        PostingRow(p: pair.element)
                    }
                }
                if !t.meta.isEmpty {
                    Section(LS("元数据")) {
                        ForEach(t.meta.items, id: \.0) { item in LabeledContent(item.0, value: item.1.display) }
                    }
                }
                LinkGroupsSection(t: t, L: L, D: D)
                if !t.synthetic { AttachmentsSection(t: t) }
                Section {
                    MonoText(text: t.src)
                } header: {
                    Text(LS("Beancount 源文本 · %@:%@", t.file, t.line)).textCase(nil)
                }
                Section {
                    if t.synthetic {
                        Text(LS("此交易由 pad 指令自动生成，如需调整请修改对应的 pad 或余额断言。")).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        NavigationLink(value: EditDest(t)) { Label(LS("编辑"), systemImage: "pencil") }
                        Button { again(t, L, D, kind: nil) } label: { Label(LS("复制为新交易"), systemImage: "arrow.uturn.forward") }
                        if classify(t, L).kind == .expense {
                            Button { refund(t, L, D) } label: { Label(LS("登记退款"), systemImage: "arrow.uturn.backward") }
                            if let s = store.subs.first(where: { s in s.charges.contains { $0.txn.id == t.id } }) {
                                NavigationLink(value: SubDetailDest(name: s.name)) {
                                    Label(LS("订阅：%@", s.name), systemImage: "repeat")
                                }
                            } else {
                                Button { subPick = t } label: { Label(LS("加入订阅管理"), systemImage: "repeat") }
                            }
                        }
                    }
                    Button {
                        UIPasteboard.general.string = t.src
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        store.show(LS("已复制到剪贴板"))
                    } label: { Label(LS("复制源文本"), systemImage: "doc.on.doc") }
                    if let u = store.githubURL(t.file, line: t.line) { Link(destination: u) { Label(LS("在网页中打开"), systemImage: "arrow.up.right.square") } }
                }
            }
            .navigationTitle(t.date)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $subDraft) { SubEditSheet(draft: $0) }
            .sheet(item: $subPick) { e in
                SubPickSheet(t: e) { if let L = store.L { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { subDraft = SubDraft(e, L) } } }
            }
        } else {
            Text(LS("该交易已不存在")).foregroundStyle(.secondary)
        }
    }

    private func linkTo(_ s: Subscription, _ t: Entry) async {
        let ops = await store.linkOps([t], link: s.link, label: LS("关联订阅：%@ %@ 笔", s.name, 1))
        guard !ops.isEmpty else { return }
        await store.commit(ops, word: LS("已关联到 %@", s.name))
    }

    private func again(_ t: Entry, _ L: Ledger, _ D: Derived, kind: DraftKind?) {
        var d = draftFromTxn(t, kind: kind, L, D, defaultFunding: store.defaultFunding)
        d.date = Day.today()
        handOff(d, LS("已载入为新交易，请核对金额与日期"))
    }

    private func refund(_ t: Entry, _ L: Ledger, _ D: Derived) {
        handOff(refundDraft(t, L, D, defaultFunding: store.defaultFunding), LS("已生成退款草稿，请核对金额后保存"))
    }

    /// hand a filled form to 记一笔: close any open detail pages and switch tabs
    private func handOff(_ d: Draft, _ msg: String) {
        store.draft = d
        store.popToken += 1
        store.tab = .add
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.show(msg)
    }
}

struct PostingRow: View {
    let p: Posting
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text((p.flag.map { $0 + " " } ?? "") + p.account).font(.subheadline).lineLimit(2)
                Spacer()
                if let u = p.units, let c = p.currency {
                    Text(money(u, c, abs(u) < 1 && (p.digits ?? 2) > 2 ? 4 : 2)).monospacedDigit().sensitive()
                }
            }
            if !details.isEmpty {
                Text(details).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
            }
            ForEach(p.meta.items, id: \.0) { item in
                Text(item.0 + ": " + item.1.display).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var details: String {
        var parts: [String] = []
        if let pr = p.price, let n = pr.number { parts.append("@ \(fmtNum(n, 4)) \(pr.currency ?? "")") }
        if let c = p.cost, let n = c.number { parts.append("{\(fmtNum(n, 4)) \(c.currency ?? "")\(c.date.map { ", " + $0 } ?? "")}") }
        if p.interpolated { parts.append(LS("自动补平")) }
        return parts.joined(separator: "  ")
    }
}

// MARK: - edit

struct EditTxView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let dest: EditDest
    @State private var old: String?
    @State private var text = ""
    @State private var path = ""
    @State private var summary = ""
    @State private var date = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let old = old, let L = store.L {
                let aligned = alignText(text)
                let v = validateText(aligned, L, single: true)
                Section {
                    TextEditor(text: $text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 200)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if v.ok { Label(LS("校验通过"), systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Color.gain) }
                    else if let m = v.msg { Label(m, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.loss) }
                } header: {
                    Text(LS("所在文件：%@。修改日期后将按新日期重新排序。", path)).textCase(nil)
                }
                Section {
                    Button { Task { await save(old, L) } } label: { Text(LS("保存修改")).frame(maxWidth: .infinity).fontWeight(.semibold) }
                        .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large)
                        .disabled(!v.ok || aligned.trimmed == old.trimmed)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                Section {
                    Button(LS("删除交易"), role: .destructive) { confirmDelete = true }
                }
            } else {
                ProgressView()
            }
        }
        .keyboardDone()
        .navigationTitle(LS("编辑交易"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(LS("删除 %@ %@？", date, summary), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(LS("删除"), role: .destructive) { Task { await delete() } }
        }
        .task { await load() }
    }

    private func load() async {
        guard old == nil, let t = store.txn(dest.id, key: dest.key) else { return }
        path = t.file
        date = t.date
        summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        do {
            let file = try await store.fileText(t.file)
            let lines = file.components(separatedBy: "\n")
            guard t.endLine < lines.count else { return }
            let o = lines[t.startLine...t.endLine].joined(separator: "\n")
            old = o
            text = compactText(o)
        } catch {
            store.show(error.localizedDescription)
        }
    }

    private func save(_ old: String, _ L: Ledger) async {
        var rm = Op(kind: .remove, path: path)
        rm.old = old
        rm.label = LS("修改：%@ %@", date, summary)
        let newText = alignText(text)
        guard let ins = store.makeOps(newText, extra: OpExtra(silent: true), single: true),
              let ops = await store.review([rm] + ins + store.pairedLinkOps(oldText: old, newText: newText)) else { return }
        store.popToken += 1
        await store.commit(ops, word: LS("已更新"), checked: true)
    }

    private func delete() async {
        guard let old = old else { return }
        var rm = Op(kind: .remove, path: path)
        rm.old = old
        rm.label = LS("删除：%@ %@", date, summary)
        guard let ops = await store.review([rm] + store.pairedLinkOps(oldText: old, newText: nil)) else { return }
        store.popToken += 1
        await store.commit(ops, word: LS("已删除"), checked: true)
    }
}
