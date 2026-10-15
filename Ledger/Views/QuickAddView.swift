import SwiftUI
import LedgerKit

/// the pages of the 记一笔 card past the quick one
enum AddRoute: Hashable { case full }

/// 记一笔 as a card over any tab: the quick page first, 完整表单 one step in
struct AddCard: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    /// 1 while the full form is the card's own first page (opened for 分录, 退款…), so popping keeps it
    @State private var base = 0

    var body: some View {
        NavigationStack(path: $path) {
            QuickAddView { path.append(AddRoute.full) }
                .navigationDestination(for: AddRoute.self) { _ in AddForm { store.adding = false } }
                .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0).privacyToolbar() }
                .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
                .subscriptionDestinations()
        }
        .overlay(alignment: .top) { ToastView(top: true).padding(.top, 6).animation(.spring(duration: 0.3), value: store.toast) }
        .sheet(item: $store.subSuggestion) { c in SubEditSheet(draft: SubDraft(c)) }
        .onAppear(perform: route)
        .onChange(of: store.addToken) { _, _ in route() }
        // after an edit or delete on a page opened from here: back to the form
        .onChange(of: store.popToken) { _, _ in if path.count > base { path.removeLast(path.count - base) } }
        .onChange(of: path.count) { _, n in if n < base { base = n } }
    }

    /// the page asked for: the quick one, or the full form on top of it
    private func route() {
        var p = NavigationPath()
        if store.addFull { p.append(AddRoute.full) }
        base = p.count
        path = p
    }
}

