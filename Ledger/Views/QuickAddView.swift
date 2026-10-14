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

/// The quick page: the kind on top, the categories as a grid, the paying account and other choices as a row of
/// chips, the amount with its own keypad. What it can't show (分录, 文本, AA, 实付, 源文本) is one step in, on 完整表单.
struct QuickAddView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    let openFull: () -> Void

    enum Field: Hashable { case payee, narration }
    @FocusState private var field: Field?
    @State private var showSource = false
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
    }

    private static let kinds: [DraftKind] = [.expense, .income, .transfer]
    /// the amount of an expense: a deep red (lighter in dark mode), so it reads as money going out
    static let spendRed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.00, green: 0.45, blue: 0.43, alpha: 1) : UIColor(red: 0.76, green: 0.16, blue: 0.16, alpha: 1) })

    private var kindColor: Color {
        switch store.draft.kind {
        case .expense: return Self.spendRed
        case .income: return Color.gain
        default: return Color.primary
        }
    }

    @ViewBuilder
    private func content(_ L: Ledger, _ D: Derived) -> some View {
        let d = store.draft
        let quick = Self.kinds.contains(d.kind) && !d.split
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !quick {
                        fullBanner(d)
                    } else {
                        // editing an entry: which one, instead of the templates (picking one would replace it)
                        if let r = d.replacing { editingBanner(r) } else { templatesRow(d.kind) }
                        if d.kind == .transfer { transferPanel(d, L, D) } else { grid(d, L, D) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            if quick { bottomPanel(d, L, D) }
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
                .frame(width: 210)
                .disabled(!quick)
            }
            ToolbarItem(placement: .primaryAction) { moreMenu }
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

    private var moreMenu: some View {
        Menu {
            Button { openFull() } label: { Label(LS("完整表单"), systemImage: "list.bullet.rectangle") }
            Button { store.setKind(.multi); openFull() } label: { Label(LS("分录（多行）"), systemImage: "list.number") }
            Button { store.setKind(.raw); openFull() } label: { Label(LS("文本（Beancount 指令）"), systemImage: "text.alignleft") }
            if store.draft.replacing == nil {
                Divider()
                Button { importing = true } label: { Label(LS("导入账单"), systemImage: "square.and.arrow.down.on.square") }
            }
            Divider()
            Button { managingCats = true } label: { Label(LS("分类图标与排序"), systemImage: "square.grid.3x3") }
            Button { managingTemplates = true } label: { Label(LS("常用交易"), systemImage: "star") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(LS("更多"))
    }

    private func editingBanner(_ r: Replacing) -> some View {
        Label(LS("修改：%@ %@", r.date, r.summary), systemImage: "pencil")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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

    @ViewBuilder
    private func templatesRow(_ kind: DraftKind) -> some View {
        let list = kind == .transfer ? [] : Array(store.templateList.filter { $0.kind == (kind == .income ? .income : .expense) }.prefix(8))
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(list) { x in
                        TemplateChip(x: x, saving: $saving) { _ in pickedCategory = true; pickedFunding = true }
                    }
                }
            }
        }
    }

    // MARK: the grid

    @ViewBuilder
    private func grid(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let root = Store.categoryRoot(d.kind)
        let groups = store.gridGroups(root, D)
        let last = lastUsedInGroups(L, root: root)
        let picked = d.account.hasPrefix(root) ? catOf(d.account) : nil
        let rows = stride(from: 0, to: groups.count, by: 5).map { Array(groups[$0..<min($0 + 5, groups.count)]) }
        VStack(spacing: 14) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        if i < rows[r].count {
                            cell(rows[r][i], selected: rows[r][i].id == picked, L) { pick(rows[r][i], last: last) }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
                // the accounts of the picked group, right under its row
                if let g = rows[r].first(where: { $0.id == picked }), !g.single {
                    ChipRow {
                        ForEach(g.accounts, id: \.self) { a in
                            Chip(label: accountTitle(L, a), selected: d.account == a) {
                                store.draft.account = a
                                store.draft.edited = nil
                                pickedCategory = true
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            if groups.isEmpty {
                Text(LS("账本里还没有%@科目，可在「账户」里新建。", d.kind == .income ? LS("收入") : LS("支出")))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: picked)
    }

    private func cell(_ g: CategoryGroup, selected: Bool, _ L: Ledger, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: store.catIcon(Store.cellKey(g)))
                        .font(.system(size: 21, weight: .regular))
                        .frame(width: 50, height: 50)
                        .foregroundStyle(selected ? Color.onJade : Color.primary)
                        .background(selected ? Color.jade : Color(.secondarySystemGroupedBackground), in: Circle())
                    if !g.single {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.secondary, in: Circle())
                            .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
                Text(store.catTitle(g, L))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button { styling = StyleTarget(group: g) } label: { Label(LS("更换图标"), systemImage: "photo") }
            Button { newTitle = store.catStyle.titles[g.id] ?? ""; renaming = g } label: { Label(LS("改名"), systemImage: "pencil") }
            Button(role: .destructive) { store.catStyle.hidden.append(g.id) } label: { Label(LS("从宫格隐藏"), systemImage: "eye.slash") }
        }
    }

    /// a group of one picks its account; a bigger one the account last used in it (its row of accounts opens)
    private func pick(_ g: CategoryGroup, last: [String: String]) {
        let cur = store.draft.account
        let a: String
        if g.single { a = g.accounts[0] }
        else if catOf(cur) == g.id && g.accounts.contains(cur) { a = cur }
        else if let l = last[g.id], g.accounts.contains(l) { a = l }
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

    // MARK: the bottom: choices, amount, keypad

    private func bottomPanel(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let text = draftText(d, L, D, explicit: store.explicitAmounts)
        let v: Validation? = text.trimmed.isEmpty ? nil : validateText(text, L, single: draftIsSingle(d, L))
        return VStack(spacing: 10) {
            chips(d, L, D)
            amountCard(d, text, v, L, D)
            if field == nil { keypad(d, v) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: chips

    private func chips(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if d.kind != .transfer { fundingMenu(d, L, D) }
                if discountAllowed(d) {
                    let v = evalAmount(d.discount) ?? 0
                    Button { splittingPay = true } label: {
                        pill(v > 0 ? LS("优惠 %@", money(v, d.currency)) : LS("优惠"), icon: "tag", on: v > 0)
                    }
                    .buttonStyle(.plain)
                }
                if d.kind == .expense && store.ownedSubLinks.contains(d.link.trimmed) {
                    // a subscription's charge: paid on top of this period's, or a new period
                    Button { store.draft.topup.toggle(); store.draft.edited = nil } label: {
                        pill(LS("本期补差"), icon: "plus.forwardslash.minus", on: d.topup)
                    }
                    .buttonStyle(.plain)
                }
                if d.kind == .expense { reimbChip(d, D) }
                if d.kind == .expense && !d.reimb {
                    Button {
                        store.draft.split = true; store.draft.edited = nil
                        openFull()
                    } label: { pill(LS("AA"), icon: "person.2", on: false) }
                    .buttonStyle(.plain)
                }
                eventChips(d, L)
                moreChips(d, D)
            }
            .padding(.horizontal, 2)
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
            pill(title, icon: "creditcard", on: !d.funding.isEmpty)
        }
    }

    /// the events of the entry's day (and any already picked): tap to add or remove the tag
    @ViewBuilder
    private func eventChips(_ d: Draft, _ L: Ledger) -> some View {
        let evs: [LedgerEvent] = d.kind == .transfer ? [] : ledgerEvents(L, today: d.date).filter { ($0.entry != nil && $0.covers(d.date)) || d.events.contains($0.tag) }
        ForEach(evs) { e in
            Button {
                var x = store.draft
                if let i = x.events.firstIndex(of: e.tag) { x.events.remove(at: i) } else { x.events.append(e.tag) }
                x.eventsTouched = true
                x.edited = nil
                store.draft = x
            } label: { pill(e.title, icon: "flag", on: d.events.contains(e.tag)) }
            .buttonStyle(.plain)
        }
    }

    /// what only the full form can fill in: who a personal receivable is with, the amount in the account's currency
    @ViewBuilder
    private func moreChips(_ d: Draft, _ D: Derived) -> some View {
        let fc = store.L.flatMap { accountCurrency(d.funding, $0, D) }, tc = store.L.flatMap { accountCurrency(d.to, $0, D) }
        let cross = d.kind == .transfer ? (!d.to.isEmpty && tc != nil && tc != d.currency) : (fc != nil && fc != d.currency)
        if d.kind != .transfer && (isPersonal(d.account) || isPersonal(d.funding)) {
            Button { openFull() } label: {
                pill(d.person.trimmed.isEmpty ? LS("填写对方") : d.person, icon: "person", on: !d.person.trimmed.isEmpty)
            }
            .buttonStyle(.plain)
        }
        if cross {
            Button { openFull() } label: { pill(LS("实付或汇率…"), icon: "arrow.left.arrow.right", on: false) }
                .buttonStyle(.plain)
        }
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
            pill(label + (d.reimb && !d.voucher.isEmpty ? " · " + d.voucher : ""), icon: "doc.text", on: d.reimb)
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

    private func amountCard(_ d: Draft, _ text: String, _ v: Validation?, _ L: Ledger, _ D: Derived) -> some View {
        let narrs = Array((D.payee(d.payee.trimmed)?.narrations ?? []).prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Menu {
                    Picker(LS("币种"), selection: Binding(get: { store.draft.currency }, set: { store.draft.currency = $0; store.draft.edited = nil })) {
                        ForEach(D.currencies, id: \.self) { c in Text(c).tag(c) }
                    }
                } label: {
                    Text(SYM[d.currency] ?? d.currency).font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(kindColor)
                }
                .fixedSize()
                // smaller as the expression grows (a fixed size each step, so it doesn't wobble while typing)
                Text(d.amount.isEmpty ? "0.00" : d.amount)
                    .font(.system(size: d.amount.count <= 9 ? 38 : d.amount.count <= 14 ? 30 : 22, weight: .semibold, design: .rounded))
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
            if field == nil, let s = comboSummary(d, L) {
                Label(comboIssue(d, L, D) ?? s, systemImage: comboIssue(d, L, D) == nil ? "square.split.2x1" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(comboIssue(d, L, D) == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .onTapGesture { splittingPay = true }
            }
            Divider()
            if field == nil { dateRow() }
            textFields(d, narrs, text, D)
            if showSource && field == nil { source(d, text, v) }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// the date, and the source text behind the chevron
    private func dateRow() -> some View {
        HStack(spacing: 10) {
            DatePicker(LS("日期"), selection: Binding(get: { Day.date(store.draft.date) ?? Date() },
                                                    set: { store.draft.date = Day.string($0); store.draft.edited = nil }),
                       displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
            Spacer(minLength: 0)
            Button { withAnimation { showSource.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(LS("源文本")).font(.footnote)
                    Image(systemName: showSource ? "chevron.down" : "chevron.up").font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(showSource ? LS("收起源文本") : LS("查看源文本"))
        }
    }

    /// 收付款方 and 备注 on rows of their own, always editable; while typing, the header line they make
    @ViewBuilder
    private func textFields(_ d: Draft, _ narrs: [String], _ text: String, _ D: Derived) -> some View {
        labeled(LS("收付款方")) {
            TextField(LS("如 便利店、淘宝，可不填"), text: Binding(get: { store.draft.payee }, set: { store.draft.payee = $0; store.draft.edited = nil }))
                .focused($field, equals: .payee)
                .submitLabel(.next)
                .onSubmit { applyPayee(store.draft.payee.trimmed, onlyBlanks: false); field = .narration }
        }
        if field == .payee {
            let q = d.payee.trimmed
            let items = Array(D.payees.filter { q.isEmpty || fuzzy(q, $0.name) > 0 }.prefix(8))
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
        if field != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(text.components(separatedBy: "\n").first(where: { !$0.trimmed.isEmpty }) ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail)
                Text(d.kind == .transfer
                     ? LS("写成 日期 * \"收付款方\" \"备注\"。转账不填时自动写 \"Transfer\" 和 \"转出 -> 转入\"。")
                     : LS("写成 日期 * \"收付款方\" \"备注\"。收付款方不填就省略，只留 \"备注\"；备注不填写成 \"\"。不用自己加引号。"))
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func source(_ d: Draft, _ text: String, _ v: Validation?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.trimmed.isEmpty {
                Text(LS("填写金额与账户后将在此生成分录")).font(.footnote).foregroundStyle(.tertiary)
            } else {
                MonoText(text: text)
                HStack {
                    Button { field = nil; editingText = true } label: {
                        Label(d.edited != nil ? LS("已手动编辑 · 点按继续编辑") : LS("点按编辑源文本"), systemImage: "pencil").font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.jade)
                    Spacer()
                    if d.edited != nil {
                        Button(LS("恢复自动生成")) { store.draft.edited = nil }.font(.footnote).buttonStyle(.plain).foregroundStyle(Color.jade)
                    }
                }
            }
            if let v = v {
                if v.ok {
                    Label(v.warnings.isEmpty ? LS("校验通过") : v.warnings[0].msg, systemImage: v.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(v.warnings.isEmpty ? Color.gain : Color.orange)
                } else if let m = v.msg {
                    Label(m, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.loss)
                }
            }
        }
    }

    // MARK: keypad

    private func keypad(_ d: Draft, _ v: Validation?) -> some View {
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
                KeyCap(text: expr ? "=" : LS("完成"), font: .system(size: expr ? 24 : 17, weight: .semibold), filled: true,
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
            showSource = false
            if close { store.adding = false }
        }
    }
}

/// a key of the 记一笔 keypad; `hold` is what a long press types (× on +, clear on ⌫)
struct KeyCap: View {
    var text: String? = nil
    var systemImage: String? = nil
    var label: String? = nil
    var font: Font = .system(size: 24, weight: .regular, design: .rounded)
    var filled = false
    let tap: () -> Void
    var hold: (() -> Void)? = nil

    var body: some View {
        Group {
            if let s = systemImage { Image(systemName: s).font(.system(size: 20, weight: .medium)) }
            else { Text(text ?? "").font(font).lineLimit(1).minimumScaleFactor(0.7) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .foregroundStyle(filled ? Color.onJade : Color.primary)
        .background(filled ? Color.jade : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
