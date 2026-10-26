import SwiftUI
import LedgerKit

struct ReimbursementsDest: Hashable {}
struct ReimbBatchDest: Hashable { let link: String }
struct UnclaimedDest: Hashable {}

extension Store {
    /// write 支出类型 (`category:`) or 凭证类型 (`voucher:`) on an advance; nil value clears it
    func setAdvanceMeta(_ t: Entry, key: String, value: String?) async {
        guard let D = D, let text = setPostingMeta(t.src, account: D.receivable, key: key, value: value), text != t.src else { return }
        var op = Op(kind: .replace, path: t.file)
        op.old = t.src
        op.text = text
        op.date = t.date
        let what = key == categoryMeta ? LS("支出类型") : LS("凭证类型")
        op.label = LS("%@：%@ %@ → %@", what, t.date, t.payee, value.map { key == categoryMeta ? acctLabel($0) : $0 } ?? LS("清除"))
        await commit([op], word: LS("已修改"))
    }

    /// put advances on a reimbursement or petty cash: `#reimbursed ^link` on each, one commit
    @discardableResult
    func linkAdvances(_ es: [Entry], link: String, label: String) async -> Bool {
        let ledgerID = cfg.id
        var ops: [Op] = []
        var done = Set<ObjectIdentifier>()
        for e in es {
            guard done.insert(ObjectIdentifier(e)).inserted else { continue }
            guard let file = try? await fileText(e.file) else { show(LS("无法读取 %@", e.file)); return false }
            guard cfg.id == ledgerID, let current = EntryLocator(e).resolve(in: parseFile(file, file: e.file).entries) else {
                show(LS("记录或账本已变化，请重新打开后再试")); return false
            }
            let lines = file.components(separatedBy: "\n")
            guard current.startLine < lines.count else { return false }
            var op = Op(kind: .link, path: e.file)
            op.headerLine = current.startLine + 1
            op.header = lines[current.startLine]
            op.add = (e.tags.contains("reimbursed") ? "" : " #reimbursed") + " ^" + link
            op.link = link
            op.silent = !ops.isEmpty
            if ops.isEmpty { op.label = label }
            ops.append(op)
        }
        guard cfg.id == ledgerID, !ops.isEmpty else { return false }
        return await commit(ops, word: LS("已关联"))
    }
}

/// 报表 → 报销: everything about reimbursements in one place — what is waiting, the petty cash and open claims,
/// and every settled one by year
struct ReimbursementsView: View {
    @Environment(Store.self) var store
    @State private var pettyCash = false

    var body: some View {
        List {
            if let L = store.L, let D = store.D {
                let all = reimbBatches(L)
                let open = all.filter { !$0.settled }
                let done = all.filter { $0.settled }
                let waiting = D.unclaimed.reduce(0.0) { $0 + $1.amount }
                let inHand = D.floats.reduce(0.0) { $0 + max(0, $1.left) }
                let balance = (L.final[D.receivable] ?? [:]).reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key) ?? 0) }
                Section {
                    LabeledContent(LS("待报销")) { Amount(n: waiting) }
                    if inHand > 0.005 { LabeledContent(LS("备用金剩余")) { Amount(n: inHand) } }
                    LabeledContent(LS("报销应收余额")) { Amount(n: balance) }
                } footer: {
                    Text(LS("报销应收余额 = 垫付未回款 − 手上的备用金。"))
                }
                Section(LS("进行中")) {
                    NavigationLink(value: UnclaimedDest()) {
                        BatchRowLabel(title: LS("待报销"), caption: D.unclaimed.isEmpty ? LS("没有待报销的垫付")
                                      : LS("%@ 笔 · 最早 %@", D.unclaimed.count, D.unclaimed[0].t.date), amount: waiting, currency: "CNY")
                    }
                    ForEach(open) { b in NavigationLink(value: ReimbBatchDest(link: b.link)) { BatchRow(b: b) } }
                }
                let years = Array(Set(done.map { String($0.last.prefix(4)) })).sorted(by: >)
                ForEach(years, id: \.self) { y in
                    Section(LS("%@ 年 · 已结清", y)) {
                        ForEach(done.filter { $0.last.hasPrefix(y) }) { b in NavigationLink(value: ReimbBatchDest(link: b.link)) { BatchRow(b: b) } }
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
        .navigationTitle(LS("报销"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { pettyCash = true } label: { Label(LS("领取备用金"), systemImage: "banknote").labelStyle(ControlLabelStyle()) }
            }
        }
        .sheet(isPresented: $pettyCash) { PettyCashSheet() }
    }
}

struct BatchRowLabel: View {
    let title: String
    let caption: String
    let amount: Double
    let currency: String
    var body: some View {
        HStack(spacing: AppSpacing.control) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(title).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Amount(n: amount, c: currency)
        }
    }
}

