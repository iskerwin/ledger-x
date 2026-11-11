import SwiftUI
import LedgerKit

/// 表单: the amount first, then the day, currency, accounts and category in two columns; what most entries don't need folds away.
/// 分录 and 文本 fill the same place
struct EntryForm: View {
    @Binding var draft: Draft
    let ledger: Ledger
    let derived: Derived
    let subscriptionLinks: Set<String>
    let open: (EntryPanel) -> Void
    @State private var addingPerson = false
    @State private var newPerson = ""
    @State private var more: Bool
    @State private var showsText = false
    @FocusState private var field: Field?
    @FocusState private var textFocused: Bool

    private enum Field: Hashable { case amount, payee, narration }

    init(draft: Binding<Draft>, ledger: Ledger, derived: Derived, subscriptionLinks: Set<String>, open: @escaping (EntryPanel) -> Void) {
        _draft = draft
        self.ledger = ledger
        self.derived = derived
        self.subscriptionLinks = subscriptionLinks
        self.open = open
        let held = draft.wrappedValue
        _more = State(initialValue: held.reimb || held.split || hasCombo(held) || held.topup || !held.tags.isEmpty || held.flag == "!")
    }

    var body: some View {
        let text = draftText(draft, ledger, derived)
        Form {
            switch draft.kind {
            case .multi:
                multiSections
            case .raw:
                Section {
                    TextEditor(text: $draft.raw)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .frame(minHeight: 340)
                        .overlay(alignment: .topLeading) {
                            if draft.raw.isEmpty {
                                Text("\(Day.today()) price USD 7.10 CNY")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onAppear { textFocused = true }
                }
            default:
                amountSection
                detailSection
                payeeSection
                moreSections
            }
            if draft.kind != .raw && !text.trimmed.isEmpty {
                Section {
                    DisclosureGroup("Beancount 原文", isExpanded: $showsText) {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity)
        .onAppear { if draft.kind != .multi && draft.kind != .raw { field = .amount } }
        // leaving the payee or the note: a known one fills in what isn't picked yet
        .onChange(of: field) { old, new in
            if old == .payee && new != .payee { draft = applyingPayee(draft, name: draft.payee.trimmed, derived, onlyBlanks: true) }
            if old == .narration && new != .narration, !draft.narration.trimmed.isEmpty {
                draft = applyingNarration(draft, text: draft.narration.trimmed, derived, onlyBlanks: true)
            }
        }
        // new AA parts follow the amount until typed by hand
        .onChange(of: draft.amount) {
            if draft.split && !draft.sharesEdited { spreadShares() }
        }
    }

    private var currencies: [String] {
        Array(Set(derived.currencies + [draft.currency])).sorted()
    }

    // MARK: 金额

    private var amountSection: some View {
        Section {
            VStack(spacing: 2) {
                TextField("金额", text: $draft.amount, prompt: Text("0.00"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .focused($field, equals: .amount)
                // its line is always there, so typing a sum moves nothing
                Text(isExpression(draft.amount) ? "= " + (evalAmount(draft.amount).map { fmtNum($0) } ?? "?") : " ")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 日期、币种、账户与科目

    @ViewBuilder private var detailSection: some View {
        let categoryRoot = draft.kind == .income ? "Income:" : "Expenses:"
        let fundingTitle = draft.kind == .income ? "收款账户" : draft.kind == .refund ? "退回账户" : "付款账户"
        let other = conversionCurrency(draft, ledger, derived)
        Section {
            HStack(alignment: .top, spacing: 16) {
                FieldColumn(title: "日期") { DateRow(title: "日期", day: $draft.date).labelsHidden() }
                FieldColumn(title: "币种") {
                    Picker("币种", selection: $draft.currency) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            if draft.kind == .transfer {
                HStack(alignment: .top, spacing: 16) {
                    FieldColumn(title: "转出账户") {
                        AccountField(title: "转出账户", prefixes: ["Assets:", "Liabilities:"], derived: derived, account: Binding(get: { draft.funding }, set: { account in
                            draft.funding = account
                            draft.selection = picked(funding: true)
                            draft.currency = derived.acctCcy[account] ?? draft.currency
                        }))
                        .labelsHidden()
                    }
                    FieldColumn(title: "转入账户") {
                        AccountField(title: "转入账户", prefixes: ["Assets:", "Liabilities:"], derived: derived, account: $draft.to).labelsHidden()
                    }
                }
                if !draft.to.isEmpty, let other, other != draft.currency {
                    LabeledContent("入账金额 " + other) {
                        TextField("入账金额", text: $draft.toAmount, prompt: Text("实际入账金额"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    FieldColumn(title: fundingTitle) {
                        AccountField(title: fundingTitle, prefixes: ["Assets:", "Liabilities:"], derived: derived, account: Binding(get: { draft.funding }, set: { account in
                            draft.funding = account
                            draft.selection = picked(funding: true)
                        })).labelsHidden()
                    }
                    FieldColumn(title: "分类") {
                        AccountField(title: "分类", prefixes: [categoryRoot], derived: derived, account: Binding(get: { draft.account }, set: { account in
                            draft.account = account
                            draft.selection = picked(category: true)
                        })).labelsHidden()
                    }
                }
                if isPersonal(draft.account) || isPersonal(draft.funding) {
                    TextField("对方", text: $draft.person)
                }
                if let other, other != draft.currency, !hasCombo(draft) {
                    conversion(other)
                }
            }
            if draft.kind == .expense || draft.kind == .transfer {
                LabeledContent("币种、汇率与手续费") {
                    Button(feeSummary) { open(.rate) }
                }
            }
        }
    }

    private var feeSummary: String {
        guard let fee = evalAmount(draft.transferFee ?? ""), fee > 0 else { return "设置…" }
        return "手续费 " + money(fee, draft.feeCurrency ?? draft.currency)
    }

    // MARK: 收付款方

    private var payeeSection: some View {
        Section {
            FieldColumn(title: "收付款方") {
                TextField("收付款方", text: $draft.payee)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($field, equals: .payee)
            }
            FieldColumn(title: "摘要") {
                TextField("摘要", text: $draft.narration, prompt: Text(narrationSuggestions(derived, typed: "", payee: draft.payee, limit: 1).first ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($field, equals: .narration)
            }
            // its line is always there, so moving between the fields moves nothing
            suggestions.frame(height: 24)
        }
    }

    /// picked by hand in this entry: a payee or a note picked after leaves it as it is
    private func picked(category: Bool = false, funding: Bool = false) -> DraftSelection {
        var selection = draft.selection ?? DraftSelection()
        if category { selection.category = true }
        if funding { selection.funding = true }
        return selection
    }

    /// who it might be while typing the payee, what it was for while typing the note
    private var suggestions: some View {
        ChipRow {
            if field == .payee {
                let typed = draft.payee.trimmed
                let known = derived.payees.filter { typed.isEmpty || $0.name.localizedCaseInsensitiveContains(typed) }.prefix(6)
                if !(known.count == 1 && known.first?.name == typed) {
                    ForEach(Array(known), id: \.name) { payee in
                        EntryChip(title: payee.name, selected: false) {
                            draft = applyingPayee(draft, name: payee.name, derived)
                            field = .narration
                        }
                    }
                }
            } else if field == .narration {
                ForEach(narrationSuggestions(derived, typed: draft.narration, payee: draft.payee, limit: 6), id: \.self) { note in
                    EntryChip(title: note, selected: draft.narration == note) {
                        if draft.narration != note { draft = applyingNarration(draft, text: note, derived) }
                    }
                }
            }
        }
    }

    // MARK: 更多

    @ViewBuilder private var moreSections: some View {
        if draft.kind == .refund { refundSection }
        Section {
            DisclosureGroup("更多选项", isExpanded: $more) {
                if draft.kind == .expense {
                    LabeledContent("组合付款与优惠") {
                        Button(comboIssue(draft, ledger, derived) ?? payingSummary(draft, ledger) ?? "未使用") { open(.pay) }
                            .lineLimit(1)
                    }
                }
                marksRow
            }
        }
        if more && draft.kind == .expense { expenseSections }
    }

    /// as the receipt has it: the amount charged, or the rate
    @ViewBuilder private func conversion(_ other: String) -> some View {
        Picker("换算", selection: $draft.byRate) {
            Text("填实付金额").tag(false)
            Text("填汇率").tag(true)
        }
        .pickerStyle(.segmented)
        if draft.byRate {
            LabeledContent("1 \(draft.currency) =") {
                HStack {
                    TextField("汇率", text: $draft.rate)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text(other).foregroundStyle(.secondary)
                }
            }
            if let rate = Double(draft.rate.trimmed), let amount = evalAmount(draft.amount) {
                LabeledContent("实付 " + other, value: money(roundTo(amount * rate, 2), other))
            }
        } else {
            LabeledContent("实付 " + other) {
                TextField("实付", text: $draft.paid, prompt: Text("账户实际扣款"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
            if let paid = evalAmount(draft.paid), let amount = evalAmount(draft.amount), amount > 0 {
                LabeledContent("汇率", value: "1 \(draft.currency) = \(toFixed(paid / amount, 5)) \(other)")
            }
        }
    }

    // MARK: 报销、AA、补差

    @ViewBuilder private var expenseSections: some View {
        if subscriptionLinks.contains(draft.link.trimmed) {
            Section {
                Toggle("本期补差", isOn: $draft.topup)
            }
        }
        reimbSection
        if !draft.reimb { splitSection }
    }

    private var reimbSection: some View {
        let links = Array(derived.openLinks.filter { $0.link.hasPrefix("reimburse") }.suffix(4))
        let floats = derived.floats.filter { $0.left > 0.005 }
        let onFloat = isFloatLink(draft.link.trimmed)
        return Section {
            Toggle("可报销", isOn: Binding(get: { draft.reimb }, set: { on in
                draft.reimb = on
                // the newest petty cash with money left pays it, unless a link was already given
                if on && draft.link.trimmed.isEmpty, let float = floats.last { draft.link = float.link }
                if !on && isFloatLink(draft.link.trimmed) { draft.link = "" }
            }))
            if draft.reimb {
                if !floats.isEmpty {
                    ChipRow {
                        ForEach(floats) { float in
                            EntryChip(title: "备用金 \(float.date)（剩 \(money(float.left, float.currency))）", selected: draft.link == float.link) { draft.link = float.link }
                        }
                        EntryChip(title: "自己垫付", selected: !onFloat) { if onFloat { draft.link = "" } }
                    }
                }
                Picker("凭证类型", selection: $draft.voucher) {
                    Text("不填").tag("")
                    ForEach(voucherKinds, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                if !onFloat {
                    TextField("关联", text: $draft.link, prompt: Text("reimburse-…"))
                    if !links.isEmpty {
                        ChipRow {
                            ForEach(links, id: \.link) { open in
                                EntryChip(title: open.link, selected: draft.link == open.link) { draft.link = open.link }
                            }
                        }
                    }
                }
            }
        }
    }

    /// split the expense with people: their parts go to the personal receivable, yours to the category
    private var splitSection: some View {
        let known = people(ledger).filter { !$0.closed && !$0.unnamed }
        let total = evalAmount(draft.amount) ?? 0
        let theirs = draft.shares.reduce(0.0) { $0 + (evalAmount($1.amount) ?? 0) }
        return Section {
            Toggle("AA 分摊", isOn: Binding(get: { draft.split }, set: { on in
                draft.split = on
                if !on {
                    draft.shares = []
                    draft.sharesEdited = false
                }
            }))
            if draft.split {
                ChipRow {
                    ForEach(known) { person in
                        EntryChip(title: person.name, selected: draft.shares.contains { $0.person == person.name }) { toggleShare(person.name) }
                    }
                    EntryChip(title: "＋ 其他人", selected: addingPerson) { addingPerson.toggle() }
                }
                if addingPerson {
                    HStack {
                        TextField("称呼", text: $newPerson).onSubmit(addPerson)
                        Button("加入", action: addPerson).disabled(newPerson.trimmed.isEmpty)
                    }
                }
                ForEach($draft.shares) { $share in
                    LabeledContent(share.person) {
                        TextField(share.person, text: Binding(get: { share.amount }, set: {
                            share.amount = $0
                            draft.sharesEdited = true
                        }), prompt: Text("0.00"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 120)
                    }
                }
                if !draft.shares.isEmpty {
                    LabeledContent("我的份额") {
                        Text(money(total - theirs, draft.currency))
                            .monospacedDigit()
                            .foregroundStyle(total - theirs < -0.004 ? Color.loss : Color.primary)
                    }
                    if draft.sharesEdited {
                        Button("重新平均分摊", action: spreadShares)
                    }
                }
            }
        }
    }

    /// someone typed in: the same name as someone in 往来 is that person
    private func addPerson() {
        let name = newPerson.trimmed
        guard !name.isEmpty else { return }
        if !draft.shares.contains(where: { $0.person == name }) { toggleShare(name) }
        newPerson = ""
        addingPerson = false
    }

    private func toggleShare(_ name: String) {
        if let index = draft.shares.firstIndex(where: { $0.person == name }) {
            draft.shares.remove(at: index)
        } else {
            draft.shares.append(Share(person: name))
        }
        if !draft.sharesEdited { spreadShares() }
    }

    /// everyone, you included, pays the same; you take the odd cents
    private func spreadShares() {
        var next = draft
        let each = evenShares(evalAmount(next.amount) ?? 0, next.shares.count)
        for index in next.shares.indices { next.shares[index].amount = index < each.count ? toFixed(each[index], 2) : "" }
        next.sharesEdited = false
        draft = next
    }

    private var refundSection: some View {
        Section {
            if let fee = draft.refundFee {
                Toggle("同时退回手续费 \(money(fee.amount, fee.currency))", isOn: Binding(get: { draft.refundFee?.on ?? false }, set: { draft.refundFee?.on = $0 }))
            }
            TextField("关联", text: $draft.link, prompt: Text("refund-…"))
        }
    }

    // MARK: 事件、标签

    private var marksRow: some View {
        let events = draft.kind == .transfer ? [] : ledgerEvents(ledger, today: draft.date).filter { draft.events.contains($0.tag) }.map(\.title)
        let parts = events + draft.tags.map { "#" + $0 } + (draft.flag == "!" ? ["!"] : [])
        return LabeledContent("事件与标签") {
            Button(parts.isEmpty ? "添加…" : parts.joined(separator: " ")) { open(.marks) }
                .lineLimit(1)
        }
    }

    // MARK: 分录

    @ViewBuilder private var multiSections: some View {
        Section {
            DateRow(title: "日期", day: $draft.date)
            TextField("收付款方", text: $draft.payee)
                .focused($field, equals: .payee)
            TextField("摘要", text: $draft.narration)
            TextField("标签与链接", text: $draft.tagsText, prompt: Text("#标签 ^链接"))
            Toggle("待确认（!）", isOn: Binding(get: { draft.flag == "!" }, set: { draft.flag = $0 ? "!" : "*" }))
        }
        Section("分录") {
            ForEach($draft.rows) { $row in
                RowEditor(row: $row, derived: derived, ledger: ledger) {
                    let id = row.id
                    draft.rows.removeAll { $0.id == id }
                }
            }
            Button("添加分录行", systemImage: "plus.circle") { draft.rows.append(DraftRow()) }
        }
    }
}

/// a field with its name above it, taking its share of the row
private struct FieldColumn<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// one line of 分录: the account, the amount (a blank one balances the rest), its currency, 待确认; cost and price under it
private struct RowEditor: View {
    @Binding var row: DraftRow
    let derived: Derived
    let ledger: Ledger
    let remove: () -> Void
    @State private var more = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AccountField(title: "账户", prefixes: ["Assets:", "Liabilities:", "Expenses:", "Income:", "Equity:"], derived: derived, account: Binding(get: { row.account }, set: { account in
                    row.account = account
                    if !row.ccyTouched, let currency = derived.acctCcy[account] { row.currency = currency }
                }))
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("!") { row.flag = row.flag == "!" ? "" : "!" }
                    .foregroundStyle(row.flag == "!" ? Color.warn : Color.secondary)
                    .help("标记为待确认（!）")
                Button("删除", systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("±") {
                    let amount = row.amount.trimmed
                    row.amount = amount.hasPrefix("-") ? String(amount.dropFirst()) : "-" + amount
                }
                TextField("金额", text: $row.amount, prompt: Text("自动补平"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Picker("币种", selection: Binding(get: { row.currency }, set: {
                    row.currency = $0
                    row.ccyTouched = true
                })) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("成本与价格", systemImage: showsMore ? "chevron.up.circle.fill" : "ellipsis.circle") { more.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.jade)
            }
            if showsMore {
                HStack {
                    TextField("成本", text: $row.cost, prompt: Text("成本 {180 USD}"))
                    TextField("价格", text: $row.price, prompt: Text("价格 @ 7.1 CNY"))
                }
            }
            if isPersonal(row.account) {
                TextField("对方", text: $row.person)
            }
        }
    }

    private var showsMore: Bool { more || !row.cost.isEmpty || !row.price.isEmpty }

    private var currencies: [String] {
        var all = derived.currencies
        for currency in ledger.commodities.keys.sorted() where !all.contains(currency) { all.append(currency) }
        if !all.contains(row.currency) { all.append(row.currency) }
        return all
    }
}
