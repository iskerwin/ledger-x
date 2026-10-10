import SwiftUI
import LedgerKit

/// which reimbursement to record: the loose advances (nil) or one ^reimburse-… link
struct ReimbTarget: Identifiable {
    let link: String?
    var id: String { link ?? "__unclaimed" }
}

/// 报销到账: pick the advances that were paid back, record the incoming money,
/// and tag the picked transactions with #reimbursed ^link
struct ReimbSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: ReimbTarget

    @State private var date = Day.today()
    @State private var payee = ""
    @State private var amount = ""
    @State private var account = ""
    @State private var linkText = ""
    @State private var linkTouched = false
    @State private var selected: Set<Int> = []
    @State private var ready = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(LS("报销回款"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    // MARK: data

    private func pool(_ D: Derived) -> [Unclaimed] { target.link == nil ? D.unclaimed : [] }
    private func openLink(_ D: Derived) -> OpenLink? { target.link.flatMap { l in D.openLinks.first { $0.link == l } } }
    private func currency(_ D: Derived) -> String { openLink(D)?.currency ?? "CNY" }

    private func owed(_ D: Derived) -> Double {
        if let x = openLink(D) { return x.amount }
        let p = pool(D)
        return roundTo(selected.reduce(0.0) { $0 + (p.indices.contains($1) ? p[$1].amount : 0) }, 2)
    }
    private func link() -> String {
        if let l = target.link { return l }
        if linkTouched { return linkText.trimmed.replacingOccurrences(of: "^", with: "") }
        // reimburse-<who pays back>-<date>, like every other link
        return newLink("reimburse", payee: payee.trimmed.isEmpty ? "work" : payee.trimmed, date: date, taken: Set(store.D?.allLinks ?? []))
    }
    private func got(_ D: Derived) -> Double? { amount.trimmed.isEmpty ? owed(D) : evalAmount(amount) }
    private func shortfall(_ L: Ledger) -> String { L.accounts["Expenses:Unreimbursed"] != nil ? "Expenses:Unreimbursed" : "Expenses:Miscellaneous" }

    private func past(_ L: Ledger) -> [Entry] { L.txns.filter { $0.tags.contains("reimbursement") } }
    private func payeeChoices(_ L: Ledger) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in past(L).reversed() where !t.payee.isEmpty && seen.insert(t.payee).inserted { out.append(t.payee) }
        return Array(out.prefix(4))
    }
    private func accountChoices(_ L: Ledger, _ D: Derived) -> [String] {
        let boost = past(L).suffix(10).reversed().flatMap { t in t.postings.filter { ($0.units ?? 0) > 0 }.map { $0.account } }
        return Array(D.rankAccounts(["Assets:"], boost: boost).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(6))
    }

    private func text(_ L: Ledger, _ D: Derived) -> String {
        guard let g = got(D), g > 0, owed(D) > 0, !account.isEmpty else { return "" }
        let o = owed(D), c = currency(D)
        let diff = roundTo(g - o, 2)
        var tx = TxDraft(date: date)
        tx.payee = payee.trimmed
        let lk = link()
        let digits = lk.range(of: #"\d{8}$"#, options: .regularExpression).map { String(lk[$0]) } ?? date.replacingOccurrences(of: "-", with: "")
        tx.narration = LS("报销入账-") + digits
        tx.tags = ["reimbursement"]
        tx.links = [lk]
        tx.postings = [TxPosting(account: D.receivable, amount: -o, currency: c)]
        if diff > 0.004 { tx.postings.append(TxPosting(account: "Income:ReimbExcess", amount: -diff, currency: c)) }
        if diff < -0.004 { tx.postings.append(TxPosting(account: shortfall(L), amount: -diff, currency: c)) }
        tx.postings.append(TxPosting(account: account, amount: g, currency: c))
        return formatTxn(tx)
    }

    // MARK: form

    private func form(_ L: Ledger, _ D: Derived) -> some View {
        let p = pool(D)
        let c = currency(D)
        let o = owed(D)
        let t = text(L, D)
        return Form {
            if target.link == nil {
                pickSection(p, o)
            } else if let x = openLink(D) {
                linkSection(x, D)
            }
            Section(LS("回款信息")) {
                DatePicker(LS("回款日期"), selection: Binding(get: { Day.date(date) ?? Date() }, set: { date = Day.string($0) }), displayedComponents: .date)
                if target.link == nil {
                    LabeledContent(LS("关联")) {
                        TextField("reimburse-…", text: Binding(get: { link() }, set: { linkText = $0; linkTouched = true }))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField(LS("付款方（如公司名称）"), text: $payee)
                    let ps = payeeChoices(L)
                    if !ps.isEmpty {
                        ChipRow { ForEach(ps, id: \.self) { x in Chip(label: x, selected: payee == x) { payee = x } } }
                    }
                }
                LabeledContent(LS("回款金额 ") + c) {
                    TextField(fmtNum(o), text: $amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                AccountField(label: LS("收款账户"), prefixes: ["Assets:"], chips: accountChoices(L, D), value: $account)
            }
            Section(LS("将写入")) {
                if let g = got(D), g > 0, abs(g - o) > 0.004 {
                    let diff = g - o
                    Text(diff > 0 ? LS("超额 %@，计入 Income:ReimbExcess", money(diff, c)) : LS("短收 %@，计入 %@", money(-diff, c), shortfall(L)))
                        .font(.footnote)
                        .foregroundStyle(diff < 0 ? Color.loss : Color.secondary)
                }
                if t.isEmpty {
                    Text(o > 0 ? LS("选择收款账户后生成") : LS("请先选择报销明细")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    MonoText(text: t)
                }
                if target.link == nil && !selected.isEmpty {
                    Text(LS("所选 %@ 笔将添加 #reimbursed ^%@", selected.count, link())).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    Task { await save(L, D, t) }
                } label: {
                    HStack { Spacer(); if saving { ProgressView() } else { Text(LS("登记回款")).fontWeight(.semibold) }; Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.jade)
                .controlSize(.large)
                .disabled(t.isEmpty || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            selected = Set(p.indices)
            payee = payeeChoices(L).first ?? ""
            account = accountChoices(L, D).first ?? ""
        }
    }

    private func pickSection(_ p: [Unclaimed], _ o: Double) -> some View {
        Section {
            ForEach(Array(p.enumerated()), id: \.offset) { pair in
                let i = pair.offset
                let it = pair.element
                Button {
                    if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(i) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(i) ? Color.jade : Color.secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text([it.t.payee, it.t.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                            Text(it.t.date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(it.amount, it.currency)).monospacedDigit().sensitive()
                    }
                }
                .buttonStyle(.plain)
            }
            if p.isEmpty { Text(LS("近 180 天无待报销垫款")).foregroundStyle(.secondary) }
        } header: {
            HStack {
                Text(LS("已选 %@/%@ 笔，合计 ", selected.count, p.count) + money(o)).textCase(nil)
                Spacer()
                Button(selected.count == p.count ? LS("全不选") : LS("全选")) {
                    selected = selected.count == p.count ? [] : Set(p.indices)
                }
                .font(.footnote)
                .textCase(nil)
            }
        }
    }

    private func linkSection(_ x: OpenLink, _ D: Derived) -> some View {
        let items = D.byLink[x.link] ?? []
        return Section {
            LabeledContent("^" + x.link) { Text(LS("应收 ") + money(x.amount, x.currency)).monospacedDigit().sensitive() }
            DisclosureGroup(LS("包含 %@ 笔交易", items.count)) {
                ForEach(items, id: \.id) { t in TxRow(t: t, showDate: true) }
            }
        }
    }

    // MARK: save

    private func save(_ L: Ledger, _ D: Derived, _ t: String) async {
        guard !t.isEmpty else { return }
        saving = true
        defer { saving = false }
        let lk = link()
        var ops: [Op] = []
        if target.link == nil {
            let p = pool(D)
            var done = Set<ObjectIdentifier>()
            for i in selected.sorted() where p.indices.contains(i) {
                let e = p[i].t
                guard done.insert(ObjectIdentifier(e)).inserted else { continue }
                guard let file = try? await store.fileText(e.file) else { store.show(LS("无法读取 %@", e.file)); return }
                let lines = file.components(separatedBy: "\n")
                guard e.startLine < lines.count else { continue }
                var op = Op(kind: .link, path: e.file)
                op.headerLine = e.startLine + 1
                op.header = lines[e.startLine]
                op.add = (e.tags.contains("reimbursed") ? "" : " #reimbursed") + " ^" + lk
                op.link = lk
                op.silent = true
                ops.append(op)
            }
        }
        let n = ops.count
        guard let ins = store.makeOps(t, extra: OpExtra(label: LS("报销回款：^%@%@", lk, n > 0 ? LS(" %@ 笔", n) : "")), single: true),
              let checked = await store.review(ops + ins) else { return }
        dismiss()
        await store.commit(checked, word: LS("已入账"), checked: true)
    }
}