struct BatchRow: View {
    let b: ReimbBatch
    var body: some View {
        let kind = b.kind == .float ? LS("备用金") : LS("报销")
        let dates = b.first == b.last ? b.first : b.first + " – " + b.last
        let state: String = b.settled ? LS("已结清") : b.kind == .float ? (b.balance < 0 ? LS("剩 %@", money(-b.balance, b.currency)) : LS("超支 %@", money(b.balance, b.currency)))
            : LS("待回款 %@", money(b.balance, b.currency))
        BatchRowLabel(title: kind + (b.payer.isEmpty ? "" : " · " + b.payer) + " · ^" + b.link,
                      caption: dates + " · " + LS("%@ 笔", b.count) + " · " + state,
                      amount: b.kind == .float ? b.received : b.advanced, currency: b.currency)
    }
}

/// one advance or receipt: date, merchant, amount, and its 支出类型 / 凭证类型
struct ReimbLineRow: View {
    let l: ReimbLine
    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.control) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text([l.payee, l.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                if l.income {
                    Text(l.date + " · " + LS("收到")).font(.caption).foregroundStyle(.secondary)
                } else {
                    (Text(l.date + " · ")
                     + Text(l.category.isEmpty ? LS("未填支出类型") : l.category + (l.guessed ? LS("（推测）") : ""))
                        .foregroundColor(l.category.isEmpty || l.guessed ? Color.warn : .secondary)
                     + Text(" · ")
                     + Text(l.voucher.isEmpty ? LS("凭证未填") : l.voucher).foregroundColor(l.voucher.isEmpty ? Color.warn : .secondary))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text((l.income ? "+" : "") + money(l.amount, l.currency)).monospacedDigit()
                .foregroundStyle(l.income ? Color.gain : Color.loss).sensitive()
        }
    }
}

/// a list of advances with the edits every reimbursement page shares: open the transaction, set 支出类型 /
/// 凭证类型, take it off the batch
struct ReimbLinesSection: View {
    @Environment(Store.self) var store
    let title: String
    let lines: [ReimbLine]
    /// the batch the advances are on (nil: not on one yet)
    let link: String?
    @State private var typing: Entry?
    @State private var voucherFor: Entry?
    @State private var removing: Entry?

