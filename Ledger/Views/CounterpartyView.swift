import SwiftUI
import LedgerKit

struct CounterpartyDest: Hashable {}
struct PersonDest: Hashable { let key: String }

/// a loan entry to write: for someone already in the ledger (key) or someone new (nil)
struct LoanTarget: Identifiable {
    let id = UUID()
    var key: String?
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
}

/// 往来: what people, the company and the reimbursement desk owe you, and what you owe them
struct CounterpartyView: View {
    @EnvironmentObject var store: Store
    @State private var reimb: ReimbTarget?
    @State private var loan: LoanTarget?
    @State private var settle: SettleTarget?
    @State private var showSettled = false

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
        .navigationTitle(LS("往来"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { loan = LoanTarget(key: nil, kind: .lend) } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel(LS("新的往来"))
            }
        }
        .navigationDestination(for: PersonDest.self) { PersonView(key: $0.key) }
        .sheet(item: $reimb) { ReimbSheet(target: $0) }
        .sheet(item: $loan) { LoanSheet(target: $0) }
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
            Text(LS("报销应收、公司往来和每个人的个人往来（Assets:Receivable:Personal）与借款（Liabilities:Loan）合在一起，按人民币折算。"))
        }
    }

    @ViewBuilder
    private func reimbSection(_ L: Ledger, _ D: Derived) -> some View {
        let open = D.openLinks.filter { abs($0.amount) > 0.005 }
        let bal = reimbBalance(L, D)
        if !D.unclaimed.isEmpty || !open.isEmpty || abs(bal) > 0.005 {
            Section {
                if !D.unclaimed.isEmpty {
                    Button { reimb = ReimbTarget(link: nil) } label: {
                        row(LS("待报销垫款"), LS("%@ 笔 · 最早 %@ · 点按登记回款", D.unclaimed.count, D.unclaimed[0].t.date),
                            D.unclaimed.reduce(0.0) { $0 + $1.amount }, "CNY")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(open, id: \.link) { x in
                    Button { reimb = ReimbTarget(link: x.link) } label: {
                        row("^" + x.link, LS("%@ 笔垫款 · 点按登记回款", x.n), x.amount, x.currency)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink(value: AccountDest(name: D.receivable)) { Text(LS("报销应收明细")) }
            } header: {
                HStack { Text(LS("报销")); Spacer(); Text(money(bal)).monospacedDigit().sensitive() }
            }
        }
    }

    @ViewBuilder
    private func employerSection(_ L: Ledger, _ emp: (total: [String: Double], open: [OpenDifference])) -> some View {
        let acct = L.accounts.keys.filter(isSalaryClearing).sorted().first
        if let acct = acct, !emp.open.isEmpty || !emp.total.isEmpty {
            Section {
                ForEach(emp.open) { x in
                    if let fl = x.link, fl.hasPrefix("float-") {
                        // petty cash: its transactions; what is left goes back with a swipe
                        NavigationLink(value: LinkDest(link: fl)) {
                            row("^" + fl, LS("备用金 · %@ · 报销时选「备用金冲抵」，左滑退回剩余", x.date), x.amount, x.currency, chevron: false)
                        }
                        .swipeActions {
                            Button(LS("退回剩余")) {
                                let banks = store.D.map { Array($0.rankAccounts(["Assets:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(4)) } ?? []
                                settle = SettleTarget(title: LS("退回备用金"), payee: metaName(L, acct) ?? LS("公司"), link: fl,
                                                      items: [SettleItem(account: x.account, currency: x.currency, amount: x.amount)], to: banks)
                            }
                            .tint(.jade)
                        }
                    } else {
                    Button {
                        settle = SettleTarget(title: LS("结清公司往来"), payee: metaName(L, acct) ?? LS("公司"), link: x.link,
                                              items: [SettleItem(account: x.account, currency: x.currency, amount: x.amount)],
                                              to: ["Income:Salary:Other", "Income:Salary"])
                    } label: {
                        row(x.link.map { "^" + $0 } ?? LS("未关联的差额"),
                            (x.amount > 0 ? LS("公司少发，待补") : LS("公司多发，待退")) + (x.date.isEmpty ? "" : " · " + x.date) + LS(" · 点按结清"),
                            x.amount, x.currency)
                    }
                    .buttonStyle(.plain)
                    }
                }
                NavigationLink(value: AccountDest(name: acct)) { Text(LS("公司往来明细")) }
            } header: {
                Text(metaName(L, acct) ?? LS("公司往来"))
            } footer: {
                Text(LS("正数是公司少发、还会补；负数是公司多发、还要退。不会再补或退的差额点按结清，默认记入 Income:Salary:Other。"))
            }
        }
    }

    @ViewBuilder
    private func peopleSection(_ ps: [Person]) -> some View {
        let open = ps.filter { !$0.settled }
        let done = ps.filter { $0.settled && !$0.closed }
        Section {
            if ps.isEmpty {
                Text(LS("还没有个人往来。点右上角记一笔借出或借入。")).foregroundStyle(.secondary)
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
            Text(LS("记一笔支出时打开「AA 分摊」，别人的份额记到他的个人往来；别人替你付的钱，付款账户选他的个人往来即可。"))
        }
    }

    private func personRow(_ p: Person) -> some View {
        NavigationLink(value: PersonDest(key: p.key)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
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

func personCaption(_ p: Person) -> String {
    let state = p.settled ? LS("已结清") : p.netCNY > 0 ? LS("他欠我") : LS("我欠他")
    return state + (p.last.map { " · " + LS("最近 %@", $0) } ?? "")
}

/// one person: what is owed each way, the actions, and every transaction with them
struct PersonView: View {
    @EnvironmentObject var store: Store
    let key: String
    @State private var loan: LoanTarget?
    @State private var settle: SettleTarget?
    @State private var limit = 100

    var body: some View {
        List {
            if let L = store.L, let p = people(L).first(where: { $0.key == key }) {
                Section {
                    if p.settled {
                        Label(LS("已结清"), systemImage: "checkmark.seal").foregroundStyle(Color.gain)
                    }
                    ForEach(p.net.sorted { $0.key < $1.key }, id: \.key) { e in
                        LabeledContent(e.value > 0 ? LS("他欠我") : LS("我欠他")) { Amount(n: abs(e.value), c: e.key) }
                    }
                    ForEach(p.balances.keys.sorted(), id: \.self) { a in
                        NavigationLink(value: AccountDest(name: a)) {
                            HStack {
                                Text(acctLabel(a)).font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Text(p.balances[a]!.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }.joined(separator: " · "))
                                    .monospacedDigit().font(.subheadline).sensitive()
                            }
                        }
                    }
                } footer: {
                    Text(LS("个人往来为正是你替他付或借给他的钱；借款（Liabilities:Loan）是你向他借的钱。两者相加就是净额。"))
                }
                Section {
                    HStack(spacing: 8) {
                        ForEach(LoanKind.allCases) { k in
                            Button { loan = LoanTarget(key: key, kind: k) } label: {
                                Text(k.label).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    if !p.settled {
                        Button(LS("结清剩余金额…")) { settle = settleTarget(L, p) }
                    }
                }
                let es = personEntries(L, key)
                Section(LS("记录（%@ 笔）", es.count)) {
                    ForEach(es.prefix(limit), id: \.id) { t in
                        NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) }
                    }
                    if es.count > limit { Button(LS("显示更多")) { limit += 200 } }
                }
            } else {
                Text(LS("没有找到 %@ 的往来账户", key)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.L.flatMap { L in people(L).first { $0.key == key }?.name } ?? key)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $loan) { LoanSheet(target: $0) }
        .sheet(item: $settle) { SettleSheet(target: $0) }
    }

    /// everything left on their accounts, to gifts given (they owe you, you let it go) or received (you owe, they let it go)
    private func settleTarget(_ L: Ledger, _ p: Person) -> SettleTarget {
        var items: [SettleItem] = []
        for a in p.balances.keys.sorted() {
            for (c, v) in p.balances[a]!.sorted(by: { $0.key < $1.key }) where abs(v) > 0.005 {
                items.append(SettleItem(account: a, currency: c, amount: roundTo(v, 2)))
            }
        }
        let gifts = p.netCNY > 0 ? ["Expenses:Gifts", "Income:Gifts"] : ["Income:Gifts", "Expenses:Gifts"]
        let known = gifts.filter { L.accounts[$0] != nil }
        return SettleTarget(title: LS("结清 %@", p.name), payee: p.name, link: nil, items: items, to: known.isEmpty ? gifts : known)
    }
}

// MARK: - lend / collect / borrow / repay

struct LoanSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: LoanTarget
    @State private var d = LoanDraft()
    @State private var keyTouched = false
    @State private var ready = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(target.key == nil ? LS("新的往来") : d.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    private func person(_ L: Ledger) -> Person? { people(L).first { $0.key == d.key } }

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
            if target.key == nil {
                Section {
                    let known = people(L).filter { !$0.closed }
                    if !known.isEmpty {
                        ChipRow {
                            ForEach(known) { x in
                                Chip(label: x.name, selected: d.key == x.key) { d.key = x.key; d.name = x.name; keyTouched = true }
                            }
                        }
                    }
                    TextField(LS("称呼（如 五姨、王五）"), text: Binding(get: { d.name }, set: { n in
                        d.name = n
                        if !keyTouched { d.key = accountPart(from: n) ?? "" }
                    }))
                    LabeledContent(LS("账户名")) {
                        TextField("WangWu", text: Binding(get: { d.key }, set: { d.key = $0; keyTouched = true }))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(LS("对方"))
                } footer: {
                    Text(!d.key.isEmpty && !validAccountPart(d.key)
                         ? LS("账户名需以大写字母或数字开头，只能包含英文字母、数字和 -，例如拼音 WangWu。")
                         : LS("账户名用于 %@<账户名>，建议用拼音；称呼显示在 App 里。", d.kind.account("")))
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
                TextField(LS("备注（可选）"), text: $d.note)
            }
            Section(LS("将写入")) {
                if text.isEmpty {
                    Text(LS("填好对方、金额和账户后生成")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    MonoText(text: text)
                    if let m = v?.msg, v?.ok == false { Text(m).font(.footnote).foregroundStyle(Color.loss) }
                }
            }
            Section {
                Button {
                    Task { await save(text) }
                } label: {
                    HStack { Spacer(); if saving { ProgressView() } else { Text(LS("保存")).fontWeight(.semibold) }; Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.jade)
                .controlSize(.large)
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
            if let k = target.key {
                d.key = k
                d.name = person(L)?.name ?? k
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
        case .lend: return LS("借给对方或替对方垫付，记入他的个人往来。")
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
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("%@：%@", d.kind.label, d.name.isEmpty ? d.key : d.name)), single: false),
              let checked = await store.review(ops) else { return }
        dismiss()
        await store.commit(checked, checked: true)
    }
}

// MARK: - settle what is left

struct SettleSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: SettleTarget
    @State private var date = Day.today()
    @State private var to = ""
    @State private var narration = ""
    @State private var ready = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    private func form(_ L: Ledger) -> some View {
        let text = settleText(L, date: date, payee: target.payee, narration: narration.trimmed.isEmpty ? LS("结清") : narration.trimmed,
                              link: target.link, items: target.items, to: to)
        let v = text.isEmpty ? nil : validateText(text, L, single: false)
        return Form {
            Section {
                if let l = target.link { LabeledContent(LS("关联"), value: "^" + l) }
                ForEach(target.items, id: \.self) { i in
                    LabeledContent(acctLabel(i.account)) { Amount(n: i.amount, c: i.currency) }
                }
            } footer: {
                Text(LS("这些余额会清零，差额记入下面的账户。只在确定不会再补、再退时结清；还会变的留着不动即可（挂账）。"))
            }
            Section {
                DateField(value: $date)
                AccountField(label: LS("差额记入"), prefixes: ["Income:", "Expenses:", "Equity:", "Assets:"], chips: target.to, value: $to)
                TextField(LS("说明（默认「结清」）"), text: $narration)
            }
            Section(LS("将写入")) {
                if text.isEmpty { Text(LS("选择差额账户后生成")).font(.footnote).foregroundStyle(.secondary) }
                else {
                    MonoText(text: text)
                    if let m = v?.msg, v?.ok == false { Text(m).font(.footnote).foregroundStyle(Color.loss) }
                }
            }
            Section {
                Button {
                    Task { await save(text) }
                } label: {
                    HStack { Spacer(); if saving { ProgressView() } else { Text(LS("结清")).fontWeight(.semibold) }; Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.jade)
                .controlSize(.large)
                .disabled(text.isEmpty || v?.ok != true || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            to = target.to.first ?? ""
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
    @EnvironmentObject var store: Store
    let L: Ledger
    var body: some View {
        let ps = people(L)
        let emp = employerOpen(L).open.count
        let open = ps.filter { !$0.settled }
        let owed = open.filter { $0.netCNY > 0 }.reduce(0.0) { $0 + $1.netCNY }
        let owe = -open.filter { $0.netCNY < 0 }.reduce(0.0) { $0 + $1.netCNY }
        NavigationLink(value: CounterpartyDest()) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LS("个人与公司往来"))
                    Text(LS("%@ 人未结清", open.count) + (emp > 0 ? LS(" · 公司 %@ 笔", emp) : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if owed > 0.005 { Text(LS("应收 ") + money(owed)).font(.caption).monospacedDigit().sensitive() }
                    if owe > 0.005 { Text(LS("应付 ") + money(owe)).font(.caption).monospacedDigit().foregroundStyle(Color.warn).sensitive() }
                }
            }
        }
    }
}
