import SwiftUI
import LedgerKit

/// The phone's 记一笔 card with the keyboard for its keypad: the frequent entries, the category grid (or the two sides of a
/// transfer), the amount, then the paying account, the day and 更多. Every part keeps its place whatever the kind.
struct EntryCard: View {
    @Binding var draft: Draft
    let ledger: Ledger
    let derived: Derived
    let frequent: [Template]
    let subscriptionLinks: Set<String>
    let openFull: () -> Void
    let open: (EntryPanel) -> Void

    private enum Field: Hashable { case amount, payee, narration }
    private enum Chooser: Hashable { case category, funding, from, to }
    @FocusState private var field: Field?
    @State private var chooser: Chooser?
    @State private var dating = false

    /// the categories on the card before 全部
    private static let shownCategories = 7

    var body: some View {
        VStack(spacing: 10) {
            top.frame(height: 28)
            Group {
                if draft.kind == .transfer {
                    transferPanel
                } else {
                    VStack(spacing: 8) {
                        grid
                        subCategories.frame(height: 26)
                    }
                }
            }
            .frame(height: 176, alignment: .top)
            amountCard
            choices
        }
        .padding(.horizontal, 20)
        .onAppear { field = .amount }
        .onChange(of: draft.date) { dating = false }
        // leaving the payee: a known one fills in what isn't picked yet
        .onChange(of: field) { old, new in
            if old == .payee && new != .payee { draft = applyingPayee(draft, name: draft.payee.trimmed, derived, onlyBlanks: true) }
        }
    }

    // MARK: top