    var body: some View {
        Section {
            if lines.isEmpty { Text(LS("没有交易")).foregroundStyle(.secondary) }
            ForEach(lines) { l in
                NavigationLink(value: TxDest(l.entry)) { ReimbLineRow(l: l) }
                    .rowActions(edge: .trailing) {
                        if !l.income && editable(l.entry) {
                            Button { typing = l.entry } label: { Label(LS("类型"), systemImage: "tag") }.tint(Color.warn)
                            Button { voucherFor = l.entry } label: { Label(LS("凭证"), systemImage: "doc.text") }.tint(Color.warn)
                        }
                        if !l.income, link != nil { Button { removing = l.entry } label: { Label(LS("移出"), systemImage: "minus.circle") }.tint(Color.warn) }
                    }
            }
        } header: {
            Text(title)
        } footer: {
            Text(LS("左滑一笔可改支出类型、凭证类型") + (link != nil ? LS("，或移出这张单子（回到待报销）") : "") + LS("；点开可编辑交易本身。橙色是还没填或按收付款方推测的。"))
        }
        .sheet(item: $typing) { t in
            AccountPicker(title: LS("支出类型"), prefixes: ["Expenses:"], current: advanceCategoryText(t)) { a in
                Task { await store.setAdvanceMeta(t, key: categoryMeta, value: a) }
            }
        }
        .confirmationDialog(LS("凭证类型"), isPresented: Binding(get: { voucherFor != nil }, set: { if !$0 { voucherFor = nil } }), titleVisibility: .visible, presenting: voucherFor) { t in
            ForEach(voucherKinds, id: \.self) { v in Button { Task { await store.setAdvanceMeta(t, key: voucherMeta, value: v) } } label: { Text(v) } }
            Button(role: .destructive) { Task { await store.setAdvanceMeta(t, key: voucherMeta, value: nil) } } label: { Text(LS("清除")) }
        }
        .confirmationDialog(LS("移出这张单子？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { t in
            Button(role: .destructive) { if let l = link { Task { await store.removeLink(l, from: t) } } } label: { Text(LS("移出")) }
        } message: { t in
            Text(LS("只去掉 %@ %@ 的 ^%@，金额和分录不变，它会回到待报销。", t.date, t.payee, link ?? ""))
        }
    }

    /// the advance is on this ledger's reimbursement account (older ones on a person's account can't carry the fields)
    private func editable(_ t: Entry) -> Bool {
        guard let D = store.D else { return false }
        return t.postings.contains { $0.account == D.receivable && ($0.units ?? 0) > 0 }
    }

    private func advanceCategoryText(_ t: Entry) -> String {
        t.postings.compactMap(advanceCategory).first ?? ""
    }
}

/// 待报销: advances not on any reimbursement or petty cash yet
struct UnclaimedView: View {
    @Environment(Store.self) var store
    @State private var reimb: ReimbTarget?
    @State private var float: FloatTarget?
    @State private var exporting: ReimbExportTarget?

    var body: some View {
        List {
            if let L = store.L, let D = store.D {
                let es = D.unclaimed.map { $0.t }
                let r = reimbReport(es, L, receivable: D.receivable, title: LS("待报销"))
                Section {
                    LabeledContent(LS("合计")) { Amount(n: D.unclaimed.reduce(0.0) { $0 + $1.amount }) }
                    if !D.unclaimed.isEmpty {
                        Button { reimb = ReimbTarget(link: nil) } label: { Label(LS("登记回款…"), systemImage: "arrow.down.left").labelStyle(ControlLabelStyle()) }
                        ForEach(D.floats.filter { $0.left > 0.005 }) { f in
                            Button { float = FloatTarget(link: f.link) } label: { Label(LS("用备用金 %@ 冲抵…", f.date), systemImage: "arrow.left.arrow.right").labelStyle(ControlLabelStyle()) }
                        }
                    }
                } footer: {
                    if abs(D.unclaimedOld) > 0.005 { Text(LS("另有 180 天前的垫付 %@ 未关联报销，在「报销应收」账户明细里查看。", money(D.unclaimedOld))) }
                }
                ReimbLinesSection(title: LS("%@ 笔", r.lines.count), lines: r.lines, link: nil)
            }
        }
        .navigationTitle(LS("待报销"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exporting = ReimbExportTarget(title: LS("待报销 %@", Day.today()), entries: store.D?.unclaimed.map { $0.t } ?? [])
                } label: { Image(systemName: "doc.richtext") }
                .accessibilityLabel(LS("导出报销单"))
            }
        }
        .sheet(item: $reimb) { ReimbSheet(target: $0) }
        .sheet(item: $float) { FloatSheet(link: $0.link) }
        .sheet(item: $exporting) { ReimbExportSheet(target: $0) }
    }
}

/// one reimbursement or petty cash: totals, what to do next, and every transaction on it
struct ReimbBatchView: View {
    @Environment(Store.self) var store
    let link: String
    @State private var reimb: ReimbTarget?
    @State private var float: FloatTarget?
    @State private var adding = false
    @State private var settle: SettleTarget?
    @State private var exporting: ReimbExportTarget?