/// The quick page, laid out so nothing moves while recording: the kind and ledger on top, the frequent entries as
/// capsules, the category grid in a fixed area of its own, then the choices, the amount and the keypad. Typing the
/// payee and description swaps the keypad for the text fields; the keypad comes back with 完成.
/// What it can't show (分录, 文本, AA, 源文本) is one step in, on 完整表单, from the ⚙︎ menu.
struct QuickAddView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    let openFull: () -> Void

    enum Field: Hashable { case payee, narration }
    @FocusState private var field: Field?
    @State private var editingText = false
    @State private var picking: Pick?
    @State private var styling: StyleTarget?
    @State private var renaming: CategoryGroup?
    @State private var newTitle = ""
    @State private var managingCats = false
    @State private var managingTemplates = false
    @State private var importing = false
    @State private var saving = false
    /// 组合付款与优惠
    @State private var splittingPay = false
    /// the currency and rate sheet
    @State private var rating = false
    /// 标记: tags, events, 待确认
    @State private var marking = false
    /// the date's calendar
    @State private var dating = false
    /// a category group whose sub-categories are shown
    @State private var subPicking: String?
    /// the category / paying account were picked here: a payee picked afterwards doesn't change them
    @State private var pickedCategory = false
    @State private var pickedFunding = false

    enum Pick: String, Identifiable { case funding, from, to; var id: String { rawValue } }

    var body: some View {
        Group {
            if let L = store.L, let D = store.D { content(L, D) } else { ProgressView() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.demoEnv["LEDGER_IMPORT"] != nil { importing = true } }
        .task { if store.demoEnv["LEDGER_CATS"] != nil { managingCats = true } }
        .task { if store.demoEnv["LEDGER_COMBO_SHEET"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); splittingPay = true } }
        .task { if store.demoEnv["LEDGER_NOTE"] != nil { try? await Task.sleep(nanoseconds: 900_000_000); field = .narration } }
        .task { if store.demoEnv["LEDGER_MARK"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); marking = true } }
        .task { if store.demoEnv["LEDGER_SUBCAT"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); subPicking = catOf(store.draft.account) } }
    }

    private static let kinds: [DraftKind] = [.expense, .income, .transfer]

    /// the amount and 完成 in the kind's colour: spending red, income green (the app's usual pair), else the theme's
    private var kindColor: Color {
        switch store.draft.kind {
        case .expense: return Color.loss
        case .income: return Color.gain
        default: return Color.jade
        }
    }

    @ViewBuilder
    private func content(_ L: Ledger, _ D: Derived) -> some View {
        let d = store.draft
        let quick = Self.kinds.contains(d.kind) && !d.split
        VStack(spacing: 0) {
            if !quick {
                ScrollView { fullBanner(d).padding(16) }
            } else {
                topStrip(d)
                // the grid keeps its own area and scrolls in it: what is below never moves
                ScrollView {
                    Group {
                        if d.kind == .transfer { transferPanel(d, L, D) } else { grid(d, L, D) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: .infinity)
                bottomPanel(d, L, D)
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { store.adding = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(LS("关闭"))
            }
            ToolbarItem(placement: .principal) {
                Picker(LS("类型"), selection: Binding(get: { Self.kinds.contains(store.draft.kind) ? store.draft.kind : .expense },
                                                     set: { k in store.setKind(k); pickedCategory = false })) {
                    ForEach(Self.kinds) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.segmented)
                .frame(width: 186)
                .disabled(!quick)
            }
            ToolbarItem(placement: .primaryAction) { ledgerMenu }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(LS("完成")) { field = nil }.fontWeight(.semibold)
            }
        }
        .onAppear {
            store.freezeGridOrder("Expenses:", D)
            store.freezeGridOrder("Income:", D)
        }
        // new entries follow the events of their day until picked by hand
        .onChange(of: d.date) { _, day in
            if !store.draft.eventsTouched && store.draft.kind != .transfer { store.draft.events = store.autoEvents(on: day); store.draft.edited = nil }
        }
        .onChange(of: field) { old, new in
            // leaving the payee: a known one fills in what isn't picked yet
            if old == .payee && new != .payee { applyPayee(store.draft.payee.trimmed, onlyBlanks: true) }
        }
        .sheet(item: $picking) { p in accountPicker(p) }
        .sheet(item: $styling) { CategoryStyleSheet(target: $0) }
        .sheet(isPresented: $managingCats) { CategoryManager(root: Store.categoryRoot(store.draft.kind)) }
        .sheet(isPresented: $managingTemplates) { TemplateManager() }
        .sheet(isPresented: $splittingPay) { PaySplitSheet() }
        .sheet(isPresented: $rating) { RateSheet(L: L, D: D) }
        .sheet(isPresented: $marking) { MarkSheet(L: L).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $importing) { ImportView() }
        .sheet(isPresented: $editingText) {
            TextEditSheet(title: LS("编辑源文本"), initial: draftText(store.draft, L, D, explicit: store.explicitAmounts),
                          validate: { t in validateText(t, L, single: draftIsSingle(store.draft, L)) }) { new in
                store.draft.edited = new
            }
        }
        .alert(LS("分类名称"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map { store.catTitle($0, L) } ?? "", text: $newTitle)
            Button(LS("保存")) {
                if let g = renaming { store.catStyle.titles[g.id] = newTitle.trimmed.isEmpty ? nil : newTitle.trimmed }
                renaming = nil
            }
            Button(LS("取消"), role: .cancel) { renaming = nil }
        } message: {
            Text(LS("只改本机宫格里显示的名字，账本里的科目不变；留空恢复默认。"))
        }
    }

    // MARK: top

    /// the ledger this goes into; with more than one set up, tap to switch
    @ViewBuilder
    private var ledgerMenu: some View {
        let name = store.cfg.title
        if store.sources.count > 1 {
            Menu {
                ForEach(store.sources) { s in
                    Button {
                        guard s.id != store.cfg.id else { return }
                        Task {
                            await store.switchLedger(s.id)
                            // accounts belong to a ledger: start over in the new one
                            store.draft = store.newDraftFor(Self.kinds.contains(store.draft.kind) ? store.draft.kind : .expense)
                        }
                    } label: {
                        if s.id == store.cfg.id { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            } label: {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1).frame(maxWidth: 96)
            }
            .accessibilityLabel(LS("切换账本"))
        } else {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.jade).lineLimit(1).frame(maxWidth: 96)
        }
    }

    /// above the grid: which entry is being edited, what a screenshot gave, or the frequent entries
    @ViewBuilder
    private func topStrip(_ d: Draft) -> some View {
        if let r = d.replacing {
            editingBanner(r).padding(.horizontal, 16).padding(.top, 6)
        } else if let s = store.scanInfo {
            ScanBanner(info: s).padding(.horizontal, 12).padding(.top, 6)
        } else {
            templateCapsules(d.kind)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { openFull() } label: { Label(LS("完整表单"), systemImage: "list.bullet.rectangle") }
            Button { store.setKind(.multi); openFull() } label: { Label(LS("分录（多行）"), systemImage: "list.number") }
            Button { store.setKind(.raw); openFull() } label: { Label(LS("文本（Beancount 指令）"), systemImage: "text.alignleft") }
            Button { field = nil; editingText = true } label: {
                Label(store.draft.edited != nil ? LS("源文本（已手动编辑）") : LS("源文本"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            if store.draft.edited != nil {
                Button { store.draft.edited = nil } label: { Label(LS("恢复自动生成"), systemImage: "arrow.counterclockwise") }
            }
            if store.draft.replacing == nil {
                Divider()
                Button { importing = true } label: { Label(LS("导入账单"), systemImage: "square.and.arrow.down.on.square") }
            }
            Divider()
            Button { managingCats = true } label: { Label(LS("分类图标与排序"), systemImage: "square.grid.3x3") }
            Button { managingTemplates = true } label: { Label(LS("常用交易"), systemImage: "star") }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17))
                .frame(width: 36, height: 34)
                .foregroundStyle(Color.secondary)
        }
        .accessibilityLabel(LS("更多"))
    }

    private func editingBanner(_ r: Replacing) -> some View {
        Label(LS("修改：%@ %@", r.date, r.summary), systemImage: "pencil")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分录 / 文本 / 退款 / AA are edited on the full form
    private func fullBanner(_ d: Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(d.split ? LS("这笔是 AA 分摊") : LS("这笔是「%@」", d.kind.label), systemImage: "list.bullet.rectangle")
                .font(.headline)
            Text(LS("这类交易在完整表单里填写。")).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button(LS("继续填写")) { openFull() }.buttonStyle(.borderedProminent).tint(.jade)
                Button(LS("改为普通支出")) {
                    var x = store.draft
                    x.split = false; x.shares = []; x.sharesEdited = false; x.refundOf = nil
                    store.draft = x
                    store.setKind(.expense)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 常用交易

    /// the frequent entries as small capsules (an orange one: a subscription not recorded this month); tap to fill the
    /// form, long press to record one with a fixed amount at once
    @ViewBuilder
    private func templateCapsules(_ kind: DraftKind) -> some View {
        let list = kind == .transfer ? [] : Array(store.templateList.filter { $0.kind == (kind == .income ? .income : .expense) }.prefix(12))
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(list) { x in
                        Button {
                            store.fillTemplate(x)
                            pickedCategory = true; pickedFunding = true
                        } label: {
                            HStack(spacing: 4) {
                                if x.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                                Text(x.label).lineLimit(1)
                                if let f = x.fixed { Text(money(f, x.currency)).foregroundStyle(.secondary).sensitive() }
                            }
                            .font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(x.due ? Color.orange : Color.primary)
                            .background(x.due ? Color.orange.opacity(0.14) : Color(.secondarySystemGroupedBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if x.fixed != nil {
                                Button {
                                    guard !saving else { return }
                                    saving = true
                                    Task { await store.saveTemplateNow(x); saving = false }
                                } label: { Label(LS("直接入账：%@", x.label), systemImage: "checkmark.circle") }
                            }
                            Button { managingTemplates = true } label: { Label(LS("常用交易"), systemImage: "star") }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 6)
        }
    }

    // MARK: the grid

    @ViewBuilder
    private func grid(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let root = Store.categoryRoot(d.kind)
        let groups = store.gridGroups(root, D)
        let picked = d.account.hasPrefix(root) ? catOf(d.account) : nil
        let cells = groups.map { g in
            GridCell(id: g.id, icon: store.catIcon(Store.cellKey(g)),
                     title: g.id == picked && !g.single ? accountTitle(L, d.account) : store.catTitle(g, L), single: g.single)
        }
        if groups.isEmpty {
            Text(LS("账本里还没有%@科目，可在「账户」里新建。", d.kind == .income ? LS("收入") : LS("支出")))
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            CategoryGridView(cells: cells, picked: picked, tap: { id in
                guard let g = groups.first(where: { $0.id == id }) else { return }
                // the picked group again: its sub-categories
                if id == picked && !g.single { subPicking = id } else { pick(g, L) }
            }, menu: { id in
                guard let g = groups.first(where: { $0.id == id }) else { return }
                return AnyView(Group {
                    if !g.single { Button { pick(g, L); subPicking = id } label: { Label(LS("选择子类"), systemImage: "list.bullet") } }
                    Button { styling = StyleTarget(group: g) } label: { Label(LS("更换图标"), systemImage: "photo") }
                    Button { newTitle = store.catStyle.titles[g.id] ?? ""; renaming = g } label: { Label(LS("改名"), systemImage: "pencil") }
                    Button(role: .destructive) { store.catStyle.hidden.append(g.id) } label: { Label(LS("从宫格隐藏"), systemImage: "eye.slash") }
                })
            })
            .equatable()
            .sheet(item: Binding(get: { subPicking.flatMap { id in groups.first { $0.id == id } } }, set: { if $0 == nil { subPicking = nil } })) { g in
                SubCategorySheet(group: g, title: store.catTitle(g, L), L: L, current: store.draft.account) { a in
                    store.draft.account = a
                    store.draft.edited = nil
                    pickedCategory = true
                    subPicking = nil
                }
                .presentationDetents([.height(min(120 + CGFloat(g.accounts.count) * 46, 460))])
            }
        }
    }

    /// a group of one picks its account; a bigger one the account last used in it (tap again for the others)
    private func pick(_ g: CategoryGroup, _ L: Ledger) {
        let cur = store.draft.account
        let root = Store.categoryRoot(store.draft.kind)
        let a: String
        if g.single { a = g.accounts[0] }
        else if catOf(cur) == g.id && g.accounts.contains(cur) { a = cur }
        else if let l = lastUsedInGroups(L, root: root)[g.id], g.accounts.contains(l) { a = l }
        else { a = g.accounts[0] }
        store.draft.account = a
        store.draft.edited = nil
        pickedCategory = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: 转账

    private func transferPanel(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        VStack(spacing: 0) {
            accountRow(LS("转出"), d.funding, L) { picking = .from }
            Divider().padding(.leading, 16)
            accountRow(LS("转入"), d.to, L) { picking = .to }
            if !d.funding.isEmpty && !d.to.isEmpty {
                Divider().padding(.leading, 16)
                Button {
                    var x = store.draft
                    (x.funding, x.to) = (x.to, x.funding)
                    x.currency = D.acctCcy[x.funding] ?? x.currency
                    x.edited = nil
                    store.draft = x
                } label: {
                    Label(LS("对调"), systemImage: "arrow.up.arrow.down").font(.subheadline)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.jade)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func accountRow(_ label: String, _ a: String, _ L: Ledger, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(a.isEmpty ? LS("选择") : accountTitle(L, a)).foregroundStyle(a.isEmpty ? Color.secondary : Color.primary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func accountPicker(_ p: Pick) -> some View {
        let d = store.draft
        switch p {
        case .funding:
            AccountPicker(title: d.kind == .income ? LS("收款账户") : LS("付款账户"), prefixes: ["Assets:", "Liabilities:"], current: d.funding) { a in
                store.draft.funding = a; store.draft.edited = nil; pickedFunding = true
            }
        case .from:
            AccountPicker(title: LS("转出"), prefixes: ["Assets:", "Liabilities:"], current: d.funding) { a in
                store.draft.funding = a
                store.draft.currency = store.D?.acctCcy[a] ?? store.draft.currency
                store.draft.edited = nil
            }
        case .to:
            AccountPicker(title: LS("转入"), prefixes: ["Assets:", "Liabilities:"], current: d.to) { a in
                store.draft.to = a; store.draft.edited = nil
            }
        }
    }

    // MARK: the bottom: choices, amount, keypad (or the text fields while typing)

    private func bottomPanel(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        VStack(spacing: 10) {
            if field == nil { chips(d, L, D) }
            amountCard(d, L, D)
            if field == nil { keypad(d) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: chips

    private func chips(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if d.kind != .transfer { fundingMenu(d, L, D) }
                    if d.kind == .expense { reimbChip(d, D) }
                    if discountAllowed(d) {
                        let v = evalAmount(d.discount) ?? 0
                        Button { splittingPay = true } label: {
                            pill(v > 0 ? LS("优惠 %@", money(v, d.currency)) : LS("优惠"), icon: "gift", on: v > 0)
                        }
                        .buttonStyle(.plain)
                    }
                    markChip(d, L)
                    if d.kind == .expense && store.ownedSubLinks.contains(d.link.trimmed) {
                        // a subscription's charge: paid on top of this period's, or a new period
                        Button { store.draft.topup.toggle(); store.draft.edited = nil } label: {
                            pill(LS("本期补差"), icon: "plus.forwardslash.minus", on: d.topup)
                        }
                        .buttonStyle(.plain)
                    }
                    if d.kind == .expense && !d.reimb {
                        Button {
                            store.draft.split = true; store.draft.edited = nil
                            openFull()
                        } label: { pill(LS("AA"), icon: "person.2", on: false) }
                        .buttonStyle(.plain)
                    }
                    if d.kind != .transfer && (isPersonal(d.account) || isPersonal(d.funding)) {
                        Button { openFull() } label: {
                            pill(d.person.trimmed.isEmpty ? LS("填写对方") : d.person, icon: "person", on: !d.person.trimmed.isEmpty)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            moreMenu
        }
    }

    private func fundingMenu(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let funds = Array(D.rankAccounts(["Assets:", "Liabilities:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(8))
        let others = d.kind == .expense ? d.extraFunds.filter { !$0.account.isEmpty }.count : 0
        let title = (d.funding.isEmpty ? (d.kind == .income ? LS("收款账户") : LS("付款账户")) : accountTitle(L, d.funding))
            + (others > 0 ? " + \(others)" : "")
        return Menu {
            ForEach(funds, id: \.self) { a in
                Button {
                    store.draft.funding = a; store.draft.edited = nil; pickedFunding = true
                } label: {
                    if a == d.funding { Label(accountTitle(L, a), systemImage: "checkmark") } else { Text(accountTitle(L, a)) }
                }
            }
            Divider()
            Button(LS("更多账户…")) { picking = .funding }
            if d.kind == .expense {
                Button { splittingPay = true } label: { Label(LS("组合付款…"), systemImage: "square.split.2x1") }
            }
        } label: {
            pill(title, icon: d.funding.isEmpty ? "creditcard" : store.groupIcon(d.funding).symbol, on: !d.funding.isEmpty)
        }
    }

    /// 标记: the entry's tags, its events and 待确认 (!) in one place; the chip says what is set
    private func markChip(_ d: Draft, _ L: Ledger) -> some View {
        let evs = d.kind == .transfer ? [] : ledgerEvents(L, today: d.date).filter { d.events.contains($0.tag) }.map { $0.title }
        let parts = evs + d.tags.map { "#" + $0 } + (d.flag == "!" ? ["!"] : [])
        return Button { marking = true } label: {
            pill(parts.isEmpty ? LS("标记") : parts.joined(separator: " "), icon: "bookmark", on: !parts.isEmpty)
        }
        .buttonStyle(.plain)
    }

    /// 报销: off, paid from a petty cash (the newest with money left, by default), or advanced by oneself
    private func reimbChip(_ d: Draft, _ D: Derived) -> some View {
        let floats = D.floats.filter { $0.left > 0.005 }
        let onFloat = d.reimb && isFloatLink(d.link.trimmed)
        let label = !d.reimb ? LS("报销") : onFloat ? LS("报销 · 备用金") : LS("报销 · 垫付")
        func set(_ on: Bool, _ link: String) {
            store.draft.reimb = on
            store.draft.link = link
            store.draft.edited = nil
        }
        return Menu {
            Button { set(false, isFloatLink(d.link.trimmed) ? "" : d.link) } label: {
                if !d.reimb { Label(LS("不报销"), systemImage: "checkmark") } else { Text(LS("不报销")) }
            }
            ForEach(floats) { f in
                Button { set(true, f.link) } label: {
                    let t = LS("备用金 %@（剩 %@）", f.date, money(f.left, f.currency))
                    if d.reimb && d.link == f.link { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
            }
            Button { set(true, isFloatLink(d.link.trimmed) ? "" : d.link) } label: {
                if d.reimb && !onFloat { Label(LS("自己垫付"), systemImage: "checkmark") } else { Text(LS("自己垫付")) }
            }
            if d.reimb {
                Divider()
                Picker(LS("凭证类型"), selection: Binding(get: { store.draft.voucher }, set: { store.draft.voucher = $0; store.draft.edited = nil })) {
                    Text(LS("凭证：不填")).tag("")
                    ForEach(voucherKinds, id: \.self) { Text(LS("凭证：%@", $0)).tag($0) }
                }
            }
        } label: {
            pill(label + (d.reimb && !d.voucher.isEmpty ? " · " + d.voucher : ""), icon: d.reimb ? "checkmark.circle.fill" : "circle", on: d.reimb)
        }
    }

    private func pill(_ text: String, icon: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.subheadline).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(on ? Color.jade : Color.primary)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().stroke(on ? Color.jade.opacity(0.6) : Color.clear, lineWidth: 1))
    }

    // MARK: amount

    private func amountCard(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let fc = accountCurrency(d.funding, L, D), tc = accountCurrency(d.to, L, D)
        let other = d.kind == .transfer ? (d.to.isEmpty ? nil : tc) : fc
        let cross = other != nil && other != d.currency && !(d.kind != .transfer && hasCombo(d))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // the currency, and the rate when the account is in another one
                Button { rating = true } label: {
                    Text(SYM[d.currency] ?? d.currency).font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(kindColor)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(LS("币种与汇率"))
                .accessibilityValue(d.currency)
                // smaller as the expression grows (a fixed size each step, so it doesn't wobble while typing)
                Text(d.amount.isEmpty ? "0.00" : d.amount)
                    .font(.system(size: d.amount.count <= 10 ? 30 : d.amount.count <= 15 ? 24 : 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(d.amount.isEmpty ? Color.secondary.opacity(0.5) : kindColor)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(LS("金额"))
                    .accessibilityValue(d.amount.isEmpty ? "0" : d.amount)
                Spacer(minLength: 4)
                if isExpression(d.amount) {
                    Text("= " + (evalAmount(d.amount).map { fmtNum($0) } ?? "?")).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if cross, let o = other {
                // the rate as the draft has it ("1 USD = 6.70408 CNY"); the sheet fills it in
                Button { rating = true } label: {
                    Label(draftRate(d).map { "1 \(d.currency) = \(rateString($0)) \(o)" } ?? LS("填汇率…"), systemImage: "arrow.left.arrow.right")
                        .font(.footnote)
                        .foregroundStyle(draftRate(d) == nil ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            if field == nil, let s = comboSummary(d, L) {
                let issue = comboIssue(d, L, D)
                Label(issue ?? s, systemImage: issue == nil ? "square.split.2x1" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .onTapGesture { splittingPay = true }
            }
            Divider()
            if field == nil {
                noteRow(d)
            } else {
                textFields(d, D)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// the date, and who / what for in one line ("Landlord · 房租"); tap the line to type them
    private func noteRow(_ d: Draft) -> some View {
        let summary = [d.payee.trimmed, d.narration.trimmed].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Button { dating = true } label: {
                Label(dayLabel(d.date), systemImage: "calendar")
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $dating) { DayPopover(date: Binding(get: { store.draft.date }, set: { store.draft.date = $0; store.draft.edited = nil })) { dating = false } }
            Button { field = d.payee.trimmed.isEmpty ? .payee : .narration } label: {
                Text(summary.isEmpty ? LS("点击填写收付款方、备注") : summary)
                    .font(.subheadline)
                    .foregroundStyle(summary.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LS("收付款方与备注"))
        }
    }

    /// 今天, 昨天, or the day ("10月14日"; with the year when it isn't this year's)
    private func dayLabel(_ day: String) -> String {
        let today = Day.today()
        if day == today { return LS("今天") }
        if day == Day.shift(today, -1) { return LS("昨天") }
        let m = Int(day.dropFirst(5).prefix(2)) ?? 0, dd = Int(day.suffix(2)) ?? 0
        return day.prefix(4) == today.prefix(4) ? LS("%@月%@日", String(m), String(dd)) : day
    }

    /// 收付款方 and 备注 while typing, with suggestions under each
    @ViewBuilder
    private func textFields(_ d: Draft, _ D: Derived) -> some View {
        let narrs = Array((D.payee(d.payee.trimmed)?.narrations ?? []).prefix(6))
        labeled(LS("收付款方")) {
            TextField(LS("如 便利店、淘宝，可不填"), text: Binding(get: { store.draft.payee }, set: { store.draft.payee = $0; store.draft.edited = nil }))
                .focused($field, equals: .payee)
                .submitLabel(.next)
                .onSubmit { applyPayee(store.draft.payee.trimmed, onlyBlanks: false); field = .narration }
        }
        if field == .payee {
            let q = d.payee.trimmed
            let items = Array(D.payees.lazy.filter { q.isEmpty || fuzzy(q, $0.name) > 0 }.prefix(8))
            if !items.isEmpty && !(items.count == 1 && items[0].name == q) {
                ChipRow {
                    ForEach(items, id: \.name) { p in
                        Chip(label: p.name) { applyPayee(p.name, onlyBlanks: false); field = .narration }
                    }
                }
            }
        }
        labeled(LS("备注")) {
            TextField(narrs.first.map { LS("如 %@，可不填", $0) } ?? LS("买了什么、做什么用，可不填"),
                      text: Binding(get: { store.draft.narration }, set: { store.draft.narration = $0; store.draft.edited = nil }))
                .focused($field, equals: .narration)
                .submitLabel(.done)
                .onSubmit { field = nil }
        }
        if field == .narration && !narrs.isEmpty {
            ChipRow {
                ForEach(narrs, id: \.self) { n in
                    Chip(label: n, selected: d.narration == n) { store.draft.narration = n; store.draft.edited = nil }
                }
            }
        }
    }

    private func labeled<F: View>(_ label: String, @ViewBuilder _ f: () -> F) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            f()
        }
        .padding(.vertical, 2)
    }

    /// a payee picked by hand (or typed and left) fills in its usual category and account; ones picked here stay
    private func applyPayee(_ name: String, onlyBlanks: Bool) {
        guard !name.isEmpty, store.D?.payee(name) != nil else { return }
        let keepCat = store.draft.account, keepFund = store.draft.funding
        if onlyBlanks && !keepCat.isEmpty { return }
        store.applyPayee(name)
        if pickedCategory && !keepCat.isEmpty { store.draft.account = keepCat }
        if pickedFunding && !keepFund.isEmpty { store.draft.funding = keepFund }
    }

    // MARK: keypad

    private func keypad(_ d: Draft) -> some View {
        let expr = isExpression(d.amount)
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { digit("1"); digit("2"); digit("3"); KeyCap(systemImage: "delete.left", label: LS("退格"), tap: { key("⌫") }, hold: { setAmount("") }) }
            GridRow { digit("4"); digit("5"); digit("6"); KeyCap(text: "+  ×", label: LS("加，长按为乘"), tap: { key("+") }, hold: { key("×") }) }
            GridRow { digit("7"); digit("8"); digit("9"); KeyCap(text: "−  ÷", label: LS("减，长按为除"), tap: { key("-") }, hold: { key("÷") }) }
            GridRow {
                digit(".")
                digit("0")
                if d.replacing != nil {
                    // editing: there is no next one; its text instead
                    KeyCap(text: LS("源文本"), font: .system(size: 16, weight: .semibold), tap: { editingText = true })
                } else {
                    KeyCap(text: LS("保存再记"), font: .system(size: 16, weight: .semibold), tap: { submit(close: false) })
                }
                KeyCap(text: expr ? "=" : LS("完成"), font: .system(size: expr ? 24 : 17, weight: .semibold), filled: true, tint: kindColor,
                       tap: { expr ? equals() : submit(close: true) })
                    .opacity(saving ? 0.5 : 1)
            }
        }
    }

    private func digit(_ s: String) -> some View { KeyCap(text: s, tap: { key(s) }) }

    private func setAmount(_ a: String) {
        store.draft.amount = a
        store.draft.edited = nil
    }

    /// typing on the keypad: one decimal point and two decimals per number, no leading zeros, one operator in a row
    private func key(_ k: String) {
        var a = store.draft.amount
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setAmount(a)
    }

    private func equals() {
        guard let v = evalAmount(store.draft.amount) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setAmount(v > 0 ? jsNumberString(roundTo(v, 2)) : "")
    }

    private func submit(close: Bool) {
        guard !saving else { return }
        if isExpression(store.draft.amount) { equals() }
        guard let a = evalAmount(store.draft.amount), a > 0 else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            store.show(LS("请输入金额"))
            return
        }
        field = nil
        saving = true
        Task {
            let ok = await store.saveDraft()
            saving = false
            guard ok else { return }
            pickedCategory = false
            pickedFunding = false
            if close { store.adding = false }
        }
    }
}

// MARK: - pieces of the card

/// one cell of the category grid, as drawn
struct GridCell: Equatable {
    let id: String
    let icon: String
    let title: String
    let single: Bool
}

/// the category grid: five to a row. Equatable, so typing an amount (which changes nothing here) doesn't redraw it
struct CategoryGridView: View, Equatable {
    let cells: [GridCell]
    let picked: String?
    let tap: (String) -> Void
    let menu: (String) -> AnyView

    static func == (a: CategoryGridView, b: CategoryGridView) -> Bool { a.cells == b.cells && a.picked == b.picked }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 14) {
            ForEach(cells, id: \.id) { c in cell(c, selected: c.id == picked) }
        }
    }

    private func cell(_ c: GridCell, selected: Bool) -> some View {
        Button { tap(c.id) } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: c.icon)
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(selected ? Color.onJade : Color.primary)
                        .background(selected ? Color.jade : Color(.secondarySystemGroupedBackground), in: Circle())
                    if !c.single {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.secondary, in: Circle())
                            .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
                Text(c.title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { menu(c.id) }
    }
}

/// a group's sub-categories, to pick one
struct SubCategorySheet: View {
    let group: CategoryGroup
    let title: String
    let L: Ledger
    let current: String
    let pick: (String) -> Void

    var body: some View {
        NavigationStack {
            List(group.accounts, id: \.self) { a in
                Button { pick(a) } label: {
                    HStack {
                        Text(accountTitle(L, a)).foregroundStyle(Color.primary)
                        Spacer()
                        if a == current { Image(systemName: "checkmark").foregroundStyle(Color.jade).fontWeight(.semibold) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// the entry's day: a calendar, with 今天 and 昨天 one tap away
struct DayPopover: View {
    @Binding var date: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(LS("今天")) { date = Day.today(); done() }.buttonStyle(.bordered)
                Button(LS("昨天")) { date = Day.shift(Day.today(), -1); done() }.buttonStyle(.bordered)
                Spacer()
            }
            DatePicker(LS("日期"), selection: Binding(get: { Day.date(date) ?? Date() }, set: { date = Day.string($0); done() }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
        }
        .padding(12)
        .frame(width: 330)
        .presentationCompactAdaptation(.popover)
    }
}

/// 标记: the events of the entry's day (and any picked), its tags, and 待确认 (!)
struct MarkSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    @State private var newTag = ""
    @State private var badTag = false

    var body: some View {
        let d = store.draft
        let evs = d.kind == .transfer ? [] : ledgerEvents(L, today: d.date).filter { ($0.entry != nil && $0.covers(d.date)) || d.events.contains($0.tag) }
        let known = Array(Set(L.txns.suffix(2000).flatMap { $0.tags })).filter { !["transfer", "fx", "reimbursed", "refund", "reimbursement"].contains($0) && !d.tags.contains($0) && !evs.contains(where: { e in e.tag == $0 }) }.sorted().prefix(12)
        NavigationStack {
            List {
                if !evs.isEmpty {
                    Section(LS("事件")) {
                        ForEach(evs) { e in
                            Button {
                                var x = store.draft
                                if let i = x.events.firstIndex(of: e.tag) { x.events.remove(at: i) } else { x.events.append(e.tag) }
                                x.eventsTouched = true
                                x.edited = nil
                                store.draft = x
                            } label: {
                                HStack {
                                    Label(e.title, systemImage: "flag").foregroundStyle(Color.primary)
                                    Spacer()
                                    if d.events.contains(e.tag) { Image(systemName: "checkmark").foregroundStyle(Color.jade).fontWeight(.semibold) }
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(d.tags, id: \.self) { t in
                        HStack {
                            Text("#" + t)
                            Spacer()
                            Button { store.draft.tags.removeAll { $0 == t }; store.draft.edited = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField(LS("新标签，如 trip-shanghai"), text: $newTag)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit(addTag)
                        Button(LS("添加"), action: addTag).disabled(newTag.trimmed.isEmpty)
                    }
                    if !known.isEmpty {
                        ChipRow { ForEach(Array(known), id: \.self) { t in Chip(label: "#" + t) { add(t) } } }
                    }
                } header: {
                    Text(LS("标签"))
                } footer: {
                    if badTag { Text(LS("标签只能用英文字母、数字和 - _ / .（Beancount 的规定）")).foregroundStyle(Color.warn) }
                }
                Section {
                    Toggle(LS("待确认（!）"), isOn: Binding(get: { store.draft.flag == "!" }, set: { store.draft.flag = $0 ? "!" : "*"; store.draft.edited = nil }))
                } footer: {
                    Text(LS("金额或分类还要核对的，记为待确认；明细里用 ! 可以找出来。"))
                }
            }
            .navigationTitle(LS("标记"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() }.fontWeight(.semibold) } }
        }
    }

    private func addTag() { add(newTag); newTag = "" }

    private func add(_ raw: String) {
        let t = raw.trimmed.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "-")
        // Beancount takes only these in a tag
        badTag = !t.isEmpty && t.range(of: #"^[A-Za-z0-9\-_/.]+$"#, options: .regularExpression) == nil
        guard !t.isEmpty, !badTag, !store.draft.tags.contains(t) else { return }
        store.draft.tags.append(t)
        store.draft.edited = nil
    }
}

/// a key of the 记一笔 keypad; `hold` is what a long press types (× on +, clear on ⌫)
struct KeyCap: View {
    var text: String? = nil
    var systemImage: String? = nil
    var label: String? = nil
    var font: Font = .system(size: 24, weight: .regular, design: .rounded)
    var filled = false
    /// the filled key's colour (the theme's by default)
    var tint: Color? = nil
    let tap: () -> Void
    var hold: (() -> Void)? = nil

    var body: some View {
        Group {
            if let s = systemImage { Image(systemName: s).font(.system(size: 20, weight: .medium)) }
            else { Text(text ?? "").font(font).lineLimit(1).minimumScaleFactor(0.7) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .foregroundStyle(filled ? (tint == nil ? Color.onJade : Color.white) : Color.primary)
        .background(filled ? (tint ?? Color.jade) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: tap)
        .onLongPressGesture(minimumDuration: 0.45) {
            if let h = hold { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); h() } else { tap() }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? text ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
    }
}
