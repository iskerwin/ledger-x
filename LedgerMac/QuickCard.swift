import SwiftUI
import LedgerKit

/// the phone's text sizes and spacing in points (`AppSpacing`, `AppRadius` in Ledger/Views/ControlStyle.swift): the card is drawn at the phone's size
private enum Size {
    static let caption2: CGFloat = 11, caption: CGFloat = 12, footnote: CGFloat = 13, subheadline: CGFloat = 15, callout: CGFloat = 16, body: CGFloat = 17
}

private enum Space {
    static let detail: CGFloat = 4, icon: CGFloat = 8, control: CGFloat = 12, content: CGFloat = 16
}

private enum Radius {
    static let panel: CGFloat = 14, control: CGFloat = 12
}

/// 记一笔's quick page, laid out for a keyboard and a mouse rather than a finger: the amount typed first, then the category (common
/// ones as chips, any one by typing a few letters) or a transfer's two accounts, the paying account, the day and 更多, who and
/// what for, and the save buttons; everything close together, Tab from one field to the next, ↩ to save.
/// 分录, 文本, AA and the like are one step in, on 完整表单
struct QuickCard: View {
    @Environment(\.categoryStyle) private var style
    @Binding var draft: Draft
    let ledger: Ledger
    let derived: Derived
    let subscriptionLinks: Set<String>
    /// the grid's order as 记一笔 opened, so cells don't move about after 保存再记
    let gridOrder: [String: [String]]
    /// the ledger's folder: a change to the category style is written there (ledger-x.json)
    let folder: URL
    let editing: Bool
    let saving: Bool
    /// why the last save didn't go through
    let message: String
    let blank: (DraftKind) -> Draft
    let setKind: (DraftKind) -> Bool
    let openFull: () -> Void
    let close: () -> Void
    let save: (_ another: Bool) -> Void
    let open: (EntryPanel) -> Void

    enum Field: Hashable { case amount, payee, narration }
    enum Pick: String, Identifiable { case funding, from, to; var id: String { rawValue } }

    @FocusState private var field: Field?
    @State private var attemptedSave = false
    /// the fields' own height and what the top and the save bar take: the window is as tall as the card, no taller
    @State private var fieldsHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0
    @State private var saveBarHeight: CGFloat = 0
    /// the hidden title bar's strip, which the card is drawn up into
    @State private var titleBarHeight: CGFloat = 0
    /// a chip's height: two rows of them are what the categories, 报销's account and a transfer's two cards each take,
    /// so the card is as tall whatever the kind
    @State private var chipHeight: CGFloat = 0
    /// goes up at each save turned back, to shake the reason
    @State private var blockedSaves = 0
    @State private var picking: Pick?
    @State private var dating = false
    /// a category group whose sub-categories are shown
    @State private var subPicking: String?
    @State private var allCategories = false
    @State private var editingText = false
    @State private var styling: CategoryStyleTarget?
    @State private var managingCategories = false
    @State private var styleMessage = ""
    private let templateList: [Template]
    private let transferList: [TransferTemplate]

    private static let kinds: [DraftKind] = [.expense, .income, .transfer]
    /// how many categories the card shows before 全部
    private static let shownCategories = 7
    private static let allCell = "__all__"

    init(draft: Binding<Draft>, ledger: Ledger, derived: Derived, subscriptionLinks: Set<String>, gridOrder: [String: [String]],
         folder: URL, templatesPinned: [String], templatesHidden: [String], editing: Bool, saving: Bool, message: String,
         blank: @escaping (DraftKind) -> Draft, setKind: @escaping (DraftKind) -> Bool, openFull: @escaping () -> Void,
         close: @escaping () -> Void, save: @escaping (Bool) -> Void, open: @escaping (EntryPanel) -> Void) {
        _draft = draft
        self.ledger = ledger
        self.derived = derived
        self.subscriptionLinks = subscriptionLinks
        self.gridOrder = gridOrder
        self.folder = folder
        self.editing = editing
        self.saving = saving
        self.message = message
        self.blank = blank
        self.setKind = setKind
        self.openFull = openFull
        self.close = close
        self.save = save
        self.open = open
        // pinned and hidden as on the phone (ledger-x.json)
        templateList = templates(ledger, pinned: templatesPinned, hidden: Set(templatesHidden))
        transferList = transferTemplates(ledger)
    }

    /// spending red, income green, a transfer the theme's
    private var kindColor: Color {
        switch draft.kind {
        case .expense: return .loss
        case .income: return .gain
        default: return .jade
        }
    }

    private var root: String { draft.kind == .income ? "Income:" : "Expenses:" }