    var body: some View {
        List {
            if let L = store.L, let D = store.D, let b = reimbBatches(L).first(where: { $0.link == link }) {
                let es = (D.byLink[link] ?? []).filter { !$0.synthetic }
                let r = reimbReport(es, L, receivable: D.receivable, title: "^" + link)
                Section {
                    if !b.payer.isEmpty { LabeledContent(b.kind == .float ? LS("发放") : LS("报销单位"), value: b.payer) }
                    LabeledContent(LS("期间"), value: b.first == b.last ? b.first : b.first + " – " + b.last)
                    let figs = linkFigures(link, es, L)
                    if !figs.isEmpty { LinkFiguresRow(figs: figs) }
                    if b.settled { Label(LS("已结清"), systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain) }
                }
                Section {
                    if b.kind == .float {
                        if !b.settled { Button { float = FloatTarget(link: link) } label: { Label(LS("用它冲抵待报销的垫付…"), systemImage: "arrow.left.arrow.right").labelStyle(ControlLabelStyle()) } }
                        if b.balance < -0.005 {
                            Button {
                                let banks = Array(D.rankAccounts(["Assets:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(4))
                                settle = SettleTarget(title: LS("退回备用金"), payee: b.payer.isEmpty ? LS("公司") : b.payer, link: link,
                                                      items: [SettleItem(account: D.receivable, currency: b.currency, amount: b.balance)], to: banks)
                            } label: { Label(LS("退回剩余 %@…", money(-b.balance, b.currency)), systemImage: "arrow.uturn.backward").labelStyle(ControlLabelStyle()) }
                        }
                    } else {
                        if !b.settled { Button { reimb = ReimbTarget(link: link) } label: { Label(LS("登记回款…"), systemImage: "arrow.down.left").labelStyle(ControlLabelStyle()) } }
                        Button { adding = true } label: { Label(LS("添加待报销的垫付…"), systemImage: "plus.circle").labelStyle(ControlLabelStyle()) }.disabled(D.unclaimed.isEmpty)
                    }
                    Button { exporting = ReimbExportTarget(title: "^" + link, entries: es) } label: { Label(LS("导出报销单…"), systemImage: "square.and.arrow.up").labelStyle(ControlLabelStyle()) }
                }
                ReimbLinesSection(title: LS("明细（%@ 笔）", r.rows.count), lines: r.rows, link: link)
            } else {
                Text(LS("账本里已没有 ^%@", link)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(isFloatLink(link) ? LS("备用金") : LS("报销单"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reimb) { ReimbSheet(target: $0) }
        .sheet(item: $float) { FloatSheet(link: $0.link) }
        .sheet(item: $settle) { SettleSheet(target: $0) }
        .sheet(item: $exporting) { ReimbExportSheet(target: $0) }
        .sheet(isPresented: $adding) { AddAdvancesSheet(link: link) }
    }
}

/// pick advances waiting to be claimed and put them on a reimbursement
struct AddAdvancesSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let link: String
    @State private var picked: Set<ObjectIdentifier> = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                let us = store.D?.unclaimed ?? []
                Section {
                    ForEach(Array(us.enumerated()), id: \.offset) { _, u in
                        let k = ObjectIdentifier(u.t)
                        Button {
                            if picked.contains(k) { picked.remove(k) } else { picked.insert(k) }
                        } label: {
                            HStack(spacing: AppSpacing.icon) {
                                Image(systemName: picked.contains(k) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(picked.contains(k) ? Color.jade : Color.secondary)
                                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                    Text([u.t.payee, u.t.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                                    Text(u.t.date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(money(u.amount, u.currency)).monospacedDigit().sensitive()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked.contains(k) ? .isSelected : [])
                    }
                } footer: {
                    Text(LS("所选交易将添加 #reimbursed ^%@。", link))
                }
            }
            .navigationTitle(LS("添加垫付"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let es = (store.D?.unclaimed ?? []).map { $0.t }.filter { picked.contains(ObjectIdentifier($0)) }
                        saving = true
                        Task {
                            if await store.linkAdvances(es, link: link, label: LS("加入 ^%@：%@ 笔", link, es.count)) { dismiss() }
                            saving = false
                        }
                    } label: { Label(LS("添加 %@ 笔", picked.count), systemImage: "plus").labelStyle(ControlLabelStyle()) }
                    .disabled(picked.isEmpty || saving)
                }
            }
        }
    }
}
