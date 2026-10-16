import SwiftUI
import LedgerKit

enum AddField: Hashable { case amount, toAmount, paid, rate, payee, narration, link, tags, row(UUID) }

/// 完整表单: every kind of entry (分录, 文本, 退款, AA, 事件, 源文本), opened from the 记一笔 card
struct AddForm: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    /// after a save: the card closes
    var onSaved: () -> Void = {}
    @FocusState private var focus: AddField?
    @State private var confirmOverwrite: [Entry] = []
    @State private var showOverwrite = false
    @State private var managingTemplates = false
    @State private var editingText = false
    /// 组合付款与优惠
    @State private var splittingPay = false

    /// a save in progress (the pre-commit check takes a moment): ignore further taps
    @State private var saving = false
    /// AA: a name typed for someone not in the ledger yet
    @State private var addingPerson = false
    @State private var newPerson = ""

    var body: some View {
        Group {
            if let L = store.L, let D = store.D { content(L, D) } else { ProgressView() }
        }
        .navigationTitle(store.draft.replacing != nil ? LS("编辑交易") : LS("完整表单"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.demoEnv["LEDGER_EDIT_TEXT"] != nil { try? await Task.sleep(nanoseconds: 800_000_000); editingText = true } }
    }

    // MARK: bindings

    private func field(_ kp: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { store.draft[keyPath: kp] }, set: { store.draft[keyPath: kp] = $0; store.draft.edited = nil })
    }
    private var rowsBinding: Binding<[DraftRow]> {
        Binding(get: { store.draft.rows }, set: { store.draft.rows = $0; store.draft.edited = nil })
    }

    @ViewBuilder
    private func content(_ L: Ledger, _ D: Derived) -> some View {
        let d = store.draft
        let text = draftText(d, L, D, explicit: store.explicitAmounts)
        let v: Validation? = text.trimmed.isEmpty ? nil : validateText(text, L, single: draftIsSingle(d, L))
        Form {
            if let s = store.scanInfo {
                Section { ScanBanner(info: s).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            }
            if d.kind == .refund {
                refundBanner(d)
            } else {
                Section {
                    Picker(LS("类型"), selection: Binding(get: { store.draft.kind }, set: { store.setKind($0) })) {
                        ForEach(DraftKind.allCases.filter { $0 != .refund }) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if (d.kind == .expense || d.kind == .income) && store.scanInfo == nil && d.replacing == nil { templateSection(d.kind, L, D) }
            switch d.kind {
            case .multi: multiSection(L, D)
            case .raw: EmptyView()
            default: simpleSection(d, L, D)
            }
            if d.kind != .transfer && d.kind != .raw { eventSection(d, L) }
            previewSection(text, v, L)
            Section {
                Button {
                    guard !saving else { return }
                    saving = true
                    Task { await save(L, D); saving = false }
                } label: {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Image(systemName: "square.and.pencil")
                        Text(store.draft.replacing != nil ? LS("保存修改") : LS("记一笔"))
                        Spacer(minLength: 0)
                    }
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.jade)
                .controlSize(.large)
                .disabled(!(v?.ok ?? false) || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            recentSection(L, D)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { keyboardBar }
        }
        // new entries follow the events of their day until picked by hand
        .onChange(of: d.date) { _, day in
            if !store.draft.eventsTouched { store.draft.events = store.autoEvents(on: day); store.draft.edited = nil }
        }
        .onAppear {
            if !store.draft.eventsTouched && store.draft.events.isEmpty && store.draft.edited == nil {
                let auto = store.autoEvents(on: store.draft.date)
                if !auto.isEmpty { store.draft.events = auto }
            }
        }
        .confirmationDialog(LS("同一天已有余额断言"), isPresented: $showOverwrite, titleVisibility: .visible) {
            Button(LS("覆盖 %@ 条断言", confirmOverwrite.count), role: .destructive) { Task { await saveRaw(L, overwriteOK: true) } }
            Button(LS("取消"), role: .cancel) {}
        } message: {
            Text(confirmOverwrite.map { "\($0.date) \($0.account ?? "")" }.joined(separator: "\n"))
        }
        .sheet(isPresented: $managingTemplates) { TemplateManager() }
        .sheet(isPresented: $splittingPay) { PaySplitSheet() }
        .sheet(isPresented: $editingText) {
            TextEditSheet(title: LS("编辑源文本"), initial: text, validate: { t in validateText(t, L, single: draftIsSingle(store.draft, L)) }) { new in
                store.draft.edited = new
            }
        }
    }

    // MARK: keyboard

    @ViewBuilder private var keyboardBar: some View {
        switch focus {
        case .amount?, .toAmount?, .paid?:
            ForEach(["+", "−", "×", "÷"], id: \.self) { op in
                Button(op) { appendToFocused(op == "−" ? "-" : op) }.font(.title3)
            }
            Spacer()
            Button(LS("完成")) { focus = nil; hideKeyboard() }.fontWeight(.semibold)
        case .row(let id)?:
            Button("±") { toggleSign(row: id) }.font(.title3)
            Button("+") { appendRow(id, "+") }.font(.title3)
            Spacer()
            Button(LS("完成")) { focus = nil; hideKeyboard() }.fontWeight(.semibold)
        default:
            Spacer()
            Button(LS("完成")) { focus = nil; hideKeyboard() }.fontWeight(.semibold)
        }
    }

    private func appendToFocused(_ s: String) {
        switch focus {
        case .amount?: store.draft.amount += s
        case .toAmount?: store.draft.toAmount += s
        case .paid?: store.draft.paid += s
        default: break
        }
        store.draft.edited = nil
    }
    private func toggleSign(row id: UUID) {
        guard let i = store.draft.rows.firstIndex(where: { $0.id == id }) else { return }
        let a = store.draft.rows[i].amount.trimmed
        store.draft.rows[i].amount = a.hasPrefix("-") ? String(a.dropFirst()) : "-" + a
        store.draft.edited = nil
    }
    private func appendRow(_ id: UUID, _ s: String) {
        guard let i = store.draft.rows.firstIndex(where: { $0.id == id }) else { return }
        store.draft.rows[i].amount += s
        store.draft.edited = nil
    }

    /// refunds start from the original transaction (流水 → 记退款), so they get a banner, not a tab
    private func refundBanner(_ d: Draft) -> some View {
        Section {
            HStack(alignment: .top) {
                Image(systemName: "arrow.uturn.backward.circle.fill").font(.title2).foregroundStyle(Color.jade)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LS("登记退款")).font(.headline)
                    Text([d.payee, d.narration].filter { !$0.isEmpty }.joined(separator: " ") + (d.link.isEmpty ? "" : " · ^" + d.link))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(LS("取消")) { store.draft = store.newDraftFor(.expense) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } footer: {
            Text(LS("退款将冲减原支出科目，并通过同一 ^link 与原交易关联。"))
        }
    }

    // MARK: kind & payee

    // MARK: 常用

    @ViewBuilder
    private func templateSection(_ kind: DraftKind, _ L: Ledger, _ D: Derived) -> some View {
        let list = Array(store.templateList.filter { $0.kind == (kind == .income ? .income : .expense) }.prefix(8))
        if !list.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(list) { x in TemplateChip(x: x, saving: $saving) { x in if x.fixed == nil { focus = .amount } } }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            } header: {
                HStack {
                    Text(LS("常用交易"))
                    Spacer()
                    Button(LS("管理")) { managingTemplates = true }.font(.footnote).textCase(nil)
                }
            }
        }
    }

    // MARK: simple form

    struct FormContext {
        var payeeStat: PayeeStat?
        var catPrefix: [String]
        var cats: [String]
        var funds: [String]
        var fc: String?
        var tc: String?
    }

    private func formContext(_ d: Draft, _ L: Ledger, _ D: Derived) -> FormContext {
        let stat = D.payee(d.payee)
        var boost: [String] = []
        if stat != nil {
            var seen = Set<String>()
            for t in L.txns.filter({ $0.payee == d.payee }).suffix(30).reversed() {
                for p in t.postings where seen.insert(p.account).inserted { boost.append(p.account) }
            }
        }
        let catPrefix = d.kind == .income ? ["Income:"] : ["Expenses:"]
        let cats = Array(D.rankAccounts(catPrefix, boost: boost).prefix(8))
        let funds = Array(D.rankAccounts(["Assets:", "Liabilities:"], boost: boost).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(6))
        return FormContext(payeeStat: stat, catPrefix: catPrefix, cats: cats, funds: funds, fc: accountCurrency(d.funding, L, D), tc: accountCurrency(d.to, L, D))
    }

    @ViewBuilder
    private func simpleSection(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let ctx = formContext(d, L, D)
        amountSection(d, D)
        if d.kind == .transfer {
            transferSection(d, D, ctx)
        } else {
            payeeSection(d, D, ctx)
            accountSection(d, ctx)
            if d.kind == .expense && store.ownedSubLinks.contains(d.link.trimmed) { topupSection(d) }
            if d.kind == .expense { reimbSection(d, D) }
            if d.kind == .expense && !d.reimb { aaSection(d, L) }
            if d.kind == .refund {
                Section(LS("关联")) {
                    TextField(LS("^refund-… 可留空"), text: field(\.link)).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
        }
    }

    /// a subscription's charge paid on top of this period's (written as `topup: TRUE`)
    private func topupSection(_ d: Draft) -> some View {
        let name = store.subs.first { $0.link == d.link.trimmed }?.name ?? d.link
        return Section {
            Toggle(LS("本期补差"), isOn: Binding(get: { store.draft.topup }, set: { store.draft.topup = $0; store.draft.edited = nil }))
        } footer: {
            Text(d.topup ? LS("补交「%@」这一期的差价：计入累计已付，不算新的一期，不改变下次扣费日。", name)
                 : LS("这是「%@」的一期扣费。补交上一期差价时打开「本期补差」。", name))
        }
    }

    private func amountSection(_ d: Draft, _ D: Derived) -> some View {
        Section {
            HStack(spacing: 10) {
                Menu {
                    Picker(LS("币种"), selection: field(\.currency)) {
                        ForEach(D.currencies, id: \.self) { c in Text(c).tag(c) }
                    }
                } label: {
                    Text(d.currency)
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                TextField("0.00", text: field(\.amount))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .amount)
                    .multilineTextAlignment(.trailing)
            }
            if isExpression(d.amount) {
                HStack {
                    Spacer()
                    Text("= " + (evalAmount(d.amount).map { fmtNum($0) } ?? "?")).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            DateField(value: field(\.date))
        }
    }

    private func transferSection(_ d: Draft, _ D: Derived, _ ctx: FormContext) -> some View {
        let fromBinding = Binding<String>(get: { store.draft.funding }, set: { a in
            store.draft.funding = a
            store.draft.currency = D.acctCcy[a] ?? store.draft.currency
            store.draft.edited = nil
        })
        let toChips = Array(D.rankAccounts(["Assets:", "Liabilities:"]).filter { $0 != d.funding }.prefix(6))
        return Section {
            AccountField(label: LS("转出"), prefixes: ["Assets:", "Liabilities:"], chips: ctx.funds, value: fromBinding)
            AccountField(label: LS("转入"), prefixes: ["Assets:", "Liabilities:"], chips: toChips, value: field(\.to))
            if !d.to.isEmpty, let tc = ctx.tc, tc != d.currency {
                LabeledContent(LS("入账金额 ") + tc) {
                    TextField(LS("实际入账金额"), text: field(\.toAmount))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .toAmount)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func payeeSection(_ d: Draft, _ D: Derived, _ ctx: FormContext) -> some View {
        let narrs = Array((ctx.payeeStat?.narrations ?? []).prefix(6))
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                TextField(LS("收付款方（如 便利店、淘宝）"), text: field(\.payee))
                    .focused($focus, equals: .payee)
                    .submitLabel(.next)
                    .onSubmit {
                        store.applyPayee(store.draft.payee.trimmed)
                        focus = .narration
                    }
                if focus == .payee { payeeSuggestions(d.payee, D) }
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(narrs.first ?? LS("摘要"), text: field(\.narration))
                    .focused($focus, equals: .narration)
                if !narrs.isEmpty {
                    ChipRow {
                        ForEach(narrs, id: \.self) { n in
                            Chip(label: n, selected: d.narration == n) {
                                store.draft.narration = n
                                store.draft.edited = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func accountSection(_ d: Draft, _ ctx: FormContext) -> some View {
        let catLabel = d.kind == .income ? LS("收入科目") : LS("支出科目")
        let fundLabel = d.kind == .income ? LS("收款账户") : d.kind == .refund ? LS("退回账户") : LS("付款账户")
        return Section {
            AccountField(label: catLabel, prefixes: ctx.catPrefix, chips: ctx.cats, value: field(\.account))
            AccountField(label: fundLabel, prefixes: ["Assets:", "Liabilities:"], chips: ctx.funds, value: field(\.funding))
            if isPersonal(d.account) || isPersonal(d.funding) {
                PersonField(value: field(\.person))
            }
            if d.kind == .expense, let L = store.L, let D = store.D {
                Button { splittingPay = true } label: {
                    LabeledContent(LS("组合付款与优惠")) {
                        Text(comboIssue(d, L, D) ?? comboSummary(d, L) ?? LS("未使用"))
                            .foregroundStyle(comboIssue(d, L, D) != nil ? Color.orange : Color.secondary).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
            if let fc = ctx.fc, fc != d.currency, !hasCombo(d) {
                // as the receipt has it: the amount charged, or the rate ("1CNY=1.17912HKD")
                Picker(LS("换算"), selection: Binding(get: { store.draft.byRate }, set: { store.draft.byRate = $0; store.draft.edited = nil })) {
                    Text(LS("填实付金额")).tag(false)
                    Text(LS("填汇率")).tag(true)
                }
                .pickerStyle(.segmented)
                if d.byRate {
                    LabeledContent("1 \(d.currency) =") {
                        HStack(spacing: 6) {
                            TextField("1.17912", text: field(\.rate))
                                .keyboardType(.decimalPad)
                                .focused($focus, equals: .rate)
                                .multilineTextAlignment(.trailing)
                            Text(fc).foregroundStyle(.secondary)
                        }
                    }
                    if let r = Double(d.rate.trimmed), let a = evalAmount(d.amount) {
                        LabeledContent(LS("实付 ") + fc, value: money(roundTo(a * r, 2), fc))
                    }
                } else {
                    LabeledContent(LS("实付 ") + fc) {
                        TextField(LS("账户实际扣款"), text: field(\.paid))
                            .keyboardType(.decimalPad)
                            .focused($focus, equals: .paid)
                            .multilineTextAlignment(.trailing)
                    }
                    if let p = evalAmount(d.paid), let a = evalAmount(d.amount), a > 0 {
                        LabeledContent(LS("汇率"), value: "1 \(d.currency) = \(toFixed(p / a, 5)) \(fc)")
                    }
                }
            }
        }
    }

    /// 可报销: the advance goes to the reimbursement account. With petty cash still in hand it is paid from that
    /// (^float-…, chosen by default); 自己垫付 leaves it for a reimbursement later (no link, or an open ^reimburse-…)
    private func reimbSection(_ d: Draft, _ D: Derived) -> some View {
        let links = Array(D.openLinks.filter { $0.link.hasPrefix("reimburse") }.suffix(4))
        let floats = D.floats.filter { $0.left > 0.005 }
        let hint = LS("关联 ^link，如 reimburse-商户拼音-") + Day.today().replacingOccurrences(of: "-", with: "")
        let reimb = Binding<Bool>(get: { store.draft.reimb }, set: { on in
            store.draft.reimb = on
            // the newest petty cash with money left pays it, unless a link was already given
            if on && store.draft.link.trimmed.isEmpty, let f = floats.last { store.draft.link = f.link }
            if !on && isFloatLink(store.draft.link.trimmed) { store.draft.link = "" }
            store.draft.edited = nil
        })
        let onFloat = isFloatLink(d.link.trimmed)
        func pick(_ l: String) { store.draft.link = l; store.draft.edited = nil }
        return Section {
            Toggle(LS("可报销（计入应收款并标记 #reimbursed）"), isOn: reimb).tint(.jade)
            if d.reimb {
                ChipRow {
                    ForEach(floats) { f in
                        Chip(label: LS("备用金 %@（剩 %@）", f.date, money(f.left, f.currency)), selected: d.link == f.link) { pick(f.link) }
                    }
                    if !floats.isEmpty {
                        Chip(label: LS("自己垫付"), selected: !onFloat) { if onFloat { pick("") } }
                    }
                }
                Picker(LS("凭证类型"), selection: field(\.voucher)) {
                    Text(LS("不填")).tag("")
                    ForEach(voucherKinds, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                if !onFloat {
                    TextField(hint, text: field(\.link))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !links.isEmpty {
                        ChipRow {
                            ForEach(links, id: \.link) { x in
                                Chip(label: x.link, selected: d.link == x.link) { pick(x.link) }
                            }
                        }
                    }
                }
            }
        } footer: {
            if d.reimb {
                Text(onFloat ? LS("用备用金支付：记入报销应收并关联 ^%@，直接冲抵备用金，不进待报销。自己垫付的请选「自己垫付」。上面选的支出科目记为报销单的支出类型。", d.link.trimmed)
                     : LS("自己垫付：进入待报销，公司回款时在「往来」登记；以后改用备用金冲抵，也可在往来里点按备用金勾选。上面选的支出科目记为报销单的支出类型。"))
            }
        }
    }

    // MARK: events

    /// the events of the entry's day (and any already picked): tap to add or remove the tag
    @ViewBuilder
    private func eventSection(_ d: Draft, _ L: Ledger) -> some View {
        let evs = ledgerEvents(L, today: d.date).filter { ($0.entry != nil && $0.covers(d.date)) || d.events.contains($0.tag) }
        if !evs.isEmpty {
            Section {
                ChipRow {
                    ForEach(evs) { e in
                        Chip(label: e.title, selected: d.events.contains(e.tag)) {
                            var x = store.draft
                            if let i = x.events.firstIndex(of: e.tag) { x.events.remove(at: i) } else { x.events.append(e.tag) }
                            x.eventsTouched = true
                            x.edited = nil
                            store.draft = x
                        }
                    }
                }
            } header: {
                Text(LS("事件"))
            } footer: {
                Text(LS("选中的事件以 #标签 记在这笔交易上，事件页按标签汇总花费。"))
            }
        }
    }

    // MARK: AA

    /// split the expense with people: their parts go to the personal receivable (person: on each), yours to the category
    private func aaSection(_ d: Draft, _ L: Ledger) -> some View {
        let ps = people(L).filter { !$0.closed && !$0.unnamed }
        let on = Binding<Bool>(get: { store.draft.split }, set: { v in
            store.draft.split = v
            if !v { store.draft.shares = []; store.draft.sharesEdited = false }
            store.draft.edited = nil
        })
        let total = evalAmount(d.amount) ?? 0
        let theirs = d.shares.reduce(0.0) { $0 + (evalAmount($1.amount) ?? 0) }
        return Section {
            Toggle(LS("AA 分摊"), isOn: on).tint(.jade)
            if d.split {
                ChipRow {
                    ForEach(ps) { p in
                        Chip(label: p.name, selected: d.shares.contains { $0.person == p.name }) { toggleShare(p.name) }
                    }
                    Chip(label: LS("＋ 其他人"), selected: addingPerson) { addingPerson.toggle() }
                }
                if addingPerson {
                    HStack {
                        TextField(LS("称呼，如 小王、王五"), text: $newPerson)
                            .submitLabel(.done)
                            .onSubmit { addPerson() }
                        Button(LS("加入")) { addPerson() }.disabled(newPerson.trimmed.isEmpty)
                    }
                }
                ForEach(d.shares) { x in
                    HStack {
                        Text(x.person)
                        Spacer()
                        TextField("0.00", text: Binding(get: { x.amount }, set: { v in
                            guard let i = store.draft.shares.firstIndex(where: { $0.id == x.id }) else { return }
                            store.draft.shares[i].amount = v
                            store.draft.sharesEdited = true
                            store.draft.edited = nil
                        }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 120)
                    }
                }
                if !d.shares.isEmpty {
                    LabeledContent(LS("我的份额")) {
                        Text(money(total - theirs, d.currency)).monospacedDigit()
                            .foregroundStyle(total - theirs < -0.004 ? Color.loss : Color.primary).sensitive()
                    }
                    if d.sharesEdited {
                        Button(LS("重新平均分摊")) { spreadShares() }.font(.footnote)
                    }
                }
            }
        } footer: {
            if d.split {
                Text(LS("别人的份额记到个人往来（Assets:Receivable:Personal），每一行用 person: 写明是谁；你的份额记入支出科目。之后在「往来」里登记他还你的钱。"))
            }
        }
        .onChange(of: d.amount) { _, _ in if store.draft.split && !store.draft.sharesEdited { spreadShares() } }
    }

    /// someone typed in: the same name as someone in 往来 is that person
    private func addPerson() {
        let name = newPerson.trimmed
        guard !name.isEmpty else { return }
        if !store.draft.shares.contains(where: { $0.person == name }) { toggleShare(name) }
        newPerson = ""
        addingPerson = false
    }

    private func toggleShare(_ name: String) {
        var d = store.draft
        if let i = d.shares.firstIndex(where: { $0.person == name }) { d.shares.remove(at: i) }
        else { d.shares.append(Share(person: name)) }
        store.draft = d
        if !store.draft.sharesEdited { spreadShares() } else { store.draft.edited = nil }
    }

    /// everyone, you included, pays the same; you take the odd cents
    private func spreadShares() {
        var d = store.draft
        let amt = evalAmount(d.amount) ?? 0
        let each = evenShares(amt, d.shares.count)
        for i in d.shares.indices { d.shares[i].amount = i < each.count ? toFixed(each[i], 2) : "" }
        d.sharesEdited = false
        d.edited = nil
        store.draft = d
    }

    @ViewBuilder
    private func payeeSuggestions(_ q: String, _ D: Derived) -> some View {
        let t = q.trimmed
        let items = D.payees.filter { t.isEmpty || fuzzy(t, $0.name) > 0 }.prefix(6)
        if !(items.count == 1 && items.first?.name == t) && !items.isEmpty {
            ChipRow {
                ForEach(Array(items), id: \.name) { p in
                    Chip(label: p.name) { store.applyPayee(p.name); focus = .narration }
                }
            }
        }
    }

    // MARK: 分录

    @ViewBuilder
    private func multiSection(_ L: Ledger, _ D: Derived) -> some View {
        Section {
            DateField(value: field(\.date))
            TextField(LS("商户"), text: field(\.payee)).focused($focus, equals: .payee).onSubmit { store.applyPayee(store.draft.payee.trimmed) }
            if focus == .payee { payeeSuggestions(store.draft.payee, D) }
            TextField(LS("说明"), text: field(\.narration))
            TextField(LS("#标签 ^链接"), text: field(\.tagsText)).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle(LS("! 待确认"), isOn: Binding(get: { store.draft.flag == "!" }, set: { store.draft.flag = $0 ? "!" : "*"; store.draft.edited = nil })).tint(.orange)
        }
        Section {
            ForEach(rowsBinding) { $row in
                RowEditor(row: $row, focus: $focus)
            }
            .onDelete { idx in store.draft.rows.remove(atOffsets: idx); store.draft.edited = nil }
            Button {
                store.draft.rows.append(DraftRow())
                store.draft.edited = nil
            } label: { Label(LS("添加分录行"), systemImage: "plus.circle") }
        } header: {
            Text(LS("分录"))
        } footer: {
            Text(LS("金额留空的一行将自动补平；左滑可删除。成本填写 {} 内的内容，如 180 USD；价格填写 @ 7.1 CNY 或 @@ 总价。"))
        }
    }

    // MARK: preview

    @ViewBuilder
    private func previewSection(_ text: String, _ v: Validation?, _ L: Ledger) -> some View {
        let d = store.draft
        let targets: [String] = {
            if let es = v?.entries, !es.isEmpty {
                var seen = Set<String>()
                return es.map { fileFor($0, L, layout: store.layout) }.filter { seen.insert($0).inserted }
            }
            return [store.layout.journalPath(d.date)]
        }()
        Section {
            if d.kind == .raw {
                CodeTextView(text: Binding(get: { text }, set: { nv in store.draft.raw = nv }), language: .beancount,
                             fontSize: 12.5, fitsContent: true)
                    .frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(LS("直接输入 Beancount 指令，可一次输入多条，例如：\n2026-10-08 price USD 7.10 CNY\n2026-10-09 balance Assets:Cash 400.00 CNY"))
                                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 6).allowsHitTesting(false)
                        }
                    }
            } else if text.isEmpty {
                Text(LS("填写金额与账户后将在此生成分录")).font(.footnote).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    MonoText(text: text)
                    Label(d.edited != nil ? LS("已手动编辑 · 点按继续编辑") : LS("点按编辑源文本"), systemImage: "pencil")
                        .font(.footnote)
                        .foregroundStyle(Color.jade)
                }
                .contentShape(Rectangle())
                .onTapGesture { hideKeyboard(); editingText = true }
                .accessibilityAddTraits(.isButton)
            }
            if let v = v {
                if v.ok {
                    Label(v.warnings.isEmpty ? LS("校验通过") : v.warnings[0].msg, systemImage: v.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(v.warnings.isEmpty ? Color.gain : Color.orange)
                } else if let m = v.msg {
                    Label(m, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.loss)
                }
            }
        } header: {
            HStack {
                Text(LS("将写入 ") + targets.joined(separator: LS("、"))).textCase(nil)
                Spacer()
                if d.kind != .raw && d.edited != nil {
                    Button(LS("恢复自动生成")) { store.draft.edited = nil }.font(.footnote).textCase(nil)
                } else if d.kind != .raw && !text.isEmpty {
                    Text(LS("点按文本可编辑")).textCase(nil)
                }
            }
        }
    }

    // MARK: recent

    @ViewBuilder
    private func recentSection(_ L: Ledger, _ D: Derived) -> some View {
        let pend = store.pending.filter { $0.kind == .insert || $0.kind == .balance }.reversed()
        let recent = Array(L.txns.suffix(12).reversed().prefix(10))
        Section(LS("最近")) {
            ForEach(Array(pend)) { o in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(o.summary ?? o.label ?? "").lineLimit(1)
                            Text(o.failed != nil ? LS("未提交") : o.held != nil ? LS("暂存本机") : LS("待同步")).font(.caption2.weight(.semibold)).foregroundStyle(o.failed != nil ? Color.loss : Color.orange)
                        }
                        Text(o.date ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(masked(o.amountText ?? "")).monospacedDigit().sensitive()
                }
            }
            ForEach(recent, id: \.id) { t in
                NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) }
            }
        }
    }

    // MARK: save

    private func save(_ L: Ledger, _ D: Derived) async {
        focus = nil
        if store.draft.kind == .raw { await saveRaw(L, overwriteOK: false); return }
        if await store.saveDraft() { onSaved() }
    }

    private func saveRaw(_ L: Ledger, overwriteOK: Bool) async {
        let text = store.draft.raw.trimmed
        let v = validateText(text, L, single: false)
        guard v.ok else { store.show(text.isEmpty ? LS("请输入 Beancount 文本") : (v.msg.flatMap { $0.isEmpty ? nil : $0 } ?? LS("内容校验未通过"))); return }
        if !overwriteOK {
            let dups = duplicateBalances(v.entries, L)
            if !dups.isEmpty { confirmOverwrite = dups; showOverwrite = true; return }
        }
        guard let ops0 = store.makeOps(alignText(text), single: false), let ops = await store.review(ops0) else { return }
        var nd = store.newDraftFor(.raw)
        nd.date = store.draft.date
        store.draft = nd
        if await store.commit(ops, checked: true) { onSaved() }
    }
}

struct RowEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    @Binding var row: DraftRow
    var focus: FocusState<AddField?>.Binding
    @State private var picking = false
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { picking = true } label: {
                    Text(row.account.isEmpty ? LS("选择账户") : row.account)
                        .font(.subheadline)
                        .foregroundStyle(row.account.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { row.flag = row.flag == "!" ? "" : "!" } label: {
                    Text("!").font(.subheadline.weight(.bold)).frame(width: 26, height: 26)
                        .background(row.flag == "!" ? Color.orange : Color(.tertiarySystemFill), in: Circle())
                        .foregroundStyle(row.flag == "!" ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("标记为待确认（!）"))
            }
            HStack(spacing: 8) {
                Button {
                    let a = row.amount.trimmed
                    row.amount = a.hasPrefix("-") ? String(a.dropFirst()) : "-" + a
                } label: {
                    Text("±").font(.headline).frame(width: 34, height: 30).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                TextField(LS("自动补平"), text: $row.amount)
                    .keyboardType(.decimalPad)
                    .focused(focus, equals: .row(row.id))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                Menu {
                    Picker(LS("币种"), selection: Binding(get: { row.currency }, set: { row.currency = $0; row.ccyTouched = true })) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Text(row.currency).font(.subheadline.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Button { withAnimation { showMore.toggle() } } label: {
                    Image(systemName: showMore || !row.cost.isEmpty || !row.price.isEmpty ? "chevron.up.circle.fill" : "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.jade)
                .accessibilityLabel(LS("成本与价格"))
            }
            if showMore || !row.cost.isEmpty || !row.price.isEmpty {
                HStack {
                    TextField(LS("成本 {180 USD}"), text: $row.cost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(LS("价格 @ 7.1 CNY"), text: $row.price).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .font(.footnote)
            }
            if isPersonal(row.account) {
                TextField(LS("对方（person:），如 五姨"), text: $row.person).font(.footnote)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $picking) {
            AccountPicker(title: LS("账户"), prefixes: ["Assets:", "Liabilities:", "Expenses:", "Income:", "Equity:"], current: row.account, allowAny: true) { a in
                row.account = a
                if !row.ccyTouched, let c = store.D?.acctCcy[a] { row.currency = c }
            }
        }
    }

    var currencies: [String] {
        var cs = store.D?.currencies ?? ["CNY"]
        for c in (store.L?.commodities.keys.sorted() ?? []) where !cs.contains(c) { cs.append(c) }
        if !cs.contains(row.currency) { cs.append(row.currency) }
        return cs
    }
}

struct TemplateManager: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.templateList) { x in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(x.label + (x.payee.isEmpty || x.narration.isEmpty ? "" : "  " + x.narration))
                                Text(LS("%@ · %@ 次%@%@", acctDisplay(x.account), x.n, x.monthly ? LS(" · 每月") : "", x.fixed.map { LS(" · 固定 ") + money($0, x.currency) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(x.pinned ? LS("已置顶") : LS("置顶")) {
                                store.pinTemplate(x.id, !x.pinned)
                            }
                            .buttonStyle(.bordered).tint(x.pinned ? .jade : .gray).controlSize(.small)
                        }
                        .swipeActions {
                            Button(LS("隐藏"), role: .destructive) {
                                store.hideTemplate(x.id)
                            }
                        }
                    }
                } footer: {
                    Text(LS("近 120 天内出现 3 次及以上的交易将自动列入；置顶项优先显示，左滑可隐藏。"))
                }
                if !store.tplHidden.isEmpty {
                    Button(LS("恢复 %@ 项已隐藏", store.tplHidden.count)) { store.unhideAllTemplates() }
                }
            }
            .navigationTitle(LS("常用交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() } } }
        }
    }
}