    var body: some View {
        let d = draft
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                topStrip(d)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            // the window grows and shrinks with the fields; they scroll only where the screen has no more room
            ScrollView {
                VStack(alignment: .leading, spacing: Space.control) {
                    amountCard(d)
                    Group {
                        if d.kind == .transfer { transferPanel(d) }
                        else if d.reimb { LabeledContent(LS("报销应收科目"), value: accountTitle(ledger, derived.receivable)) }
                        else { categoryRow(d) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: twoRows)
                    details(d)
                }
                .background(alignment: .topLeading) {
                    QuickChip(label: LS("全部"), systemImage: "square.grid.2x2") {}
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipHeight = $0 }
                        .hidden()
                }
                .padding(.horizontal, Space.content)
                .padding(.vertical, Space.icon)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldsHeight = $0 }
            }
            .fittedScroll(fieldsHeight, bars: topHeight + saveBarHeight)
            saveBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { saveBarHeight = $0 }
        }
        .background(Color.page)
        // the window adds the strip on top of the card's height: taken off again, so the window ends where the card does
        .padding(.bottom, -titleBarHeight)
        // the title bar is hidden: no strip kept for it above ✕ and the kind
        .ignoresSafeArea(.container, edges: .top)
        // asked of the window, not measured here: what's measured here moves as the window is sized by it, and back again
        .background(WindowReader { titleBarHeight = $0.frame.height - $0.contentLayoutRect.height })
        // digits typed while no field has the cursor (after a click on a chip) still go to the amount
        .background(TypedKeys(enabled: true) { typed in
            // a Chinese or Japanese input method sends 。 for the point and full-width digits
            switch asciiTyped(typed) {
            case "*": key("×")
            case "/": key("÷")
            case "=": equals()
            case "\r", "\u{3}": isExpression(draft.amount) ? equals() : submit(close: true)
            case "\u{7F}": key("⌫")
            default:
                let typed = asciiTyped(typed)
                guard typed.count == 1, "0123456789.+-×÷".contains(typed) else { return false }
                key(typed)
            }
            return true
        })
        // the cursor starts in the amount (a field can only be focused once it is on screen)
        .onAppear { DispatchQueue.main.async { if field == nil { field = .amount } } }
        .onChange(of: field) { old, new in
            // leaving the payee or the note: a known one fills in what isn't picked yet
            if old == .payee && new != .payee { applyPayee(draft.payee.trimmed, onlyBlanks: true) }
            if old == .narration && new != .narration { applyNarration(draft.narration.trimmed, onlyBlanks: true) }
        }
        .sheet(item: $picking) { accountChooser($0) }
        .sheet(item: $styling) {
            CategoryStyleEditor(group: $0.group, ledger: ledger, folder: folder).environment(\.categoryStyle, style)
        }
        .sheet(isPresented: $managingCategories) {
            CategoryStyleManager(ledger: ledger, derived: derived, folder: folder, root: root).environment(\.categoryStyle, style)
        }
        .alert(styleMessage, isPresented: Binding(get: { !styleMessage.isEmpty }, set: { if !$0 { styleMessage = "" } })) {}
        .sheet(isPresented: $allCategories) { allCategoriesSheet }
        .sheet(isPresented: $editingText) {
            SourceSheet(initial: draftText(draft, ledger, derived), ledger: ledger, single: draftIsSingle(draft, ledger)) { applySource($0) }
        }
    }

    // MARK: top

    /// ✕, the kind, ⋯: the kind switch stays centred
    private var topBar: some View {
        HStack {
            Button(action: close) { barIcon("xmark") }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(LS("关闭"))
            Spacer()
            Picker(LS("类型"), selection: Binding(get: { Self.kinds.contains(draft.kind) ? draft.kind : .expense }, set: { _ = setKind($0) })) {
                ForEach(Self.kinds) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 186)
            Spacer()
            moreMenu
        }
        .padding(.horizontal, Space.content)
        .padding(.top, Space.control)
        .padding(.bottom, Space.icon)
    }

    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(Color.card, in: Circle())
            .contentShape(Circle())
    }

    private var moreMenu: some View {
        Menu {
            Button(LS("完整表单"), systemImage: "list.bullet.rectangle") { openFull() }
            Button(LS("分类图标与排序…"), systemImage: "square.grid.2x2") { managingCategories = true }
            Button(LS("分录（多行）"), systemImage: "list.number") { if setKind(.multi) { openFull() } }
            Button(LS("文本（Beancount 指令）"), systemImage: "text.alignleft") { if setKind(.raw) { openFull() } }
            Button(draft.edited != nil ? LS("源文本（已手动编辑）") : LS("源文本"), systemImage: "chevron.left.forwardslash.chevron.right") { editingText = true }
            if draft.edited != nil {
                Button(LS("恢复自动生成"), systemImage: "arrow.counterclockwise") { draft.edited = nil }
            }
            if draft.kind == .income && (isPersonal(draft.account) || isPersonal(draft.funding)) {
                personButton(draft)
            }
        } label: {
            barIcon("ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(LS("更多"))
    }

    /// above the grid: which entry is being edited, or the frequent entries
    @ViewBuilder
    private func topStrip(_ d: Draft) -> some View {
        if let r = d.replacing {
            Label(LS("修改：%@ %@", r.date, r.summary), systemImage: "pencil")
                .font(.system(size: Size.footnote))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.content)
                .frame(height: Self.stripHeight)
                .padding(.top, Space.icon)
        } else {
            templateCapsules(d.kind)
        }
    }

    // MARK: 常用交易

    /// the frequent entries as small capsules (an orange one: a subscription not recorded this month); click to fill the card.
    /// The row keeps its height with none to show, so the amount stays where it is as the kind changes
    private func templateCapsules(_ kind: DraftKind) -> some View {
        let list = kind == .transfer ? [] : Array(templateList.filter { $0.kind == (kind == .income ? .income : .expense) }.prefix(12))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.icon) {
                if kind == .transfer {
                    ForEach(transferList.prefix(12)) { x in
                        capsule(accountTitle(ledger, x.from) + " → " + accountTitle(ledger, x.to), amount: x.fixed.map { money($0, x.currency) }) {
                            fillTransfer(x)
                        }
                    }
                } else {
                    ForEach(list) { x in
                        capsule(x.label, amount: x.fixed.map { money($0, x.currency) }, due: x.due) { fillTemplate(x) }
                    }
                }
            }
            .padding(.horizontal, Space.content)
        }
        .frame(height: Self.stripHeight)
        .padding(.top, Space.icon)
    }

    private static let stripHeight: CGFloat = 32

    private func capsule(_ label: String, amount: String?, due: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.detail) {
                Text(label).lineLimit(1)
                if let amount { Text(amount).foregroundStyle(.secondary) }
            }
            .font(.system(size: Size.footnote))
            .padding(Space.icon)
            .foregroundStyle(due ? Color.warn : Color.primary)
            .background(due ? Color.warn.soft : Color.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fillTransfer(_ x: TransferTemplate) {
        var d = blank(.transfer)
        d.payee = x.payee
        d.narration = x.narration
        d.funding = x.from
        d.to = x.to
        d.currency = x.currency
        d.amount = x.fixed.map { jsNumberString($0) } ?? ""
        var selection = DraftSelection()
        selection.funding = true
        d.selection = selection
        draft = d
    }

    private func fillTemplate(_ x: Template) {
        var d = blank(x.kind == .income ? .income : .expense)
        d.payee = x.payee
        d.narration = x.narration
        d.account = x.account
        d.funding = x.funding
        d.currency = x.currency
        d.amount = x.fixed.map { jsNumberString($0) } ?? ""
        var selection = DraftSelection()
        selection.category = !d.account.isEmpty
        selection.funding = !d.funding.isEmpty
        d.selection = selection
        draft = d
    }

    // MARK: the grid

    /// the groups under `root` in the order they had as the card opened, the hidden ones left out (they are in 全部)
    private func gridGroups(_ root: String) -> [CategoryGroup] {
        let hidden = Set(style.hidden)
        return orderedGroups(categoryGroups(derived, root: root), saved: gridOrder[root] ?? []).filter { !hidden.contains($0.id) }
    }

    /// two rows of chips, once a chip has been measured
    private var twoRows: CGFloat? { chipHeight == 0 ? nil : chipHeight * 2 + Space.icon }

    /// the first `count` in the grid's order, the picked one put in the last place when it isn't among them
    private func shownGroups(_ groups: [CategoryGroup], picked: String?, count: Int) -> [CategoryGroup] {
        var top = Array(groups.prefix(count))
        if let p = picked, !top.contains(where: { $0.id == p }), let g = groups.first(where: { $0.id == p }), !top.isEmpty {
            top[top.count - 1] = g
        }
        return top
    }

    /// the common categories as chips and 全部, which has the rest and the search
    @ViewBuilder
    private func categoryRow(_ d: Draft) -> some View {
        let groups = gridGroups(root)
        let picked = d.account.hasPrefix(root) ? catOf(d.account) : nil
        if groups.isEmpty {
            Text(LS("账本里还没有%@科目，可在「账户」里新建。", d.kind == .income ? "收入" : "支出"))
                .font(.system(size: Size.footnote))
                .foregroundStyle(.secondary)
        } else {
            // two rows, never more: as many of the common ones as they hold, 全部 always there
            ViewThatFits(in: .vertical) {
                ForEach((0...Self.shownCategories).reversed(), id: \.self) { n in
                    categoryChips(d, groups: groups, picked: picked, count: n)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// `count` common categories and 全部. The picked one reads 餐饮 › 午餐; clicked again it opens its sub-categories
    private func categoryChips(_ d: Draft, groups: [CategoryGroup], picked: String?, count: Int) -> some View {
        FlowLayout(spacing: Space.icon) {
            ForEach(shownGroups(groups, picked: picked, count: count)) { g in
                let title = categoryTitle(g, ledger, style) + (g.id == picked && !g.single ? " › " + leafTitle(ledger, d.account) : "")
                QuickChip(label: title, systemImage: categorySymbol(g.id, style), selected: g.id == picked) {
                    // the picked group again: its sub-categories
                    if g.id == picked && !g.single { subPicking = g.id } else { pick(g) }
                }
                // under the chip, as tall as its sub-categories
                .popover(isPresented: Binding(get: { subPicking == g.id }, set: { if !$0 { subPicking = nil } }), arrowEdge: .bottom) {
                    SubCategoryList(group: g, ledger: ledger, current: d.account) { pickCategory($0); subPicking = nil }
                }
                .contextMenu {
                    if !g.single { Button(LS("选择子类"), systemImage: "list.bullet") { pick(g); subPicking = g.id } }
                    Button(LS("更换图标与名称…"), systemImage: "paintpalette") { styling = CategoryStyleTarget(group: g) }
                    Button(LS("从常用分类隐藏"), systemImage: "eye.slash") {
                        let id = g.id
                        do { try saveCategoryStyle(folder: folder, LS("从宫格隐藏：%@", categoryTitle(g, ledger, style))) { $0.setHidden(id, true) } }
                        catch { styleMessage = error.localizedDescription }
                    }
                    Divider()
                    Button(LS("分类图标与排序…"), systemImage: "square.grid.2x2") { managingCategories = true }
                }
            }
            QuickChip(label: LS("全部"), systemImage: "square.grid.2x2") { field = nil; allCategories = true }
        }
    }

    /// a group of one picks its account; a bigger one the account last used in it (click again for the others)
    private func pick(_ g: CategoryGroup) {
        let current = draft.account
        let account: String
        if g.single { account = g.accounts[0] }
        else if catOf(current) == g.id && g.accounts.contains(current) { account = current }
        else if let last = lastUsedInGroups(ledger, root: root)[g.id], g.accounts.contains(last) { account = last }
        else { account = g.accounts[0] }
        pickCategory(account)
    }

    private func pickCategory(_ account: String) {
        draft.account = account
        draft.edited = nil
        var selection = draft.selection ?? DraftSelection()
        selection.category = true
        draft.selection = selection
    }

    private var allCategoriesSheet: some View {
        let groups = gridGroups(root)
        return AllCategoriesSheet(groups: groups, common: Array(groups.prefix(Self.shownCategories)),
                                  current: draft.account.hasPrefix(root) ? draft.account : nil, ledger: ledger) { pickCategory($0) }
    }

    // MARK: 转账

    /// 转出 and 转入 as two account cards, 对调 between them
    private func transferPanel(_ d: Draft) -> some View {
        let incoming = d.to.isEmpty ? nil : (conversionCurrency(d, ledger, derived) ?? d.currency)
        let sent = evalAmount(d.amount)
        let received = incoming == nil || incoming == d.currency ? sent : evalAmount(d.toAmount)
        // the fee where it changes these two balances: charged on top from 转出, or taken off what 转入 receives
        let fee = evalAmount(d.transferFee ?? "") ?? 0
        let out = sent.map { $0 + (d.feeMode == .added && (d.feeCurrency ?? d.currency) == d.currency ? fee : 0) }
        let into = received.map { $0 - (d.feeMode == .deducted && (d.feeCurrency ?? incoming) == incoming ? fee : 0) }
        // side by side, 对调 between: as tall as two rows of categories, whatever is picked
        return VStack(alignment: .trailing, spacing: Space.detail) {
            HStack(spacing: Space.icon) {
                transferCard(LS("转出"), d.funding, currency: d.currency, change: out.map { -$0 }, arriving: nil) { picking = .from }
                Button(action: swapTransfer) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: Size.footnote, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.jade, in: Circle())
                }
                .buttonStyle(.plain)
                .help(LS("对调"))
                .disabled(d.funding.isEmpty || d.to.isEmpty)
                .opacity(d.funding.isEmpty || d.to.isEmpty ? 0.3 : 1)
                transferCard(LS("转入"), d.to, currency: incoming ?? d.currency, change: into, arriving: incoming == d.currency ? nil : incoming) { picking = .to }
            }
            // the same account, another currency: 换汇 within it
            if !d.funding.isEmpty && d.funding == d.to, let c = incoming {
                Text(LS("同账户换汇 %@ → %@", d.currency, c)).font(.system(size: Size.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private func swapTransfer() {
        var x = draft
        let outgoing = x.currency
        let incoming = conversionCurrency(x, ledger, derived) ?? outgoing
        (x.funding, x.to) = (x.to, x.funding)
        x.currency = incoming
        x.targetCurrency = outgoing
        if incoming != outgoing { (x.amount, x.toAmount) = (x.toAmount, x.amount) }
        x.fxRate = nil
        x.edited = nil
        draft = x
    }

    /// one side of a transfer: the account's icon and name, its balance, the balance after this transfer once there is an amount;
    /// a dashed card before one is chosen
    private func transferCard(_ label: String, _ a: String, currency: String, change: Double?, arriving: String?, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: Space.control) {
                if a.isEmpty {
                    Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(Color.jade).frame(width: 36, height: 36)
                    Text(label == LS("转出") ? LS("选择转出账户") : LS("选择转入账户")).foregroundStyle(Color.jade)
                    Spacer()
                } else {
                    let look = accountLook(a)
                    Image(systemName: look.symbol)
                        .font(.system(size: Size.body, weight: .semibold))
                        .foregroundStyle(look.color)
                        .frame(width: 36, height: 36)
                        .background(look.color.soft, in: Circle())
                    VStack(alignment: .leading, spacing: Space.detail) {
                        Text(accountTitle(ledger, a)).font(.system(size: Size.body, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                        Text(transferDetail(a, currency: currency, change: change, arriving: arriving))
                            .font(.system(size: Size.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.right").font(.system(size: Size.caption)).foregroundStyle(.tertiary)
            }
            .font(.system(size: Size.body))
            .padding(.horizontal, Space.control)
            .padding(.vertical, Space.icon)
            .frame(maxHeight: .infinity)
            .background {
                if a.isEmpty {
                    RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Color.jade.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                } else {
                    RoundedRectangle(cornerRadius: Radius.panel).fill(Color.card)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "余额 ¥152,421 → ¥151,421", "欠款 ¥2,195 · 到账 HKD"
    private func transferDetail(_ a: String, currency: String, change: Double?, arriving: String?) -> String {
        let now = ledger.final[a]?[currency] ?? 0
        let owing = a.hasPrefix("Liabilities:")
        func show(_ v: Double) -> String { money(owing ? -v : v, currency, 0) }
        var balance = (owing ? LS("欠款 ") : LS("余额 ")) + show(now)
        if let c = change, abs(c) > 0.005 { balance += " → " + show(now + c) }
        return ([balance] + (arriving.map { [LS("到账 ") + $0] } ?? [])).joined(separator: " · ")
    }

    private func accountLook(_ a: String) -> (symbol: String, color: Color) {
        let parts = a.components(separatedBy: ":")
        return AccountGroup.look(parts.count > 1 ? parts[1] : a)
    }

    private func accountChooser(_ p: Pick) -> some View {
        let d = draft
        let prefixes = ["Assets:", "Liabilities:"]
        return Group {
            switch p {
            case .funding:
                AccountChooser(title: d.kind == .income ? LS("收款账户") : LS("付款账户"), prefixes: prefixes, ledger: ledger, derived: derived, current: d.funding) { a in
                    draft.funding = a
                    draft.edited = nil
                    pickedFunding()
                }
            case .from:
                AccountChooser(title: LS("转出"), prefixes: prefixes, ledger: ledger, derived: derived, current: d.funding) { a in
                    pickedFunding()
                    draft.funding = a
                    draft.currency = derived.acctCcy[a] ?? draft.currency
                    draft.edited = nil
                }
            case .to:
                AccountChooser(title: LS("转入"), prefixes: prefixes, ledger: ledger, derived: derived, current: d.to,
                               hints: d.funding.isEmpty ? [:] : [d.funding: LS("同账户换汇")]) { a in
                    draft.to = a
                    draft.edited = nil
                }
            }
        }
    }

    private func pickedFunding() {
        var selection = draft.selection ?? DraftSelection()
        selection.funding = true
        draft.selection = selection
    }

    // MARK: account, day, 更多

    /// one row in equal parts: the paying account (not for a transfer), the day, then 更多 for spending or 标签 for income and transfers
    private func choices(_ d: Draft) -> some View {
        HStack(spacing: 0) {
            if d.kind != .transfer {
                fundingMenu(d).frame(maxWidth: .infinity)
                Divider().frame(height: 26)
            }
            Button { dating = true } label: { cell(dayLabel(d.date), icon: "calendar", on: false) }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .popover(isPresented: $dating) {
                    DayChooser(day: Binding(get: { draft.date }, set: { draft.date = $0; draft.edited = nil })) { dating = false }
                }
            Divider().frame(height: 26)
            Group {
                if d.kind == .expense { expenseMore(d) } else { markChip(d) }
            }
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: Size.subheadline))
    }

    private func fundingMenu(_ d: Draft) -> some View {
        let funds = Array(derived.rankAccounts(["Assets:", "Liabilities:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(8))
        let others = d.kind == .expense ? d.extraFunds.filter { !$0.account.isEmpty }.count : 0
        let title = (d.funding.isEmpty ? (d.kind == .income ? LS("收款账户") : LS("付款账户")) : accountTitle(ledger, d.funding)) + (others > 0 ? " + \(others)" : "")
        let look = d.funding.isEmpty ? (symbol: "creditcard", color: Color.jade) : accountLook(d.funding)
        return Menu {
            ForEach(funds, id: \.self) { a in
                Button {
                    draft.funding = a
                    draft.edited = nil
                    pickedFunding()
                } label: {
                    if a == d.funding { Label(accountTitle(ledger, a), systemImage: "checkmark") } else { Text(accountTitle(ledger, a)) }
                }
            }
            Divider()
            Button(LS("更多账户…"), systemImage: "building.columns") { picking = .funding }
            if d.kind == .expense {
                Button(LS("组合付款…"), systemImage: "square.split.2x1") { open(.pay) }
            }
        } label: {
            HStack(spacing: Space.icon) {
                CellIcon(symbol: look.symbol).foregroundStyle(look.color)
                Text(title).foregroundStyle(d.funding.isEmpty ? Color.secondary : Color.primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.system(size: Size.caption2, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(Space.control)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// 更多 of spending: 报销, 优惠, 标签, then AA, 组合付款, 本期补差 and 填写对方 where they apply; it names what is set
    private func expenseMore(_ d: Draft) -> some View {
        let marks = markParts(d)
        let topup = subscriptionLinks.contains(d.link.trimmed)
        let person = isPersonal(d.account) || isPersonal(d.funding)
        let discount = evalAmount(d.discount) ?? 0
        let shown = (d.reimb ? [reimbLabel(d)] : []) + marks
        let on = d.reimb || !marks.isEmpty || discount > 0 || d.topup || hasCombo(d) || !d.person.trimmed.isEmpty
        return Menu {
            Menu { reimbItems(d) } label: { Label(reimbLabel(d), systemImage: d.reimb ? "checkmark.circle.fill" : "doc.text") }
            if discountAllowed(d) {
                Button(discount > 0 ? LS("优惠 ") + money(discount, d.currency) : LS("优惠…"), systemImage: "gift") { open(.pay) }
            }
            Button(marks.isEmpty ? LS("标签…") : marks.joined(separator: " "), systemImage: "tag") { open(.marks) }
            Divider()
            if !d.reimb {
                Button(LS("AA 分摊…"), systemImage: "person.2") {
                    draft.split = true
                    draft.edited = nil
                    openFull()
                }
            }
            Button(LS("组合付款…"), systemImage: "square.split.2x1") { open(.pay) }
            if topup {
                Button(LS("本期补差"), systemImage: d.topup ? "checkmark" : "plus.forwardslash.minus") {
                    draft.topup.toggle()
                    draft.edited = nil
                }
            }
            if person { personButton(d) }
        } label: {
            cell(shown.isEmpty ? LS("更多") : shown.joined(separator: " "), icon: "ellipsis.circle", on: on)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// 填写对方: in spending's 更多, and in the ⋯ menu for income
    private func personButton(_ d: Draft) -> some View {
        Button(d.person.trimmed.isEmpty ? LS("填写对方…") : LS("对方：") + d.person, systemImage: "person") { openFull() }
    }

    /// one part of the row: an icon, its text, and a chevron; in the theme's colour when something is set
    private func cell(_ text: String, icon: String, on: Bool) -> some View {
        HStack(spacing: Space.icon) {
            CellIcon(symbol: icon).foregroundStyle(on ? Color.jade : Color.secondary)
            Text(text).foregroundStyle(on ? Color.jade : Color.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.system(size: Size.caption2, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(Space.control)
        .contentShape(Rectangle())
    }

    /// the entry's events, tags and 待确认 (!)
    private func markParts(_ d: Draft) -> [String] {
        let events = d.kind == .transfer ? [] : ledgerEvents(ledger, today: d.date).filter { d.events.contains($0.tag) }.map(\.title)
        return events + d.tags.map { "#" + $0 } + (d.flag == "!" ? ["!"] : [])
    }

    /// 标签 of income and transfers: the cell says what is set
    private func markChip(_ d: Draft) -> some View {
        let parts = markParts(d)
        return Button { open(.marks) } label: {
            cell(parts.isEmpty ? LS("标签") : parts.joined(separator: " "), icon: "tag", on: !parts.isEmpty)
        }
        .buttonStyle(.plain)
    }

    private func reimbLabel(_ d: Draft) -> String {
        let onFloat = d.reimb && isFloatLink(d.link.trimmed)
        let label = !d.reimb ? LS("报销") : onFloat ? LS("报销 · 备用金") : LS("报销 · 垫付")
        return label + (d.reimb && !d.voucher.isEmpty ? " · " + d.voucher : "")
    }

    /// 报销: off, paid from a petty cash (with money left), or advanced by oneself
    @ViewBuilder
    private func reimbItems(_ d: Draft) -> some View {
        let floats = derived.floats.filter { $0.left > 0.005 }
        let onFloat = d.reimb && isFloatLink(d.link.trimmed)
        let set = { (on: Bool, link: String) in
            draft.reimb = on
            draft.link = link
            draft.edited = nil
        }
        Button { set(false, isFloatLink(d.link.trimmed) ? "" : d.link) } label: {
            if !d.reimb { Label(LS("不报销"), systemImage: "checkmark") } else { Text(LS("不报销")) }
        }
        ForEach(floats) { f in
            Button { set(true, f.link) } label: {
                let title = LS("备用金 %@（剩 %@）", f.date, money(f.left, f.currency))
                if d.reimb && d.link == f.link { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
        }
        Button { set(true, isFloatLink(d.link.trimmed) ? "" : d.link) } label: {
            if d.reimb && !onFloat { Label(LS("自己垫付"), systemImage: "checkmark") } else { Text(LS("自己垫付")) }
        }
        if d.reimb {
            Divider()
            Picker(LS("凭证类型"), selection: Binding(get: { draft.voucher }, set: { draft.voucher = $0; draft.edited = nil })) {
                Text(LS("凭证：不填")).tag("")
                ForEach(voucherKinds, id: \.self) { Text(LS("凭证：") + $0).tag($0) }
            }
        }
    }

    // MARK: amount

    private func amountCard(_ d: Draft) -> some View {
        let other = conversionCurrency(d, ledger, derived)
        let cross = other != nil && other != d.currency && !(d.kind != .transfer && hasCombo(d))
        return VStack(alignment: .leading, spacing: Space.icon) {
            Text(d.kind == .income ? LS("收入金额") : d.kind == .transfer ? LS("转出金额") : LS("支出金额"))
                .font(.system(size: Size.caption))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: Space.icon) {
                Text(SYM[d.currency] ?? "").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(kindColor)
                // typed straight in; ↩ works out a sum, then saves
                TextField("0.00", text: Binding(get: { draft.amount }, set: { setAmount(typedAmount($0)) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(kindColor)
                    .focused($field, equals: .amount)
                    .onSubmit { isExpression(draft.amount) ? equals() : submit(close: true) }
                if isExpression(d.amount) {
                    Text("= " + (evalAmount(d.amount).map { fmtNum($0) } ?? "?"))
                        .font(.system(size: Size.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                // the currency, and the rate when the account is in another one
                Button { open(.rate) } label: {
                    HStack(spacing: Space.detail) {
                        Text(d.currency).font(.system(size: Size.subheadline, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: Size.caption2, weight: .bold))
                    }
                    .padding(.horizontal, Space.control)
                    .padding(.vertical, Space.icon)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(d.kind == .expense || d.kind == .transfer ? LS("币种、汇率与手续费") : LS("币种与汇率"))
            }
            if cross, let o = other {
                Button { open(.rate) } label: {
                    Label(draftRate(d).map { "1 \(d.currency) = \(rateString($0)) \(o)" } ?? LS("填汇率…"), systemImage: "arrow.left.arrow.right")
                        .font(.system(size: Size.footnote))
                        .foregroundStyle(draftRate(d) == nil ? Color.warn : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            if d.kind == .expense || d.kind == .transfer, let fee = evalAmount(d.transferFee ?? ""), fee > 0 {
                Button { open(.rate) } label: {
                    Label(LS("手续费 ") + money(fee, d.feeCurrency ?? other ?? d.currency), systemImage: "percent")
                        .font(.system(size: Size.footnote))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let summary = payingSummary(d, ledger) {
                let issue = comboIssue(d, ledger, derived)
                Label(issue ?? summary, systemImage: issue == nil ? "square.split.2x1" : "exclamationmark.triangle")
                    .font(.system(size: Size.footnote))
                    .foregroundStyle(issue == nil ? Color.secondary : Color.warn)
                    .lineLimit(2)
                    .onTapGesture { open(.pay) }
            }
            if let reason {
                Button { if let issue = shownIssue { locate(issue) } } label: {
                    Label(reason, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: Size.footnote))
                        .foregroundStyle(Color.loss)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .modifier(Shake(trigger: blockedSaves))
            }
        }
        .padding(Space.control)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
    }

    /// what is in the way, once a save was tried
    private var shownIssue: DraftIssue? {
        attemptedSave && draft.edited == nil ? draftIssue(draft, ledger, derived) : nil
    }

    private var reason: String? {
        shownIssue?.message ?? (message.isEmpty ? nil : message)
    }

    /// 今天, 昨天, or the day ("10月14日"; with the year when it isn't this year's)
    private func dayLabel(_ day: String) -> String {
        let today = Day.today()
        if day == today { return LS("今天") }
        if day == Day.shift(today, -1) { return LS("昨天") }
        let m = Int(day.dropFirst(5).prefix(2)) ?? 0, dd = Int(day.suffix(2)) ?? 0
        return day.prefix(4) == today.prefix(4) ? LS("%@月%@日", m, dd) : day
    }

    /// one card, rows divided by lines: account | day | 更多, then who, then what for; what was used before drops down as it is typed in
    /// ↩ in the note saves
    private func details(_ d: Draft) -> some View {
        let notes = narrationSuggestions(derived, typed: "", payee: d.payee, limit: 1)
        let typedPayee = d.payee.trimmed
        return VStack(spacing: 0) {
            choices(d)
            Divider()
            TextField(LS("收付款方"), text: Binding(get: { draft.payee }, set: { updateText(\.payee, $0) }), prompt: Text(LS("如 便利店、淘宝，可不填")))
                .textFieldStyle(.plain)
                .padding(Space.control)
                .focused($field, equals: .payee)
                .suggesting(Array(derived.payees.lazy.filter { typedPayee.isEmpty || fuzzy(typedPayee, $0.name) > 0 }.prefix(8).map(\.name)), closed: derived.payee(typedPayee) != nil)
                .onSubmit { applyPayee(draft.payee.trimmed, onlyBlanks: false); field = .narration }
            Divider()
            TextField(LS("摘要"), text: Binding(get: { draft.narration }, set: { updateText(\.narration, $0) }),
                      prompt: Text(notes.first.map { LS("如 %@，可不填", $0) } ?? LS("买了什么、做什么用，可不填")))
                .textFieldStyle(.plain)
                .padding(Space.control)
                .focused($field, equals: .narration)
                .suggesting(narrationSuggestions(derived, typed: d.narration, payee: d.payee, limit: 8), closed: derived.narration(d.narration.trimmed) != nil)
                .onSubmit { submit(close: true) }
        }
        .font(.system(size: Size.subheadline))
        .background(Color.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func updateText(_ key: WritableKeyPath<Draft, String>, _ value: String) {
        var next = draft
        next[keyPath: key] = value
        next.edited = nil
        guard next != draft else { return }
        draft = next
    }

    /// a payee picked by hand (or typed and left) fills in its usual category and account; ones picked here stay
    private func applyPayee(_ name: String, onlyBlanks: Bool) {
        guard !name.isEmpty, derived.payee(name) != nil else { return }
        draft = applyingPayee(draft, name: name, derived, onlyBlanks: onlyBlanks)
    }

    /// a note picked (or typed and left) fills in as a payee does
    private func applyNarration(_ text: String, onlyBlanks: Bool) {
        guard !text.isEmpty, text != draft.narration || onlyBlanks else { return }
        draft = applyingNarration(draft, text: text, derived, onlyBlanks: onlyBlanks)
    }

    /// 源文本 saved: the form keeps what it can read of it, the text is saved as written
    private func applySource(_ text: String) {
        var current = draft
        current.edited = text
        if case .success(var converted) = convertingEditor(current, to: current.kind, ledger: ledger, derived: derived) {
            converted.edited = text
            draft = converted
        } else {
            draft = current
        }
    }

    // MARK: saving

    /// 保存再记 (源文本 when editing) and 保存, at the bottom right; ↩ in the amount or the note saves, ⇧⌘↩ saves and starts another
    private var saveBar: some View {
        HStack(spacing: Space.control) {
            Spacer()
            if editing {
                Button(LS("源文本"), systemImage: "chevron.left.forwardslash.chevron.right") { editingText = true }
                    .controlSize(.large)
            } else {
                Button(LS("保存再记")) { submit(close: false) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .controlSize(.large)
            }
            // ↩ is each field's own (a default button would fire as well and save twice); with no field, TypedKeys takes it
            Button(LS("保存")) { isExpression(draft.amount) ? equals() : submit(close: true) }
                .buttonStyle(.borderedProminent)
                .tint(Color.jade)
                .controlSize(.large)
                .disabled(saving)
        }
        .padding(.horizontal, Space.content)
        .padding(.vertical, Space.control)
        .background(Color.page)
    }

    /// what the amount field keeps of what is typed: digits, one point a number and the four signs (* and / as × and ÷)
    private func typedAmount(_ text: String) -> String {
        asciiTyped(text).replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")
            .filter { "0123456789.+-×÷".contains($0) }
    }

    private func setAmount(_ a: String) {
        draft.amount = a
        draft.edited = nil
    }

    /// typing with no field focused: one decimal point and two decimals per number, no leading zeros, one operator in a row
    private func key(_ k: String) {
        var a = draft.amount
        let ops: Set<Character> = ["+", "-", "×", "÷"]
        let current = String(a.split(omittingEmptySubsequences: false, whereSeparator: { ops.contains($0) }).last ?? "")
        switch k {
        case "⌫":
            if !a.isEmpty { a.removeLast() }
        case "+", "-", "×", "÷":
            guard let l = a.last else { return }
            if ops.contains(l) { a.removeLast() }
            if a.isEmpty { return }
            if a.last == "." { a.removeLast() }
            a.append(Character(k))
        case ".":
            if current.contains(".") { return }
            a += current.isEmpty ? "0." : "."
        default:
            if let dot = current.firstIndex(of: "."), current[dot...].count > 2 { return }
            if current.filter({ $0.isNumber }).count >= 10 { return }
            if current == "0" { a.removeLast() }
            a += k
        }
        setAmount(a)
    }

    private func equals() {
        guard let v = evalAmount(draft.amount) else { return }
        setAmount(v > 0 ? jsNumberString(roundTo(v, 2)) : "")
    }

    private func locate(_ issue: DraftIssue) {
        field = nil
        switch issue.field {
        case .category: allCategories = true
        case .funding: picking = draft.kind == .transfer ? .from : .funding
        case .to: picking = .to
        case .rate, .paid, .toAmount, .fee: open(.rate)
        case .combined: open(.pay)
        case .date: dating = true
        default: break
        }
    }

    private func submit(close: Bool) {
        guard !saving else { return }
        if isExpression(draft.amount) { equals() }
        attemptedSave = true
        if draft.edited == nil, let issue = draftIssue(draft, ledger, derived) {
            blockedSaves += 1
            locate(issue)
            return
        }
        field = nil
        save(!close)
    }
}

// MARK: - pieces of the card

/// a sub-category's own name: its display name, or the last part of the account
private func leafTitle(_ ledger: Ledger, _ a: String) -> String {
    if let name = ledger.accounts[a]?.meta["name"]?.stringValue, !name.isEmpty { return name }
    return a.components(separatedBy: ":").last ?? a
}

/// an icon in a fixed square: a taller symbol doesn't make its row taller
private struct CellIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .frame(width: 20, height: 20)
    }
}

/// children left to right, wrapping onto the next row when the width is used up
/// (SwiftUI has no wrapping stack; a custom `Layout` is the native way)
private struct FlowLayout: Layout {
    var spacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, used: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + spacing
            used = max(used, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return (frames, CGSize(width: used, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: bounds.width)
        for (v, f) in zip(subviews, laid.frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

/// a capsule choice, the phone's `Chip`
private struct QuickChip: View {
    let label: String
    var systemImage: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage, label.isEmpty { Image(systemName: systemImage) }
                else if let systemImage { Label(label, systemImage: systemImage) } else { Text(label) }
            }
            .font(.system(size: Size.subheadline))
            .lineLimit(1)
            .padding(.horizontal, Space.control)
            .padding(.vertical, Space.icon)
            .background(selected ? Color.jade : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// one cell of the category grid: its symbol on a circle, the theme's colour when picked, a dot badge when it has sub-categories
private struct CategoryCell: View {
    let icon: String
    let title: String
    let single: Bool
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: Space.icon) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .frame(width: 54, height: 54)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? Color.jade : Color.card, in: Circle())
                    if !single {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.secondary, in: Circle())
                            .overlay(Circle().stroke(Color.page, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
                Text(title)
                    .font(.system(size: Size.footnote, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.jade : Color.secondary)
                    // a long name on two lines rather than shrunk
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
    }
}

/// a short side-to-side shake each time `trigger` goes up: a save that was turned back points at why
private struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Effect: GeometryEffect {
        var travel: CGFloat
        var animatableData: CGFloat {
            get { travel }
            set { travel = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: 6 * sin(travel * .pi * 4), y: 0))
        }
    }

    func body(content: Content) -> some View {
        content.modifier(Effect(travel: reduceMotion ? 0 : CGFloat(trigger)))
            .animation(reduceMotion ? nil : .linear(duration: 0.4), value: trigger)
    }
}

/// the entry's day: 今天, 昨天, 前天 one click away, any other on the calendar
private struct DayChooser: View {
    @Binding var day: String
    let done: () -> Void

    var body: some View {
        let today = Day.today()
        VStack(spacing: Space.control) {
            HStack(spacing: Space.icon) {
                ForEach([(LS("今天"), today), (LS("昨天"), Day.shift(today, -1)), (LS("前天"), Day.shift(today, -2))], id: \.1) { quick in
                    QuickChip(label: quick.0, systemImage: "calendar", selected: day == quick.1) {
                        day = quick.1
                        done()
                    }
                }
            }
            DayPicker(title: LS("日期"), day: Binding(get: { day }, set: { day = $0; done() }))
        }
        .padding(Space.control)
    }
}

/// a sheet's title between 取消 and 完成
private struct SheetBar: View {
    let title: String
    var done: (() -> Void)?
    var canFinish = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            if let done {
                Button(LS("完成"), action: done).keyboardShortcut(.defaultAction).disabled(!canFinish)
            }
        }
        .padding(Space.content)
    }
}

/// an account to pay from or move money between, the most used first, searchable
private struct AccountChooser: View {
    let title: String
    let prefixes: [String]
    let ledger: Ledger
    let derived: Derived
    let current: String
    var hints: [String: String] = [:]
    let pick: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let typed = query.trimmed
        let accounts = derived.rankAccounts(prefixes).filter { typed.isEmpty || fuzzy(typed, accountTitle(ledger, $0)) > 0 || fuzzy(typed, $0) > 0 }
        VStack(spacing: 0) {
            SheetBar(title: title)
            TextField(LS("搜索账户"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Space.content)
            List(accounts, id: \.self) { a in
                Button {
                    pick(a)
                    dismiss()
                } label: {
                    let parts = a.components(separatedBy: ":")
                    let look = AccountGroup.look(parts.count > 1 ? parts[1] : a)
                    HStack(spacing: Space.control) {
                        Image(systemName: look.symbol)
                            .foregroundStyle(look.color)
                            .frame(width: 30, height: 30)
                            .background(look.color.soft, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accountTitle(ledger, a))
                            Text(a).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let hint = hints[a] { Text(hint).font(.caption).foregroundStyle(.secondary) }
                        if a == current { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 420, height: 520)
    }
}

/// a group's sub-categories in a popover under its chip: one click picks it and closes; a long list scrolls
private struct SubCategoryList: View {
    let group: CategoryGroup
    let ledger: Ledger
    let current: String
    let pick: (String) -> Void

    var body: some View {
        if group.accounts.count > 12 {
            ScrollView { rows }.frame(height: 12 * 28 + Space.icon * 2)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.accounts, id: \.self) { a in
                Button { pick(a) } label: {
                    HStack(spacing: Space.control) {
                        Text(accountTitle(ledger, a))
                        Spacer(minLength: Space.content)
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.jade).opacity(a == current ? 1 : 0)
                    }
                    .frame(height: 28)
                    .padding(.horizontal, Space.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 180)
        .padding(.vertical, Space.icon)
    }
}

/// 全部分类: every group, searchable, its sub-categories below; the choice goes back to the card
private struct AllCategoriesSheet: View {
    let groups: [CategoryGroup]
    let common: [CategoryGroup]
    /// the account picked on the card
    let current: String?
    let ledger: Ledger
    let use: (String) -> Void
    @State private var query = ""
    /// the group whose sub-categories are shown under the grid
    @State private var group: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.categoryStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(title: LS("全部分类"))
            TextField(LS("搜索分类"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Space.content)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.control) {
                    if query.trimmed.isEmpty {
                        Text(LS("常用分类")).font(.system(size: Size.footnote)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.control) { ForEach(common) { cell($0).frame(width: 64) } }
                        }
                        Divider()
                        Text(LS("所有分类")).font(.system(size: Size.footnote)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.icon, alignment: .top), count: 4), spacing: Space.control) {
                            ForEach(groups) { cell($0) }
                        }
                    } else {
                        let hits = matches()
                        if hits.isEmpty { Text(LS("没有找到「%@」", query.trimmed)).foregroundStyle(.secondary).padding(.top, Space.content) }
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            let (g, a) = hit
                            Button { finish(a) } label: {
                                HStack(spacing: Space.icon) {
                                    Image(systemName: categorySymbol(g.id, style))
                                        .frame(width: 30, height: 30)
                                        .background(Color.secondary.opacity(0.12), in: Circle())
                                    VStack(alignment: .leading, spacing: Space.detail) {
                                        Text(categoryTitle(g, ledger, style) + (g.single ? "" : " › " + leafTitle(ledger, a)))
                                        Text(a).font(.system(size: Size.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if a == current { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .padding(Space.content)
            }
            if let id = group, let g = groups.first(where: { $0.id == id }), !g.single { picker(g) }
        }
        .frame(width: 420, height: 640)
        .background(Color.page)
        .onAppear {
            if let current { group = catOf(current) }
        }
    }

    /// a group of one is picked at once; a bigger one shows its sub-categories below
    private func cell(_ g: CategoryGroup) -> some View {
        CategoryCell(icon: categorySymbol(g.id, style), title: categoryTitle(g, ledger, style), single: true, selected: group == g.id) {
            if g.single { finish(g.accounts[0]) } else { group = g.id }
        }
    }

    private func finish(_ account: String) {
        use(account)
        dismiss()
    }

    /// the shown group's sub-categories: one click picks it and closes
    private func picker(_ g: CategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.icon) {
            Text(categoryTitle(g, ledger, style)).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.icon) {
                    ForEach(g.accounts, id: \.self) { a in QuickChip(label: leafTitle(ledger, a), selected: current == a) { finish(a) } }
                }
            }
        }
        .padding(Space.content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func matches() -> [(CategoryGroup, String)] { categoryMatches(groups, query.trimmed, ledger, style) }
}

/// the categories a search finds: (group, account), in the groups' order; by the group's name, the sub-category's or the account's
private func categoryMatches(_ groups: [CategoryGroup], _ query: String, _ ledger: Ledger, _ style: CategoryStyle) -> [(CategoryGroup, String)] {
    let q = query.lowercased()
    var out: [(CategoryGroup, String)] = []
    for g in groups {
        let name = categoryTitle(g, ledger, style).lowercased()
        for a in g.accounts {
            let names = [name, leafTitle(ledger, a).lowercased(), a.lowercased(), acctDisplay(a).lowercased()]
            if names.contains(where: { $0.contains(q) }) { out.append((g, a)) }
        }
    }
    return out
}

/// 源文本: the entry's Beancount text, checked before it is kept; saved as written
private struct SourceSheet: View {
    let initial: String
    let ledger: Ledger
    let single: Bool
    let apply: (String) -> Void
    @State private var text = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(title: LS("编辑源文本"), done: finish)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Space.icon)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.control))
                .padding(.horizontal, Space.content)
            Text(problem ?? " ")
                .font(.callout)
                .foregroundStyle(Color.loss)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, Space.content)
        }
        .frame(width: 560, height: 420)
        .background(Color.page)
        .onAppear { text = initial }
    }

    private func finish() {
        let checked = validateText(text, ledger, single: single)
        guard checked.ok else {
            problem = checked.msg ?? LS("这段文本无法保存")
            return
        }
        apply(text)
        dismiss()
    }
}
