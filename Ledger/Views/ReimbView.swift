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
    @Environment(Store.self) var store
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
    /// a shortfall that will still be paid: leave it on the link instead of settling it
    @State private var keepOpen = false
    @State private var batchCurrency = ""
    @State private var exporting: ReimbExportTarget?

    @State private var closeRequested = false
    @State private var baseline: [String]?
    private var state: [String] { [date, payee, amount, account, linkText, String(linkTouched), String(keepOpen), batchCurrency, selected.sorted().map(String.init).joined(separator: ",")] }

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { PageLoading() }
            }
            .keyboardDone()
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != state } ?? false, busy: saving,
                requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .navigationTitle(LS("报销回款"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }.disabled(saving) }
                ToolbarItem(placement: .primaryAction) {
                    Button { exporting = exportTarget() } label: { Image(systemName: "doc.richtext") }
                        .accessibilityLabel(LS("导出报销单"))
                }
            }
            .sheet(item: $exporting) { ReimbExportSheet(target: $0) }
        }
    }

    // MARK: data

    /// the batch, or the advances picked so far
    private func exportTarget() -> ReimbExportTarget? {
        guard let D = store.D else { return nil }
        if let l = target.link { return ReimbExportTarget(title: "^" + l, entries: D.byLink[l] ?? []) }
        let p = pool(D)
        let picked = selected.sorted().compactMap { p.indices.contains($0) ? p[$0].t : nil }
        return ReimbExportTarget(title: LS("待报销 %@", Day.today()), entries: picked)
    }

    private func batchCurrencies(_ D: Derived) -> [String] { Array(Set(D.unclaimed.map(\.currency))).sorted() }
    private func activeCurrency(_ D: Derived) -> String {
        if !batchCurrency.isEmpty { return batchCurrency }
        let values = batchCurrencies(D)
        return values.contains(store.L?.base ?? "CNY") ? (store.L?.base ?? "CNY") : values.first ?? store.L?.base ?? "CNY"
    }
    private func pool(_ D: Derived) -> [Unclaimed] { target.link == nil ? D.unclaimed.filter { $0.currency == activeCurrency(D) } : [] }
    private func openLink(_ D: Derived) -> OpenLink? { target.link.flatMap { l in D.openLinks.first { $0.link == l } } }
    private func currency(_ D: Derived) -> String { openLink(D)?.currency ?? activeCurrency(D) }

    private func owed(_ D: Derived) -> Double {
        if let x = openLink(D) { return x.amount }
        let p = pool(D)
        let picked = selected.sorted().compactMap { p.indices.contains($0) ? p[$0] : nil }
        return reimbursementTotal(picked, currency: currency(D)) ?? 0
    }
    private func link() -> String {
        if let l = target.link { return l }
        if linkTouched { return linkText.trimmed.replacingOccurrences(of: "^", with: "") }
        // reimburse-<who pays back>-<date>, like every other link
        return newLink("reimburse", payee: payee.trimmed.isEmpty ? "work" : payee.trimmed, date: date, taken: Set(store.D?.allLinks ?? []))
    }
    private func got(_ D: Derived) -> Double? { amount.trimmed.isEmpty ? owed(D) : evalAmount(amount) }
    /// the difference between what came back and what was advanced, either way (报销差额)
    private func shortfall(_ L: Ledger) -> String { "Income:ReimbExcess" }

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
        let pending = diff < -0.004 && keepOpen
        tx.postings = [TxPosting(account: D.receivable, amount: -(pending ? g : o), currency: c)]
        if diff > 0.004 { tx.postings.append(TxPosting(account: "Income:ReimbExcess", amount: -diff, currency: c)) }
        if diff < -0.004 && !keepOpen { tx.postings.append(TxPosting(account: shortfall(L), amount: -diff, currency: c)) }
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
                if batchCurrencies(D).count > 1 {
                    Section {
                        Picker(LS("回款币种"), selection: Binding(get: { activeCurrency(D) }, set: {
                            batchCurrency = $0; selected = []; amount = ""
                        })) { ForEach(batchCurrencies(D), id: \.self) { Text($0).tag($0) } }
                        .accessibilityIdentifier("reimbursement.currency")
                    } footer: { Text(LS("每批只处理一种币种；切换币种会清空本批选择和回款金额，其他币种的垫款仍保留。")) }
                }
                pickSection(p, o)
            } else if let x = openLink(D) {
                linkSection(x, D)
            }
            Section(LS("回款信息")) {
                DateField(value: $date, title: LS("回款日期"))
                if target.link == nil {
                    LabeledContent(LS("关联")) {
                        TextField("reimburse-…", text: Binding(get: { link() }, set: { linkText = $0; linkTouched = true }))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                VStack(alignment: .leading, spacing: AppSpacing.icon) {
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
                    if diff < 0 {
                        Toggle(LS("差额以后还会补（挂账）"), isOn: $keepOpen).tint(.jade)
                    }
                    Text(diff > 0 ? LS("超额 %@，计入 Income:ReimbExcess", money(diff, c))
                         : keepOpen ? LS("短收 %@，留在 ^%@ 上待收，补发后再登记回款", money(-diff, c), link())
                         : LS("短收 %@，计入 %@", money(-diff, c), shortfall(L)))
                        .font(.footnote)
                        .foregroundStyle(diff < 0 && !keepOpen ? Color.loss : Color.secondary)
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
                    HStack(spacing: AppSpacing.control) { Spacer(); BusyLabel(busy: saving, title: LS("登记回款"), systemImage: "arrow.down.left").fontWeight(.semibold); Spacer() }
                }
                .primaryButton()
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
            baseline = state
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
                    HStack(spacing: AppSpacing.icon) {
                        Image(systemName: selected.contains(i) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(i) ? Color.jadeInk : Color.secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text([it.t.payee, it.t.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                            Text(it.t.date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(it.amount, it.currency)).monospacedDigit().sensitive()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(i) ? .isSelected : [])
                .accessibilityIdentifier("reimbursement.row." + it.currency)
            }
            if p.isEmpty { Text(LS("近 180 天无待报销垫款")).foregroundStyle(.secondary) }
        } header: {
            HStack(spacing: AppSpacing.control) {
                Text(LS("已选 %@/%@ 笔，合计 ", selected.count, p.count) + money(o)).textCase(nil)
                Spacer()
                Button {
                    selected = selected.count == p.count ? [] : Set(p.indices)
                } label: { Label(selected.count == p.count ? LS("全不选") : LS("全选"), systemImage: selected.count == p.count ? "circle" : "checkmark.circle").labelStyle(ControlLabelStyle()) }
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
        guard !saving, !t.isEmpty else { return }
        saving = true
        defer { saving = false }
        let ledgerID = store.cfg.id
        let lk = link()
        var ops: [Op] = []
        if target.link == nil {
            let p = pool(D)
            var done = Set<ObjectIdentifier>()
            for i in selected.sorted() where p.indices.contains(i) {
                let e = p[i].t
                guard done.insert(ObjectIdentifier(e)).inserted else { continue }
                guard let file = try? await store.fileText(e.file) else { store.showFailure(LS("无法读取 %@", e.file)); return }
                guard store.cfg.id == ledgerID, let current = EntryLocator(e).resolve(in: parseFile(file, file: e.file).entries) else {
                    store.showFailure(LS("记录或账本已变化，请重新打开后再试")); return
                }
                let lines = file.components(separatedBy: "\n")
                guard current.startLine < lines.count else { return }
                var op = Op(kind: .link, path: e.file)
                op.headerLine = current.startLine + 1
                op.header = lines[current.startLine]
                op.add = (e.tags.contains("reimbursed") ? "" : " #reimbursed") + " ^" + lk
                op.link = lk
                op.silent = true
                ops.append(op)
            }
        }
        let n = ops.count
        guard store.cfg.id == ledgerID,
              let ins = store.makeOps(t, extra: OpExtra(label: LS("报销回款：^%@%@", lk, n > 0 ? LS(" %@ 笔", n) : "")), single: true) else { return }
        if await store.commit(ops + ins, word: LS("已入账")) { dismiss() }
    }
}

/// 备用金冲抵: the advances petty cash paid for get its ^float-… link (and #reimbursed); no money moves, so
/// nothing new is written — the link's transactions add up to what is still in hand
struct FloatSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let link: String
    @State private var selected: Set<Int> = []
    @State private var saving = false
    /// a linked transaction to take off this petty cash (back to 待报销)
    @State private var unlinking: Entry?
    @State private var exporting: ReimbExportTarget?

    @State private var closeRequested = false
    @State private var baseline: [String]?
    private var state: [String] { [selected.sorted().map(String.init).joined(separator: ",")] }

    var body: some View {
        NavigationStack {
            Group {
                if let D = store.D, let f = D.floats.first(where: { $0.link == link }) { form(D, f) }
                else { Text(LS("这笔备用金已结清")).foregroundStyle(.secondary) }
            }
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != state } ?? false, busy: saving,
                requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .onAppear { if baseline == nil { baseline = state } }
            .navigationTitle(LS("备用金冲抵"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { exporting = ReimbExportTarget(title: "^" + link, entries: store.D?.byLink[link] ?? []) } label: { Image(systemName: "doc.richtext") }
                        .accessibilityLabel(LS("导出报销单"))
                }
            }
            .sheet(item: $exporting) { ReimbExportSheet(target: $0) }
            .confirmationDialog(LS("取消这笔的备用金冲抵？"), isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
                                titleVisibility: .visible, presenting: unlinking) { t in
                Button(role: .destructive) {
                    guard !saving else { return }
                    let ledgerID = store.cfg.id
                    selected = []; saving = true
                    Task {
                        defer { saving = false }
                        guard store.cfg.id == ledgerID else { return }
                        await store.removeLink(link, from: t)
                    }
                } label: { Text(LS("取消冲抵")) }
            } message: { t in
                Text([t.date, t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " "))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }.disabled(saving) } }
        }
    }

    /// advances in the float's currency; ones from before it was handed over count too (it can pay them back)
    private func pool(_ D: Derived, _ f: OpenFloat) -> [Unclaimed] {
        D.unclaimed.filter { $0.currency == f.currency && $0.amount > 0 }
    }

    private struct Linked: Identifiable {
        let t: Entry
        /// on the reimbursement account: negative is the petty cash handed over
        let amount: Double
        var id: ObjectIdentifier { ObjectIdentifier(t) }
    }

    /// what is on this petty cash so far, newest first
    private func linked(_ D: Derived) -> [Linked] {
        (D.byLink[link] ?? []).reversed().map { t in
            Linked(t: t, amount: roundTo(t.postings.filter { $0.account == D.receivable }.reduce(0.0) { $0 + ($1.units ?? 0) }, 2))
        }
    }

    private func form(_ D: Derived, _ f: OpenFloat) -> some View {
        let p = pool(D, f)
        let done = linked(D)
        let picked = roundTo(selected.reduce(0.0) { $0 + (p.indices.contains($1) ? p[$1].amount : 0) }, 2)
        return Form {
            Section {
                LabeledContent(LS("领取")) { Amount(n: f.received, c: f.currency) }
                LabeledContent(LS("已冲抵或退回")) { Amount(n: f.used, c: f.currency) }
                LabeledContent(LS("冲抵后剩余")) {
                    Text(money(f.left - picked, f.currency)).monospacedDigit()
                        .foregroundStyle(f.left - picked < -0.004 ? Color.warn : Color.primary).sensitive()
                }
            } header: {
                Text("^" + link).textCase(nil)
            } footer: {
                if f.left - picked < -0.004 { Text(LS("超出的部分是公司欠你的，之后报销回款时再登记。")) }
            }
            Section {
                ForEach(done) { x in
                    HStack(spacing: AppSpacing.control) {
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text([x.t.payee, x.t.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                            Text(x.t.date + (x.amount < 0 ? " · " + LS("领取") : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(x.amount, f.currency)).monospacedDigit().sensitive()
                    }
                    .rowActions {
                        if x.amount > 0 {
                            Button { unlinking = x.t } label: { Label(LS("取消冲抵"), systemImage: "arrow.uturn.backward") }.tint(Color.warn)
                        }
                    }
                }
            } header: {
                Text(LS("已关联（%@ 笔）", done.count)).textCase(nil)
            } footer: {
                Text(LS("左滑可取消冲抵：只去掉这笔的 ^%@，它会回到待报销。", link))
            }
            Section {
                ForEach(Array(p.enumerated()), id: \.offset) { pair in
                    let i = pair.offset, it = pair.element
                    Button {
                        if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
                    } label: {
                        HStack(spacing: AppSpacing.icon) {
                            Image(systemName: selected.contains(i) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(i) ? Color.jadeInk : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text([it.t.payee, it.t.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                                Text(it.t.date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(it.amount, it.currency)).monospacedDigit().sensitive()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(i) ? .isSelected : [])
                }
                if p.isEmpty { Text(LS("没有待报销的垫付")).foregroundStyle(.secondary) }
            } header: {
                Text(LS("用备用金支付的垫付（已选 %@ 笔）", selected.count)).textCase(nil)
            } footer: {
                Text(LS("所选交易将添加 #reimbursed ^%@，不另记新交易。", link))
            }
            Section {
                Button {
                    Task { await save(p) }
                } label: {
                    HStack(spacing: AppSpacing.control) { Spacer(); BusyLabel(busy: saving, title: LS("冲抵"), systemImage: "arrow.left.arrow.right").fontWeight(.semibold); Spacer() }
                }
                .primaryButton()
                .disabled(selected.isEmpty || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func save(_ p: [Unclaimed]) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let es = selected.sorted().compactMap { p.indices.contains($0) ? p[$0].t : nil }
        if await store.linkAdvances(es, link: link, label: LS("备用金冲抵：^%@ %@ 笔", link, es.count)) { dismiss() }
    }
}
