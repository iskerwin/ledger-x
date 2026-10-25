import SwiftUI
import LedgerKit

struct CounterpartyDest: Hashable {}
struct PersonDest: Hashable { let name: String }

/// a loan entry to write: for someone already in the ledger (their name) or someone new (nil)
struct LoanTarget: Identifiable {
    let id = UUID()
    var name: String?
    var kind: LoanKind
}

/// balances to bring to zero, and where what is left goes
struct SettleTarget: Identifiable {
    let id = UUID()
    let title: String
    let payee: String
    let link: String?
    let items: [SettleItem]
    /// accounts offered for what is left, the first chosen
    let to: [String]
    /// the company's difference: by default the money really comes in (or goes back) through a bank account;
    /// writing it off to `to` is the other choice
    var receive: EmployerSettlement? = nil
}

/// 往来: what people, the company and the reimbursement desk owe you, and what you owe them
struct CounterpartyView: View {
    @Environment(Store.self) var store
    @State private var loan: LoanTarget?
    @State private var settle: SettleTarget?
    @State private var showSettled = false
    @State private var pettyCash = false

    var body: some View {
        List {
            if let L = store.L, let D = store.D {
                let ps = people(L)
                let emp = employerOpen(L)
                summary(L, D, ps, emp)
                reimbSection(L, D)
                employerSection(L, emp)
                peopleSection(ps)
            }
        }
        .refreshable { await store.refresh() }
        .listChanges(store.version)
        .navigationTitle(LS("往来"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { loan = LoanTarget(name: nil, kind: .lend) } label: { Label(LS("新的往来"), systemImage: "person.badge.plus") }
                    Button { pettyCash = true } label: { Label(LS("领取备用金"), systemImage: "banknote") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel(LS("新的往来"))
            }
        }
        .navigationDestination(for: PersonDest.self) { PersonView(name: $0.name).privacyToolbar() }
        .sheet(item: $loan) { LoanSheet(target: $0) }
        .sheet(isPresented: $pettyCash) { PettyCashSheet() }
        .sheet(item: $settle) { SettleSheet(target: $0) }
    }

    private func reimbBalance(_ L: Ledger, _ D: Derived) -> Double {
        (L.final[D.receivable] ?? [:]).reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key) ?? 0) }
    }

    private func summary(_ L: Ledger, _ D: Derived, _ ps: [Person], _ emp: (total: [String: Double], open: [OpenDifference])) -> some View {
        let empCNY = emp.total.reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key) ?? 0) }
        let parts = [reimbBalance(L, D), empCNY] + ps.map { $0.netCNY }
        let owed = parts.filter { $0 > 0 }.reduce(0, +), owe = -parts.filter { $0 < 0 }.reduce(0, +)
        return Section {
            LabeledContent(LS("别人欠我")) { Amount(n: owed) }
            LabeledContent(LS("我欠别人")) { Amount(n: owe) }
        } footer: {
            Text(LS("报销应收（含备用金）、公司往来和每个人的个人往来（Assets:Receivable:Personal，按 person: 区分）与借款（Liabilities:Loan）合在一起，按人民币折算。"))
        }
    }

    /// reimbursements live on their own page (报表 → 报销); here only what is owed, one tap away
    @ViewBuilder
    private func reimbSection(_ L: Ledger, _ D: Derived) -> some View {
        let bal = reimbBalance(L, D)
        let open = reimbBatches(L).filter { !$0.settled }.count
        if !D.unclaimed.isEmpty || open > 0 || abs(bal) > 0.005 {
            Section {
                NavigationLink(value: ReimbursementsDest()) {
                    BatchRowLabel(title: LS("报销"), caption: reimbCaption(D, open), amount: bal, currency: "CNY")
                }
            }
        }
    }

    @ViewBuilder
    private func employerSection(_ L: Ledger, _ emp: (total: [String: Double], open: [OpenDifference])) -> some View {
        let acct = L.accounts.keys.filter(isSalaryClearing).sorted().first
        if let acct = acct, !emp.open.isEmpty || !emp.total.isEmpty {
            Section {
                ForEach(emp.open) { x in
                    Button {
                        let r = employerSettlement(L, x)
                        settle = SettleTarget(title: LS("公司往来"), payee: r.payee.isEmpty ? (metaName(L, acct) ?? LS("公司")) : r.payee, link: x.link,
                                              items: [SettleItem(account: x.account, currency: x.currency, amount: x.amount)],
                                              to: ["Income:Salary:Other", "Income:Salary"], receive: r)
                    } label: {
                        row(x.link.map { "^" + $0 } ?? LS("未关联的差额"),
                            (x.amount > 0 ? LS("公司少发，待补") : LS("公司多发，待退")) + (x.date.isEmpty ? "" : " · " + x.date) + LS(" · 点按处理"),
                            x.amount, x.currency)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink(value: AccountDest(name: acct)) { Label(LS("公司往来明细"), systemImage: "list.bullet").labelStyle(ControlLabelStyle()) }
            } header: {
                Text(metaName(L, acct) ?? LS("公司往来"))
            } footer: {
                Text(LS("正数是公司少发、还会补；负数是公司多发、还要退。补发到账或退回公司时点按记一笔银行收付；确定不会再补或退的，点按后选「核销」，记入 Income:Salary:Other。"))
            }
        }
    }

    @ViewBuilder
    private func peopleSection(_ ps: [Person]) -> some View {
        let open = ps.filter { !$0.settled }
        let done = ps.filter { $0.settled && !$0.closed }
        Section {
            if ps.isEmpty {
                EmptyAdd(text: LS("还没有个人往来。借给别人或向别人借的钱记在这里，还款时一键结清。"), title: LS("新的往来")) { loan = LoanTarget(name: nil, kind: .lend) }
            }
            ForEach(open) { p in personRow(p) }
            if !done.isEmpty {
                DisclosureGroup(LS("已结清 %@ 人", done.count), isExpanded: $showSettled) {
                    ForEach(done) { p in personRow(p) }
                }
            }
        } header: {
            Text(LS("个人"))
        } footer: {
            Text(LS("个人往来都在 Assets:Receivable:Personal 一个账户里，每一笔用 person: 写明是谁。AA 分摊时别人的份额记在这里；别人替你付的钱，付款账户选个人往来并填上对方。"))
        }
    }

    private func personRow(_ p: Person) -> some View {
        NavigationLink(value: PersonDest(name: p.name)) {
            HStack(spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(personTitle(p.name)).foregroundStyle(p.unnamed ? Color.warn : Color.primary)
                    Text(personCaption(p)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !p.settled {
                    Text(money(abs(p.netCNY))).monospacedDigit().foregroundStyle(p.netCNY > 0 ? Color.primary : Color.warn).sensitive()
                }
            }
        }
    }

    private func row(_ title: String, _ caption: String, _ n: Double, _ c: String, chevron: Bool = true) -> some View {
        HStack(spacing: AppSpacing.icon) {
            ControlIcon(systemName: "arrow.left.arrow.right")
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(title).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Amount(n: n, c: c)
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// how a person is shown: their name, or a note for receivable postings that name nobody
func personTitle(_ name: String) -> String { name.isEmpty ? LS("未注明对方") : name }

/// petty cash to offset advances against
struct FloatTarget: Identifiable {
    let link: String
    var id: String { link }
}

/// "3 笔待报销 · 2 张单子进行中"
func reimbCaption(_ D: Derived, _ open: Int) -> String {
    var parts: [String] = []
    if !D.unclaimed.isEmpty { parts.append(LS("%@ 笔待报销", D.unclaimed.count)) }
    if open > 0 { parts.append(LS("%@ 张进行中", open)) }
    return parts.isEmpty ? LS("报销应收余额") : parts.joined(separator: " · ")
}

func personCaption(_ p: Person) -> String {
    let state = p.settled ? LS("已结清") : p.netCNY > 0 ? LS("他欠我") : LS("我欠他")
    return state + (p.last.map { " · " + LS("最近 %@", $0) } ?? "")
}

/// one person: what is owed each way, the actions, and every transaction with them
struct PersonView: View {
    @Environment(Store.self) var store
    let name: String
    @State private var loan: LoanTarget?
    @State private var settle: SettleTarget?
    @State private var limit = 100

    var body: some View {
        List {
            if let L = store.L, let p = people(L).first(where: { $0.name == name }) {
                Section {
                    if p.settled {
                        Label(LS("已结清"), systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain)
                    }
                    ForEach(p.net.sorted { $0.key < $1.key }, id: \.key) { e in
                        LabeledContent(e.value > 0 ? LS("他欠我") : LS("我欠他")) { Amount(n: abs(e.value), c: e.key) }
                    }
                    ForEach(p.balances.keys.sorted(), id: \.self) { a in
                        let line = HStack(spacing: AppSpacing.control) {
                            Text(acctLabel(a)).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text(p.balances[a]!.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }.joined(separator: " · "))
                                .monospacedDigit().font(.subheadline).sensitive()
                        }
                        // the personal receivable is everyone's: only a loan account is theirs alone
                        if isPersonal(a) { line } else { NavigationLink(value: AccountDest(name: a)) { line } }
                    }
                } footer: {
                    Text(p.unnamed ? LS("这些个人往来没有写明是谁（person:）。在交易详情里编辑源文本补上 person:，金额就会归到那个人名下。")
                         : LS("个人往来为正是你替他付或借给他的钱；借款（Liabilities:Loan）是你向他借的钱。两者相加就是净额。"))
                }
                if !p.unnamed {
                    Section {
                        ActionRow(size: .small, items: LoanKind.allCases.map { k in
                            ActionRow.Item(title: k.label, systemImage: k.incoming ? "arrow.down.left" : "arrow.up.right") {
                                loan = LoanTarget(name: name, kind: k)
                            }
                        })
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    if !p.settled {
                        // Its own section, so the row is a full rounded card with the
                        // normal gap under the actions. Sharing the action section
                        // squared off the top and stuck the card to the buttons.
                        Section {
                            Button { settle = settleTarget(L, p) } label: { Label(LS("结清剩余金额…"), systemImage: "checkmark.circle").labelStyle(ControlLabelStyle()) }
                        }
                    }
                }
                let es = personEntries(L, name)
                Section(LS("记录（%@ 笔）", es.count)) {
                    ForEach(es.prefix(limit), id: \.id) { t in
                        NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) }
                    }
                    if es.count > limit { Button { limit += 200 } label: { Label(LS("显示更多"), systemImage: "chevron.down").labelStyle(ControlLabelStyle()) } }
                }
            } else {
                Text(LS("没有找到 %@ 的往来", personTitle(name))).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(personTitle(name))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $loan) { LoanSheet(target: $0) }
        .sheet(item: $settle) { SettleSheet(target: $0) }
    }

    /// everything left on their accounts, to gifts given (they owe you, you let it go) or received (you owe, they let it go)
    private func settleTarget(_ L: Ledger, _ p: Person) -> SettleTarget {
        var items: [SettleItem] = []
        for a in p.balances.keys.sorted() {
            for (c, v) in p.balances[a]!.sorted(by: { $0.key < $1.key }) where abs(v) > 0.005 {
                items.append(SettleItem(account: a, currency: c, amount: roundTo(v, 2), person: isPersonal(a) ? p.name : nil))
            }
        }
        let gifts = p.netCNY > 0 ? ["Expenses:Gifts", "Income:Gifts"] : ["Income:Gifts", "Expenses:Gifts"]
        let known = gifts.filter { L.accounts[$0] != nil }
        return SettleTarget(title: LS("结清 %@", p.name), payee: p.name, link: nil, items: items, to: known.isEmpty ? gifts : known)
    }
}

// MARK: - lend / collect / borrow / repay

struct LoanSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let target: LoanTarget
    @State private var d = LoanDraft()
    @State private var keyTouched = false
    @State private var ready = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { PageLoading() }
            }
            .keyboardDone()
            .navigationTitle(target.name == nil ? LS("新的往来") : d.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
        }
    }

    private func person(_ L: Ledger) -> Person? { people(L).first { $0.name == d.name.trimmed } }
    /// borrowing from or repaying someone without a loan account: one is opened, and needs an account name
    private func needsKey(_ L: Ledger) -> Bool { !d.kind.receivable && person(L)?.loan(L) == nil }

    private func form(_ L: Ledger, _ D: Derived) -> some View {
        let text = loanText(d, L)
        let v = text.isEmpty ? nil : validateText(text, L, single: false)
        let p = person(L)
        return Form {
            Section {
                Picker(LS("类型"), selection: $d.kind) {
                    ForEach(LoanKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(kindHelp(d.kind))
            }
            if target.name == nil {
                Section {
                    let known = people(L).filter { !$0.closed && !$0.unnamed }
                    if !known.isEmpty {
                        ChipRow {
                            ForEach(known) { x in
                                Chip(label: x.name, selected: d.name == x.name) { d.name = x.name }
                            }
                        }
                    }
                    TextField(LS("称呼（如 五姨、王五）"), text: Binding(get: { d.name }, set: { n in
                        d.name = n
                        if !keyTouched { d.key = accountPart(from: n) ?? "" }
                    }))
                    if needsKey(L) {
                        LabeledContent(LS("借款账户名")) {
                            TextField("WangWu", text: Binding(get: { d.key }, set: { d.key = $0; keyTouched = true }))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text(LS("对方"))
                } footer: {
                    if needsKey(L) {
                        Text(!d.key.isEmpty && !validAccountPart(d.key)
                             ? LS("账户名需以大写字母或数字开头，只能包含英文字母、数字和 -，例如拼音 WangWu。")
                             : LS("向他借钱会开立 %@<账户名>，建议用拼音；称呼记为账户的 name。", loanPrefix))
                    } else {
                        Text(LS("借出、收回记在个人往来（Assets:Receivable:Personal），用 person: 写明是谁。"))
                    }
                }
            } else if let p = p {
                Section {
                    LabeledContent(LS("对方"), value: p.name)
                    ForEach(p.net.sorted { $0.key < $1.key }, id: \.key) { e in
                        LabeledContent(e.value > 0 ? LS("他欠我") : LS("我欠他")) { Amount(n: abs(e.value), c: e.key) }
                    }
                }
            }
            Section {
                DateField(value: $d.date)
                LabeledContent(LS("金额 ") + d.currency) {
                    TextField(suggested(p).map { fmtNum($0) } ?? "0.00", text: $d.amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                if D.currencies.count > 1 {
                    Picker(LS("币种"), selection: $d.currency) {
                        ForEach(D.currencies, id: \.self) { Text($0).tag($0) }
                    }
                }
                AccountField(label: d.kind.incoming ? LS("收款账户") : LS("付款账户"), prefixes: ["Assets:", "Liabilities:"],
                             chips: Array(D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(6)),
                             value: $d.account)
                TextField(LS("摘要（可选）"), text: $d.note)
            }
            Section(LS("将写入")) {
                if text.isEmpty {
                    Text(LS("填好对方、金额和账户后生成")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    MonoText(text: text)
                    if let m = v?.msg, v?.ok == false { ValidationRow(message: m) }
                }
            }
            Section {
                Button {
                    Task { await save(text) }
                } label: {
                    HStack(spacing: AppSpacing.control) { Spacer(); BusyLabel(busy: saving, title: LS("保存"), systemImage: "checkmark").fontWeight(.semibold); Spacer() }
                }
                .primaryButton()
                .disabled(text.isEmpty || v?.ok != true || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            d.kind = target.kind
            d.currency = store.defaultCurrency ?? "CNY"
            if let n = target.name {
                d.name = n
                if let c = person(L)?.net.keys.sorted().first { d.currency = c }
            }
            d.account = D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).first { !$0.hasPrefix("Assets:Receivable") } ?? ""
        }
    }

    /// what is outstanding, for collecting or repaying it in full
    private func suggested(_ p: Person?) -> Double? {
        guard let p = p, let v = p.net[d.currency] else { return nil }
        if d.kind == .collect && v > 0 { return v }
        if d.kind == .repay && v < 0 { return -v }
        return nil
    }

    private func kindHelp(_ k: LoanKind) -> String {
        switch k {
        case .lend: return LS("借给对方或替对方垫付，记入个人往来。")
        case .collect: return LS("对方还你钱，冲减他的个人往来。")
        case .borrow: return LS("向对方借钱，记入借款（Liabilities:Loan）。")
        case .repay: return LS("你还对方钱，冲减借款。")
        }
    }

    private func save(_ text0: String) async {
        var text = text0
        // collecting / repaying with the amount left empty: the outstanding amount
        if text.isEmpty, let L = store.L, let s = suggested(person(L)) {
            d.amount = fmtNum(s); text = loanText(d, L)
        }
        guard !text.isEmpty else { return }
        saving = true
        defer { saving = false }
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("%@：%@", d.kind.label, d.name.trimmed)), single: false),
              let checked = await store.review(ops) else { return }
        dismiss()
        await store.commit(checked, checked: true)
    }
}

// MARK: - settle what is left

struct SettleSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let target: SettleTarget
    @State private var date = Day.today()
    @State private var to = ""
    @State private var narration = ""
    @State private var ready = false
    @State private var saving = false
    /// the company's difference: write it off instead of receiving / returning the money
    @State private var writeOff = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { PageLoading() }
            }
            .keyboardDone()
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
        }
    }

    /// receiving the company's back pay or returning what it overpaid
    private var moving: EmployerSettlement? { writeOff ? nil : target.receive }

    private var owedToMe: Bool { target.items.reduce(0) { $0 + $1.amount } > 0 }

    private func form(_ L: Ledger) -> some View {
        let fallback = moving?.narration ?? LS("结清")
        let text = settleText(L, date: date, payee: target.payee, narration: narration.trimmed.isEmpty ? fallback : narration.trimmed,
                              link: target.link, items: target.items, to: to)
        let v = text.isEmpty ? nil : validateText(text, L, single: false)
        return Form {
            Section {
                if let l = target.link { LabeledContent(LS("关联"), value: "^" + l) }
                ForEach(target.items, id: \.self) { i in
                    LabeledContent(acctLabel(i.account) + (i.person.map { " · " + personTitle($0) } ?? "")) { Amount(n: i.amount, c: i.currency) }
                }
            } footer: {
                if target.receive == nil {
                    Text(LS("这些余额会清零，差额记入下面的账户。只在确定不会再补、再退时结清；还会变的留着不动即可（挂账）。"))
                }
            }
            if let r = target.receive {
                Section {
                    Picker(LS("处理方式"), selection: $writeOff) {
                        Text(owedToMe ? LS("收到补发") : LS("退回公司")).tag(false)
                        Text(LS("核销")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: writeOff) { _, off in to = off ? (target.to.first ?? "") : (r.account ?? "") }
                } footer: {
                    Text(writeOff ? LS("公司不会再补或退了：差额记入工资科目（默认 Income:Salary:Other），不经过银行。")
                         : owedToMe ? LS("公司把少发的钱补到账了：记一笔银行收款，冲掉这笔差额。不要先核销再另记收款，那样收入会算两次。")
                         : LS("把公司多发的钱退回去：记一笔银行付款，冲掉这笔差额。"))
                }
            }
            Section {
                DateField(value: $date)
                if moving != nil {
                    AccountField(label: owedToMe ? LS("收款账户") : LS("付款账户"), prefixes: ["Assets:", "Liabilities:"],
                                 chips: [target.receive?.account].compactMap { $0 }, value: $to)
                } else {
                    AccountField(label: LS("差额记入"), prefixes: ["Income:", "Expenses:", "Equity:", "Assets:"], chips: target.to, value: $to)
                }
                TextField(LS("说明（默认「%@」）", fallback), text: $narration)
            }
            Section(LS("将写入")) {
                if text.isEmpty { Text(LS("选择差额账户后生成")).font(.footnote).foregroundStyle(.secondary) }
                else {
                    MonoText(text: text)
                    if let m = v?.msg, v?.ok == false { ValidationRow(message: m) }
                }
            }
            Section {
                Button {
                    Task { await save(text) }
                } label: {
                    HStack(spacing: AppSpacing.control) { Spacer(); BusyLabel(busy: saving, title: moving == nil ? LS("结清") : LS("保存"), systemImage: "checkmark.circle").fontWeight(.semibold); Spacer() }
                }
                .primaryButton()
                .disabled(text.isEmpty || v?.ok != true || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            to = target.receive.map { $0.account ?? "" } ?? target.to.first ?? ""
        }
    }

    private func save(_ text: String) async {
        guard !text.isEmpty else { return }
        saving = true
        defer { saving = false }
        guard let ops = store.makeOps(text, extra: OpExtra(label: target.title), single: false),
              let checked = await store.review(ops) else { return }
        dismiss()
        await store.commit(checked, word: LS("已结清"), checked: true)
    }
}

/// the overview's line into 往来
struct CounterpartyOverviewRow: View {
    @Environment(Store.self) var store
    let L: Ledger
    var body: some View {
        let ps = people(L)
        let emp = employerOpen(L).open.count
        let open = ps.filter { !$0.settled }
        let owed = open.filter { $0.netCNY > 0 }.reduce(0.0) { $0 + $1.netCNY }
        let owe = -open.filter { $0.netCNY < 0 }.reduce(0.0) { $0 + $1.netCNY }
        NavigationLink(value: CounterpartyDest()) {
            HStack(spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(LS("个人与公司往来"))
                    Text(LS("%@ 人未结清", open.count) + (emp > 0 ? LS(" · 公司 %@ 笔", emp) : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                    if owed > 0.005 { Text(LS("应收 ") + money(owed)).font(.caption).monospacedDigit().sensitive() }
                    if owe > 0.005 { Text(LS("应付 ") + money(owe)).font(.caption).monospacedDigit().foregroundStyle(Color.warn).sensitive() }
                }
            }
        }
    }
}