    /// which entry is being edited, or the frequent entries
    @ViewBuilder private var top: some View {
        if let replacing = draft.replacing {
            Label("修改：\(replacing.date) \(replacing.summary)", systemImage: "pencil")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let kind: TxKind = draft.kind == .income ? .income : .expense
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if draft.kind != .transfer {
                        ForEach(Array(frequent.filter { $0.kind == kind }.prefix(12))) { template in
                            Button { fill(template) } label: {
                                HStack(spacing: 4) {
                                    Text(template.label).lineLimit(1)
                                    if let fixed = template.fixed {
                                        Text(money(fixed, template.currency)).foregroundStyle(.secondary)
                                    }
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .foregroundStyle(template.due ? Color.warn : Color.primary)
                                .background(template.due ? Color.warn.soft : Color.card, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// a frequent entry in the form (the amount too when it is always the same)
    private func fill(_ template: Template) {
        var next = newDraft(template.kind == .income ? .income : .expense, derived, defaultFunding: nil)
        next.payee = template.payee
        next.narration = template.narration
        next.account = template.account
        next.funding = template.funding
        next.currency = template.currency
        next.amount = template.fixed.map(jsNumberString) ?? ""
        next.events = activeEvents(ledger, on: next.date).map(\.tag)
        var selection = DraftSelection()
        selection.category = !next.account.isEmpty
        selection.funding = !next.funding.isEmpty
        next.selection = selection
        draft = next
    }

    // MARK: the grid

    private var root: String { draft.kind == .income ? "Income:" : "Expenses:" }

    private var grid: some View {
        let groups = categoryGroups(derived, root: root)
        let picked = draft.account.hasPrefix(root) ? catOf(draft.account) : nil
        var shown = Array(groups.prefix(Self.shownCategories))
        if let picked, !shown.contains(where: { $0.id == picked }), let group = groups.first(where: { $0.id == picked }), !shown.isEmpty {
            shown[shown.count - 1] = group
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 6) {
            ForEach(shown) { group in
                cell(categorySymbol(group.id), categoryGroupTitle(group, ledger), selected: group.id == picked) { pick(group) }
            }
            cell("square.grid.2x2", "全部", selected: false) { chooser = .category }
                .popover(isPresented: choosing(.category), arrowEdge: .top) {
                    AccountChooser(accounts: derived.rankAccounts([root]), ledger: ledger, current: draft.account) { pickCategory($0) }
                }
        }
    }

    private func cell(_ symbol: String, _ title: String, selected: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? Color.jade : Color.card, in: Circle())
                Text(title)
                    .font(.callout)
                    .foregroundStyle(selected ? Color.jade : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// a group of one picks its account; a bigger one the account last used in it (its others are in the row below)
    private func pick(_ group: CategoryGroup) {
        if group.accounts.contains(draft.account) { return }
        let last = lastUsedInGroups(ledger, root: root)[group.id]
        pickCategory(last.flatMap { group.accounts.contains($0) ? $0 : nil } ?? group.accounts[0])
    }

    private func pickCategory(_ account: String) {
        draft.account = account
        var selection = draft.selection ?? DraftSelection()
        selection.category = true
        draft.selection = selection
    }

    private func pickFunding(_ account: String) {
        draft.funding = account
        var selection = draft.selection ?? DraftSelection()
        selection.funding = true
        draft.selection = selection
    }

    /// the picked group's other accounts
    @ViewBuilder private var subCategories: some View {
        if draft.account.hasPrefix(root), let group = categoryGroups(derived, root: root).first(where: { $0.id == catOf(draft.account) }), !group.single {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.accounts, id: \.self) { account in
                        EntryChip(title: leafTitle(account), selected: account == draft.account) { pickCategory(account) }
                    }
                }
            }
        }
    }

    private func leafTitle(_ account: String) -> String {
        if let name = ledger.accounts[account]?.meta["name"]?.stringValue, !name.isEmpty { return name }
        return leaf(account)
    }

    // MARK: 转账

    private var transferPanel: some View {
        let incoming = draft.to.isEmpty ? nil : (conversionCurrency(draft, ledger, derived) ?? draft.currency)
        let sent = evalAmount(draft.amount)
        let received = incoming == nil || incoming == draft.currency ? sent : evalAmount(draft.toAmount)
        // the fee where it changes these two balances: charged on top from 转出, or taken off what 转入 receives
        let fee = evalAmount(draft.transferFee ?? "") ?? 0
        let onTop: Double = (draft.feeMode ?? .added) == .added && (draft.feeCurrency ?? draft.currency) == draft.currency ? fee : 0
        let takenOff: Double = draft.feeMode == .deducted && (draft.feeCurrency ?? incoming) == incoming ? fee : 0
        let out = sent.map { $0 + onTop }
        let into = received.map { $0 - takenOff }
        return VStack(spacing: 8) {
            transferSide("转出", .from, account: draft.funding, currency: draft.currency, change: out.map { -$0 }, arriving: nil)
            transferSide("转入", .to, account: draft.to, currency: incoming ?? draft.currency, change: into, arriving: incoming == draft.currency ? nil : incoming)
        }
        .overlay {
            if !draft.funding.isEmpty && !draft.to.isEmpty {
                Button(action: swap) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.jade, in: Circle())
                }
                .buttonStyle(.plain)
                .help("对调")
            }
        }
    }

    private func swap() {
        var next = draft
        let outgoing = next.currency
        let incoming = conversionCurrency(next, ledger, derived) ?? outgoing
        (next.funding, next.to) = (next.to, next.funding)
        next.currency = incoming
        next.targetCurrency = outgoing
        if incoming != outgoing { (next.amount, next.toAmount) = (next.toAmount, next.amount) }
        next.fxRate = nil
        draft = next
    }

    /// one side of a transfer: the account and its balance, the balance after this transfer once there is an amount
    private func transferSide(_ label: String, _ side: Chooser, account: String, currency: String, change: Double?, arriving: String?) -> some View {
        Button { chooser = side } label: {
            HStack(spacing: 12) {
                if account.isEmpty {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.jade).frame(width: 36, height: 36)
                    Text("选择\(label)账户").foregroundStyle(Color.jade)
                } else {
                    AccountMark(account: account, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountTitle(ledger, account)).fontWeight(.medium).lineLimit(1)
                        Text(transferDetail(account, currency: currency, change: change, arriving: arriving))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !account.isEmpty { Text(label).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .frame(height: 72)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: choosing(side), arrowEdge: .top) {
            AccountChooser(accounts: derived.rankAccounts(["Assets:", "Liabilities:"]), ledger: ledger, current: account) { chosen in
                if side == .from {
                    pickFunding(chosen)
                    draft.currency = derived.acctCcy[chosen] ?? draft.currency
                } else {
                    draft.to = chosen
                }
            }
        }
    }

    /// "余额 ¥152,421 → ¥151,421", "欠款 ¥2,195 · 到账 HKD"
    private func transferDetail(_ account: String, currency: String, change: Double?, arriving: String?) -> String {
        let now = ledger.final[account]?[currency] ?? 0
        let owing = account.hasPrefix("Liabilities:")
        func show(_ value: Double) -> String { money(owing ? -value : value, currency, 0) }
        var balance = (owing ? "欠款 " : "余额 ") + show(now)
        if let change, abs(change) > 0.005 { balance += " → " + show(now + change) }
        return arriving.map { balance + " · 到账 " + $0 } ?? balance
    }

    // MARK: amount

    private var kindColor: Color {
        switch draft.kind {
        case .expense: return .loss
        case .income: return .gain
        default: return .jade
        }
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.kind == .income ? "收入金额" : draft.kind == .transfer ? "转出金额" : "支出金额")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("0.00", text: $draft.amount)
                    .textFieldStyle(.plain)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(kindColor)
                    .focused($field, equals: .amount)
                if isExpression(draft.amount) {
                    Text("= " + (evalAmount(draft.amount).map { fmtNum($0) } ?? "?"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button { open(.rate) } label: {
                    HStack(spacing: 4) {
                        Text(draft.currency).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(draft.kind == .income ? "币种与汇率" : "币种、汇率与手续费")
            }
            conversionLine.frame(height: 16)
            Divider()
            TextField("收付款方", text: $draft.payee)
                .textFieldStyle(.plain)
                .focused($field, equals: .payee)
            TextField("摘要", text: $draft.narration, prompt: Text(narrations.first ?? "摘要"))
                .textFieldStyle(.plain)
                .focused($field, equals: .narration)
            suggestions.frame(height: 24)
        }
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// the rate, the fee and who pays what, in the line kept for them
    private var conversionLine: some View {
        let other = conversionCurrency(draft, ledger, derived)
        let combo = hasCombo(draft)
        let cross = other != nil && other != draft.currency && !(draft.kind != .transfer && combo)
        var parts: [String] = []
        if cross, let other { parts.append(draftRate(draft).map { "1 \(draft.currency) = \(rateString($0)) \(other)" } ?? "填汇率…") }
        if draft.kind == .expense || draft.kind == .transfer, let fee = evalAmount(draft.transferFee ?? ""), fee > 0 {
            parts.append("手续费 " + money(fee, draft.feeCurrency ?? other ?? draft.currency))
        }
        let issue = comboIssue(draft, ledger, derived)
        if combo { parts.append(issue ?? payingSummary(draft, ledger) ?? "") }
        let warned = issue != nil || (cross && draftRate(draft) == nil)
        return Button { open(combo ? .pay : .rate) } label: {
            Text(parts.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(warned ? Color.warn : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(parts.isEmpty)
    }

    private var narrations: [String] {
        Array((derived.payee(draft.payee.trimmed)?.narrations ?? []).prefix(6))
    }

    /// who it might be while typing the payee, what it was for while typing the note
    @ViewBuilder private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
                    ForEach(narrations, id: \.self) { note in
                        EntryChip(title: note, selected: draft.narration == note) { draft.narration = note }
                    }
                }
            }
        }
    }

    // MARK: the paying account, the day and 更多 (or 标签)

    private var choices: some View {
        HStack(spacing: 0) {
            if draft.kind != .transfer {
                fundingMenu.frame(maxWidth: .infinity)
                Divider().frame(height: 22)
            }
            Button { dating = true } label: {
                Label(dayLabel(draft.date), systemImage: "calendar")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .popover(isPresented: $dating) { DayPicker(title: "日期", day: $draft.date).padding(12) }
            Divider().frame(height: 22)
            Group {
                if draft.kind == .expense {
                    expenseMore
                } else {
                    let parts = markParts
                    Button { open(.marks) } label: {
                        Label(parts.isEmpty ? "标签" : parts.joined(separator: " "), systemImage: "tag")
                            .lineLimit(1)
                            .foregroundStyle(parts.isEmpty ? Color.primary : Color.jade)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 40)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var fundingMenu: some View {
        let funds = Array(derived.rankAccounts(["Assets:", "Liabilities:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(8))
        let others = draft.kind == .expense ? draft.extraFunds.filter { !$0.account.isEmpty }.count : 0
        let title = (draft.funding.isEmpty ? (draft.kind == .income ? "收款账户" : "付款账户") : accountTitle(ledger, draft.funding)) + (others > 0 ? " + \(others)" : "")
        return Menu {
            ForEach(funds, id: \.self) { account in
                Button {
                    pickFunding(account)
                } label: {
                    if account == draft.funding { Label(accountTitle(ledger, account), systemImage: "checkmark") } else { Text(accountTitle(ledger, account)) }
                }
            }
            Divider()
            Button("更多账户…") { chooser = .funding }
            if draft.kind == .expense {
                Button("组合付款…") { open(.pay) }
            }
        } label: {
            Label(title, systemImage: draft.funding.isEmpty ? "creditcard" : accountSymbol(draft.funding))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .popover(isPresented: choosing(.funding), arrowEdge: .top) {
            AccountChooser(accounts: derived.rankAccounts(["Assets:", "Liabilities:"]), ledger: ledger, current: draft.funding) { pickFunding($0) }
        }
    }

    /// 更多 of spending: 报销, 优惠, 标签, then AA, 组合付款, 本期补差 and 填写对方 where they apply; it names what is set
    private var expenseMore: some View {
        let marks = markParts
        let discount = evalAmount(draft.discount) ?? 0
        let shown = (draft.reimb ? [reimbLabel] : []) + marks
        return Menu {
            Menu(reimbLabel) { reimbItems }
            if discountAllowed(draft) {
                Button(discount > 0 ? "优惠 " + money(discount, draft.currency) : "优惠…") { open(.pay) }
            }
            Button(marks.isEmpty ? "标签…" : marks.joined(separator: " ")) { open(.marks) }
            Divider()
            if !draft.reimb {
                Button("AA 分摊…") {
                    draft.split = true
                    openFull()
                }
            }
            Button("组合付款…") { open(.pay) }
            if subscriptionLinks.contains(draft.link.trimmed) {
                Toggle("本期补差", isOn: $draft.topup)
            }
            if isPersonal(draft.account) || isPersonal(draft.funding) {
                Button(draft.person.trimmed.isEmpty ? "填写对方…" : "对方：\(draft.person)") { openFull() }
            }
        } label: {
            Label(shown.isEmpty ? "更多" : shown.joined(separator: " "), systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
    }

    /// the entry's events, tags and 待确认 (!)
    private var markParts: [String] {
        let events = draft.kind == .transfer ? [] : ledgerEvents(ledger, today: draft.date).filter { draft.events.contains($0.tag) }.map(\.title)
        return events + draft.tags.map { "#" + $0 } + (draft.flag == "!" ? ["!"] : [])
    }

    private var reimbLabel: String {
        let label = !draft.reimb ? "报销" : isFloatLink(draft.link.trimmed) ? "报销 · 备用金" : "报销 · 垫付"
        return label + (draft.reimb && !draft.voucher.isEmpty ? " · " + draft.voucher : "")
    }

    /// 报销: off, paid from a petty cash (the newest with money left, by default), or advanced by oneself
    @ViewBuilder private var reimbItems: some View {
        let onFloat = draft.reimb && isFloatLink(draft.link.trimmed)
        Toggle("不报销", isOn: Binding(get: { !draft.reimb }, set: { _ in setReimb(false, link: isFloatLink(draft.link.trimmed) ? "" : draft.link) }))
        ForEach(derived.floats.filter { $0.left > 0.005 }) { float in
            Toggle("备用金 \(float.date)（剩 \(money(float.left, float.currency))）", isOn: Binding(get: { draft.reimb && draft.link == float.link }, set: { _ in setReimb(true, link: float.link) }))
        }
        Toggle("自己垫付", isOn: Binding(get: { draft.reimb && !onFloat }, set: { _ in setReimb(true, link: isFloatLink(draft.link.trimmed) ? "" : draft.link) }))
        if draft.reimb {
            Divider()
            Picker("凭证类型", selection: $draft.voucher) {
                Text("凭证：不填").tag("")
                ForEach(voucherKinds, id: \.self) { Text("凭证：\($0)").tag($0) }
            }
        }
    }

    private func setReimb(_ on: Bool, link: String) {
        draft.reimb = on
        draft.link = link
    }

    /// 今天, 昨天, or the day; with the year when it isn't this year's
    private func dayLabel(_ day: String) -> String {
        let today = Day.today()
        if day == today { return "今天" }
        if day == Day.shift(today, -1) { return "昨天" }
        return day.prefix(4) == today.prefix(4) ? Day.dayLabel(day) : day
    }

    private func choosing(_ what: Chooser) -> Binding<Bool> {
        Binding(get: { chooser == what }, set: { if !$0 { chooser = nil } })
    }
}
