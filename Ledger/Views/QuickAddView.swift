import SwiftUI
import LedgerKit

/// the pages of the 记一笔 card past the quick one
enum AddRoute: Hashable { case full }

/// 记一笔 as a card over any tab: the quick page first, 完整表单 one step in
struct AddCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    @State private var recovering = false
    @State private var path = NavigationPath()
    /// 1 while the full form is the card's own first page (opened for 分录, 退款…), so popping keeps it
    @State private var base = 0

    var body: some View {
        NavigationStack(path: $path) {
            QuickAddView { path.append(AddRoute.full) }
                .navigationDestination(for: AddRoute.self) { _ in AddForm(onSaved: { store.adding = false }, onBack: {
                    if store.prepareQuickEditor(), !path.isEmpty { path.removeLast() }
                }) }
                .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0).privacyToolbar() }
                .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
                .subscriptionDestinations()
        }
        // on the stack itself: the pages it opens inherit what is set here, not what is set on its first page
        .pushes(onto: $path)
        .disabled(dm.isSaving)
        .protectUnsavedChanges(dirty: dm.hasChanges, busy: dm.isSaving, requested: $store.closeAddRequested,
            keep: { store.persistActiveDraft(); store.adding = false },
            discard: { store.discardActiveDraft(); store.adding = false },
            close: { store.adding = false })
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { recovering = true } label: { Image(systemName: "doc.badge.clock") }
                    .accessibilityLabel(LS("草稿"))
            }
        }
        .sheet(isPresented: $recovering) { DraftRecoverySheet() }
        .overlay(alignment: .top) { ToastView(top: true).padding(.top, AppSpacing.icon).animation(AppMotion.emphasized, value: store.toast) }
        .sheet(item: $store.subSuggestion) { c in SubEditSheet(draft: SubDraft(c)) }
        .onDisappear { store.persistActiveDraft() }
        .onAppear(perform: route)
        .onChange(of: store.addToken) { _, _ in route() }
        // after an edit or delete on a page opened from here: back to the form
        .onChange(of: store.popToken) { _, _ in if path.count > base { path.removeLast(path.count - base) } }
        .onChange(of: path.count) { _, n in if n < base { base = n } }
    }

    /// the page asked for: the quick one, or the full form on top of it — set as the card opens, without a push
    /// animation (and left alone when it is already that page, so opening doesn't redraw the stack)
    private func route() {
        let want = store.addFull ? 1 : 0
        guard path.count != want || base != want else { return }
        var p = NavigationPath()
        if store.addFull { p.append(AddRoute.full) }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            base = p.count
            path = p
        }
    }
}

/// Amount entry keeps the categories, choices and keypad stable. Text entry uses a scrolling card and a
/// keyboard-safe candidate bar, temporarily hiding categories and templates; 完成 restores amount entry.
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
    @State private var pettyCash = false
    @State private var saving = false
    @State private var attemptedSave = false
    /// editing an entry: 删除这笔交易 asked, waiting for the confirmation
    @State private var confirmDelete = false
    /// 组合付款与优惠
    @State private var splittingPay = false
    /// the currency and rate sheet
    @State private var rating = false
    @State private var feeEditing = false
    /// 标记: tags, events, 待确认
    @State private var marking = false
    /// the date's calendar
    @State private var dating = false
    /// typing the payee and description: the fields replace the keypad (focus follows once they are on screen)
    @State private var writing = false
    /// a category group whose sub-categories are shown
    @State private var subPicking: String?
    /// the category / paying account were picked here: a payee picked afterwards doesn't change them
    private var pickedCategory: Bool {
        get { store.draft.selection?.category == true }
        nonmutating set {
            var selection = store.draft.selection ?? DraftSelection()
            selection.category = newValue; store.draft.selection = selection
        }
    }
    private var pickedFunding: Bool {
        get { store.draft.selection?.funding == true }
        nonmutating set {
            var selection = store.draft.selection ?? DraftSelection()
            selection.funding = newValue; store.draft.selection = selection
        }
    }
    /// 全部分类: every category, searchable, without the keypad
    @State private var allCategories = false

    enum Pick: String, Identifiable { case funding, from, to; var id: String { rawValue } }

    var body: some View {
        Group {
            if let L = store.L, let D = store.D { content(L, D) } else { ProgressView() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.demoEnv["LEDGER_IMPORT"] != nil { importing = true } }
        .task { if store.demoEnv["LEDGER_PETTY_CASH"] != nil { try? await Task.sleep(nanoseconds: 700_000_000); pettyCash = true } }
        .task { if store.demoEnv["LEDGER_CATS"] != nil { managingCats = true } }
        .task { if store.demoEnv["LEDGER_COMBO_SHEET"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); splittingPay = true } }
        .task { if store.demoEnv["LEDGER_NOTE"] != nil { try? await Task.sleep(nanoseconds: 900_000_000); startWriting(.narration) } }
        .task { if store.demoEnv["LEDGER_MARK"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); marking = true } }
        .task { if store.demoEnv["LEDGER_ALLCATS"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); allCategories = true } }
        .task { if store.demoEnv["LEDGER_SUBCAT"] != nil { try? await Task.sleep(nanoseconds: 600_000_000); subPicking = catOf(store.draft.account) } }
    }

    private static let kinds: [DraftKind] = [.expense, .income, .transfer]

    /// the kind's colour, for the amount, its currency sign and the save keys: spending red, income green, a
    /// transfer the theme's (green for a gain and red for a loss everywhere in the app)
    private var kindColor: Color {
        switch store.draft.kind {
        case .expense: return .loss
        case .income: return .gain
        default: return .jade
        }
    }
    /// the save keys' colour: the theme's own (with its text colour) for a transfer
    private var saveTint: Color? {
        switch store.draft.kind {
        case .expense, .income: return kindColor
        default: return nil
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    private func content(_ L: Ledger, _ D: Derived) -> some View {
        let d = store.draft
        let quick = Self.kinds.contains(d.kind) && !d.split
        VStack(spacing: 0) {
            if !quick {
                ScrollView { fullBanner(d).padding(AppSpacing.content) }
            } else if writing {
                ScrollViewReader { proxy in
                    ScrollView {
                        amountCard(d, L, D).padding(AppSpacing.control)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: field) { _, next in
                        if let next { proxy.scrollTo(next, anchor: .center) }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { textSuggestions(d, D) }
            } else {
                topStrip(d)
                // the grid, sub-categories and the details scroll in their own area: the amount, the choices and
                // the keypad below never move
                ScrollView {
                    VStack(spacing: AppSpacing.control) {
                        if d.kind == .transfer { transferPanel(d, L, D) } else { grid(d, L, D); subCategories(d, L, D) }
                    }
                    .padding(.horizontal, AppSpacing.content)
                    .padding(.vertical, AppSpacing.icon)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: .infinity)
                bottomPanel(d, L, D)
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { store.closeAddRequested = true } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(LS("关闭"))
            }
            ToolbarItem(placement: .principal) {
                Picker(LS("类型"), selection: Binding(get: { Self.kinds.contains(store.draft.kind) ? store.draft.kind : .expense },
                                                     set: { k in store.setKind(k) })) {
                    ForEach(Self.kinds) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.segmented)
                .frame(width: 186)
                .disabled(!quick)
            }
            // ⚙︎ on the right, as wide as ✕ on the left: the kind switch stays centred and doesn't move as the card opens
            ToolbarItem(placement: .primaryAction) { moreMenu }
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
            if new == nil && old != nil { store.persistActiveDraft(); DispatchQueue.main.async { if field == nil { writing = false } } }
            // leaving the payee: a known one fills in what isn't picked yet
            if old == .payee && new != .payee { applyPayee(store.draft.payee.trimmed, onlyBlanks: true) }
        }
        .sheet(item: $picking) { p in accountPicker(p) }
        .navigationDestination(isPresented: $allCategories) { allCategoriesPage(L, D) }
        .sheet(item: $styling) { CategoryStyleSheet(target: $0) }
        .sheet(isPresented: $managingCats) { CategoryManager(root: Store.categoryRoot(store.draft.kind)) }
        .sheet(isPresented: $managingTemplates) { TemplateManager() }
        .sheet(isPresented: $splittingPay) { PaySplitSheet() }
        .sheet(isPresented: $rating) { RateSheet(L: L, D: D) }
        .sheet(isPresented: $feeEditing) { TransferFeeSheet() }
        .sheet(isPresented: $marking) { MarkSheet(L: L).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $importing) { ImportView() }
        .sheet(isPresented: $pettyCash) { PettyCashSheet() }
        .confirmationDialog(store.draft.replacing.map { LS("删除 %@ %@？", $0.date, $0.summary) } ?? "",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(role: .destructive) {
                guard !store.drafts.isSaving, let r = store.draft.replacing else { return }
                store.drafts.isSaving = true
                Task {
                    defer { store.drafts.isSaving = false }
                    // the entry as it was when the card opened; the card closes once it is gone
                    if await store.deleteEntry(path: r.path, old: r.old, date: r.date, summary: r.summary, pop: false, anchorLine: r.line) {
                        store.discardActiveDraft()
                        store.adding = false
                    }
                }
            } label: { Text(LS("删除")) }
        } message: {
            Text(LS("删除后可在「最近改动」里撤回。"))
        }
        .sheet(isPresented: $editingText) {
            TextEditSheet(title: LS("编辑源文本"), initial: draftText(store.draft, L, D, explicit: store.explicitAmounts),
                          validate: { t in validateText(t, L, single: draftIsSingle(store.draft, L)) }) { new in
                store.applyDraftSource(new)
            }
        }
        .alert(LS("分类名称"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map { store.catTitle($0, L) } ?? "", text: $newTitle)
            Button {
                if let g = renaming { store.catStyle.titles[g.id] = newTitle.trimmed.isEmpty ? nil : newTitle.trimmed }
                renaming = nil
            } label: { Text(LS("保存")) }
            Button(role: .cancel) { renaming = nil } label: { Text(LS("取消")) }
        } message: {
            Text(LS("只改本机宫格里显示的名字，账本里的科目不变；留空恢复默认。"))
        }
    }

    // MARK: top

    /// the ledgers set up on this phone, to switch to (in the ⋯ menu), and where they are managed
    private var ledgerItems: some View {
            Menu {
                ForEach(store.sources) { s in
                    Button {
                        guard s.id != store.cfg.id else { return }
                        Task {
                            await store.switchLedger(s.id)
                        }
                    } label: {
                        if s.id == store.cfg.id { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
                Divider()
                Button {
                    // settings open over the app, not over the card
                    store.adding = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { store.showSettings = true }
                } label: { Label(LS("管理账本…"), systemImage: "gearshape") }
            } label: {
                Label(LS("切换账本（%@）", store.cfg.title), systemImage: "books.vertical")
            }
    }

    /// above the grid: which entry is being edited, what a screenshot gave, or the frequent entries
    @ViewBuilder
    private func topStrip(_ d: Draft) -> some View {
        if let r = d.replacing {
            editingBanner(r).padding(.horizontal, AppSpacing.content).padding(.top, AppSpacing.icon)
        } else if let s = store.scanInfo {
            ScanBanner(info: s).padding(.horizontal, AppSpacing.control).padding(.top, AppSpacing.icon)
        } else {
            templateCapsules(d.kind)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { openFull() } label: { Label(LS("完整表单"), systemImage: "list.bullet.rectangle") }
            Button { if store.setKind(.multi) { openFull() } } label: { Label(LS("分录（多行）"), systemImage: "list.number") }
            Button { if store.setKind(.raw) { openFull() } } label: { Label(LS("文本（Beancount 指令）"), systemImage: "text.alignleft") }
            Button { field = nil; editingText = true } label: {
                Label(store.draft.edited != nil ? LS("源文本（已手动编辑）") : LS("源文本"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("quick.source")
            if store.draft.edited != nil {
                Button { store.draft.edited = nil } label: { Label(LS("恢复自动生成"), systemImage: "arrow.counterclockwise") }
            }
            if store.draft.replacing == nil {
                Divider()
                Button { pettyCash = true } label: { Label(LS("领取备用金"), systemImage: "banknote") }
                Button { importing = true } label: { Label(LS("导入账单"), systemImage: "square.and.arrow.down.on.square") }
            }
            Divider()
            Button { managingCats = true } label: { Label(LS("分类图标与排序"), systemImage: "square.grid.3x3") }
            Button { managingTemplates = true } label: { Label(LS("常用交易"), systemImage: "star") }
            if store.draft.replacing == nil { ledgerItems }
            if store.draft.replacing != nil {
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label(LS("删除这笔交易"), systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(LS("更多"))
    }

    private func editingBanner(_ r: Replacing) -> some View {
        Label(LS("修改：%@ %@", r.date, r.summary), systemImage: "pencil").labelStyle(ControlLabelStyle())
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分录 / 文本 / 退款 / AA are edited on the full form
    private func fullBanner(_ d: Draft) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            Label(d.split ? LS("这笔是 AA 分摊") : LS("这笔是「%@」", d.kind.label), systemImage: "list.bullet.rectangle").labelStyle(ControlLabelStyle())
                .font(.headline)
            if !d.payee.trimmed.isEmpty { LabeledContent(LS("收付款方"), value: d.payee) }
            if !d.narration.trimmed.isEmpty { LabeledContent(LS("备注"), value: d.narration) }
            Text(LS("这类交易在完整表单里填写。")).font(.subheadline).foregroundStyle(.secondary)
            ActionRow(size: .small, items: [
                ActionRow.Item(title: LS("继续填写"), systemImage: "pencil", emphasis: .primary) { openFull() },
                ActionRow.Item(title: LS("改为普通支出"), systemImage: "arrow.down.circle") {
                    var x = store.draft
                    x.split = false; x.shares = []; x.sharesEdited = false; x.refundOf = nil
                    store.draft = x
                    store.setKind(.expense)
                },
            ])
        }
        .padding(AppSpacing.content)
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
                HStack(spacing: AppSpacing.icon) {
                    ForEach(list) { x in
                        Button {
                            store.fillTemplate(x)
                            pickedCategory = true; pickedFunding = true
                        } label: {
                            HStack(spacing: AppSpacing.detail) {
                                if x.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                                Text(x.label).lineLimit(1)
                                if let f = x.fixed { Text(money(f, x.currency)).foregroundStyle(.secondary).sensitive() }
                            }
                            .font(.footnote)
                            .padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.icon)
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
                .padding(.horizontal, AppSpacing.content)
            }
            .padding(.top, AppSpacing.icon)
        }
    }

    // MARK: the grid

    /// how many categories the card shows before 全部
    static let shownCategories = 7
    static let allCell = "__all__"

    /// the categories on the card: the first seven in the grid's order, the picked one put in the last place when
    /// it isn't among them
    private func shownGroups(_ groups: [CategoryGroup], picked: String?) -> [CategoryGroup] {
        var top = Array(groups.prefix(Self.shownCategories))
        if let p = picked, !top.contains(where: { $0.id == p }), let g = groups.first(where: { $0.id == p }), !top.isEmpty {
            top[top.count - 1] = g
        }
        return top
    }

    /// what a long press on a category offers (here and on 全部分类)
    private func cellMenu(_ g: CategoryGroup, _ L: Ledger) -> AnyView {
        AnyView(Group {
            if !g.single { Button { pick(g, L); subPicking = g.id } label: { Label(LS("选择子类"), systemImage: "list.bullet").labelStyle(ControlLabelStyle()) } }
            Button { styling = StyleTarget(group: g) } label: { Label(LS("更换图标"), systemImage: "photo").labelStyle(ControlLabelStyle()) }
            Button { newTitle = store.catStyle.titles[g.id] ?? ""; renaming = g } label: { Label(LS("改名"), systemImage: "pencil").labelStyle(ControlLabelStyle()) }
            Button(role: .destructive) { store.catStyle.hidden.append(g.id) } label: { Label(LS("从宫格隐藏"), systemImage: "eye.slash").labelStyle(ControlLabelStyle()) }
        })
    }

    @ViewBuilder
    private func grid(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let root = Store.categoryRoot(d.kind)
        let groups = store.gridGroups(root, D)
        let picked = d.account.hasPrefix(root) ? catOf(d.account) : nil
        let top = shownGroups(groups, picked: picked)
        let cells = top.map { g in GridCell(id: g.id, icon: store.catIcon(Store.cellKey(g)), title: store.catTitle(g, L), single: g.single) }
            + (groups.count > top.count || !groups.isEmpty ? [GridCell(id: Self.allCell, icon: "square.grid.2x2", title: LS("全部"), single: true)] : [])
        if groups.isEmpty {
            Text(LS("账本里还没有%@科目，可在「账户」里新建。", d.kind == .income ? LS("收入") : LS("支出")))
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            CategoryGridView(cells: cells, picked: picked, large: typeSize.isAccessibilitySize, tap: { id in
                if id == Self.allCell { field = nil; allCategories = true; return }
                guard let g = groups.first(where: { $0.id == id }) else { return }
                // the picked group again: its sub-categories
                if id == picked && !g.single { subPicking = id } else { pick(g, L) }
            }, menu: { id in
                guard let g = groups.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
                return cellMenu(g, L)
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

    /// 全部分类: every group, searchable, its sub-categories below; the choice goes back to the card
    private func allCategoriesPage(_ L: Ledger, _ D: Derived) -> some View {
        let root = Store.categoryRoot(store.draft.kind)
        let groups = store.gridGroups(root, D)
        return AllCategoriesView(
            groups: groups,
            common: Array(groups.prefix(Self.shownCategories)),
            current: store.draft.account.hasPrefix(root) ? store.draft.account : nil,
            L: L,
            menu: { cellMenu($0, L) },
            manage: { managingCats = true }
        ) { a in
            store.draft.account = a
            store.draft.edited = nil
            pickedCategory = true
            allCategories = false
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
        Haptics.selection()
    }

    // MARK: 转账

    /// 转出 and 转入 as two account cards, 对调 between them; the fee is set in 币种、汇率与手续费 (its line shows under
    /// the amount once there is one)
    private func transferPanel(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let incoming = d.to.isEmpty ? nil : (conversionCurrency(d, L, D) ?? d.currency)
        let sent = evalAmount(d.amount)
        let received = incoming == nil || incoming == d.currency ? sent : evalAmount(d.toAmount)
        // the fee where it changes these two balances: charged on top from 转出, or taken off what 转入 receives
        let fee = evalAmount(d.transferFee ?? "") ?? 0
        let out = sent.map { $0 + (d.feeMode == .added && (d.feeCurrency ?? d.currency) == d.currency ? fee : 0) }
        let into = received.map { $0 - (d.feeMode == .deducted && (d.feeCurrency ?? incoming) == incoming ? fee : 0) }
        return VStack(spacing: AppSpacing.icon) {
            transferCard(LS("转出"), d.funding, currency: d.currency, change: out.map { -$0 }, arriving: nil, L) { picking = .from }
            ZStack {
                if !d.funding.isEmpty && !d.to.isEmpty {
                    Button { swapTransfer(L, D) } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.onJade)
                            .frame(width: 34, height: 34)
                            .background(Color.jade, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LS("对调"))
                    .accessibilityIdentifier("transfer.swap")
                }
                // the same account, another currency: 换汇 within it
                if !d.funding.isEmpty && d.funding == d.to, let c = incoming {
                    HStack {
                        Spacer()
                        Text(LS("同账户换汇 %@ → %@", d.currency, c)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: d.funding.isEmpty || d.to.isEmpty ? 0 : 34)
            transferCard(LS("转入"), d.to, currency: incoming ?? d.currency, change: into, arriving: incoming == d.currency ? nil : incoming, L) { picking = .to }
        }
    }

    private func swapTransfer(_ L: Ledger, _ D: Derived) {
        var x = store.draft
        let outgoing = x.currency
        let incoming = conversionCurrency(x, L, D) ?? outgoing
        (x.funding, x.to) = (x.to, x.funding)
        x.currency = incoming
        x.targetCurrency = outgoing
        if incoming != outgoing { (x.amount, x.toAmount) = (x.toAmount, x.amount) }
        x.fxRate = nil
        x.edited = nil
        store.draft = x
        Haptics.selection()
    }

    /// one side of a transfer: the account's icon and name, its last digits and balance, the balance after this
    /// transfer once there is an amount; a dashed card before one is chosen
    private func transferCard(_ label: String, _ a: String, currency: String, change: Double?, arriving: String?, _ L: Ledger,
                              tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: AppSpacing.control) {
                if a.isEmpty {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.jade).frame(width: 36, height: 36)
                    Text(label == LS("转出") ? LS("选择转出账户") : LS("选择转入账户")).foregroundStyle(Color.jade)
                    Spacer()
                } else {
                    let mark = accountMark(store, a)
                    Image(systemName: mark.symbol).font(.body.weight(.semibold)).foregroundStyle(mark.color)
                        .frame(width: 36, height: 36)
                        .background(mark.color.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(accountTitle(L, a)).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        Text(transferDetail(a, currency: currency, change: change, arriving: arriving, L))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            .sensitive()
                    }
                    Spacer(minLength: AppSpacing.icon)
                    Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
            .frame(minHeight: 56)
            .background {
                if a.isEmpty {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Color.jade.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("draft.account." + label)
        .accessibilityValue(a)
    }

    /// "尾号 6666 · 余额 ¥152,421 → ¥151,421", "欠款 ¥2,195 · 到账 HKD"
    private func transferDetail(_ a: String, currency: String, change: Double?, arriving: String?, _ L: Ledger) -> String {
        var parts: [String] = []
        if let tail = store.repoConfig?.scanCards?.first(where: { $0.value == a && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) })?.key {
            parts.append(LS("尾号 %@", tail))
        }
        let now = L.final[a]?[currency] ?? 0
        let owing = a.hasPrefix("Liabilities:")
        func show(_ v: Double) -> String { money(owing ? -v : v, currency, 0) }
        var balance = (owing ? LS("欠款 ") : LS("余额 ")) + show(now)
        if let c = change, abs(c) > 0.005 { balance += " → " + show(now + c) }
        parts.append(balance)
        if let c = arriving { parts.append(LS("到账 %@", c)) }
        return parts.joined(separator: " · ")
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
                pickedFunding = true
                store.draft.funding = a
                store.draft.currency = store.D?.acctCcy[a] ?? store.draft.currency
                store.draft.edited = nil
            }
        case .to:
            AccountPicker(title: LS("转入"), prefixes: ["Assets:", "Liabilities:"], current: d.to,
                          hints: d.funding.isEmpty ? [:] : [d.funding: LS("同账户换汇")]) { a in
                store.draft.to = a; store.draft.edited = nil
            }
        }
    }

    // MARK: the bottom: choices, amount, keypad (or the text fields while typing)

    private func bottomPanel(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        VStack(spacing: AppSpacing.icon) {
            amountCard(d, L, D)
            if !writing {
                choices(d, L, D)
                keypad(d)
            }
        }
        .padding(.horizontal, AppSpacing.control)
        .padding(.top, AppSpacing.icon)
        .padding(.bottom, AppSpacing.detail)
        .background(Color(.systemGroupedBackground))
        // the part that never moves keeps its size with the largest text; the scrolling part above follows it all the way
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// 保存至 <ledger>: a cell beside the day, when there is more than one ledger on this phone (and not while editing)
    private var showsLedger: Bool { store.sources.count > 1 && store.draft.replacing == nil }

    private var ledgerMenu: some View {
        Menu {
            Section(LS("保存至")) {
                ForEach(store.sources) { s in
                    Button {
                        guard s.id != store.cfg.id else { return }
                        Task {
                            await store.switchLedger(s.id)
                        }
                    } label: {
                        if s.id == store.cfg.id { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            }
        } label: {
            HStack(spacing: AppSpacing.icon) {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
                Text(store.cfg.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LS("保存至"))
        .accessibilityValue(store.cfg.title)
    }

    /// the picked group's other accounts, one tap each, and the path picked ("餐饮 › 咖啡") on the right
    @ViewBuilder
    private func subCategories(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let root = Store.categoryRoot(d.kind)
        if d.account.hasPrefix(root), let g = store.gridGroups(root, D).first(where: { $0.id == catOf(d.account) }), !g.single {
            HStack(spacing: AppSpacing.icon) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.icon) {
                        ForEach(g.accounts, id: \.self) { a in
                            Chip(label: leafTitle(L, a), systemImage: store.catIcon(a), selected: a == d.account) {
                                store.draft.account = a
                                store.draft.edited = nil
                                pickedCategory = true
                                Haptics.selection()
                            }
                        }
                    }
                }
                Text(store.catTitle(g, L) + " › " + leafTitle(L, d.account))
                    .font(.caption).foregroundStyle(Color.jade).lineLimit(1).fixedSize()
            }
        }
    }

    /// a sub-category's own name: its display name, or the last part of the account
    private func leafTitle(_ L: Ledger, _ a: String) -> String {
        if let n = store.displayName(a), !n.isEmpty { return n }
        return a.components(separatedBy: ":").last ?? a
    }

    /// the last four digits a card is known by (ledger-x.json scan_cards), for the paying account's line
    private func cardTail(_ a: String) -> String? {
        store.repoConfig?.scanCards?.first { $0.value == a && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) }?.key
    }

    // MARK: the paying account and the day; 报销 · 优惠 · 标签 · 更多

    /// one card: the paying account, the day and the ledger saved to, side by side in equal parts; then the
    /// marks, each a third (or a quarter with 更多)
    private func choices(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if d.kind != .transfer {
                    fundingMenu(d, L, D).frame(maxWidth: .infinity)
                    Divider().frame(height: 26)
                }
                Button { dating = true } label: {
                    HStack(spacing: AppSpacing.icon) {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text(dayLabel(d.date)).lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .sheet(isPresented: $dating) {
                    DaySheet(date: Binding(get: { store.draft.date }, set: { store.draft.date = $0; store.draft.edited = nil })) { dating = false }
                        .presentationDetents([.height(500)])
                }
                if showsLedger {
                    Divider().frame(height: 26)
                    ledgerMenu.frame(maxWidth: .infinity)
                }
            }
            Divider().padding(.horizontal, AppSpacing.control)
            HStack(spacing: 0) {
                if d.kind == .expense { reimbChip(d, D); Divider().frame(height: 20) }
                if discountAllowed(d) {
                    let v = evalAmount(d.discount) ?? 0
                    Button { splittingPay = true } label: {
                        mark(v > 0 ? LS("优惠 %@", money(v, d.currency)) : LS("优惠"), icon: "gift", on: v > 0)
                    }
                    .buttonStyle(.plain)
                    Divider().frame(height: 20)
                }
                markChip(d, L)
                if let more = moreMenu(d, L) { Divider().frame(height: 20); more }
            }
        }
        .font(.subheadline)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 更多: AA, 组合付款, 本期补差 and 填写对方 where they apply (nil when none does)
    private func moreMenu(_ d: Draft, _ L: Ledger) -> AnyView? {
        let aa = d.kind == .expense && !d.reimb
        let combo = d.kind == .expense
        let topup = d.kind == .expense && store.ownedSubLinks.contains(d.link.trimmed)
        let person = d.kind != .transfer && (isPersonal(d.account) || isPersonal(d.funding))
        guard aa || combo || topup || person else { return nil }
        let on = d.topup || hasCombo(d) || !d.person.trimmed.isEmpty
        return AnyView(Menu {
            if aa {
                Button { store.draft.split = true; store.draft.edited = nil; openFull() } label: { Label(LS("AA 分摊…"), systemImage: "person.2") }
            }
            if combo { Button { splittingPay = true } label: { Label(LS("组合付款…"), systemImage: "square.split.2x1") } }
            if topup {
                Button { store.draft.topup.toggle(); store.draft.edited = nil } label: {
                    Label(LS("本期补差"), systemImage: d.topup ? "checkmark" : "plus.forwardslash.minus")
                }
            }
            if person {
                Button { openFull() } label: { Label(d.person.trimmed.isEmpty ? LS("填写对方…") : LS("对方：%@", d.person), systemImage: "person") }
            }
        } label: {
            mark(LS("更多"), icon: "ellipsis.circle", on: on)
        })
    }

    private func fundingMenu(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let funds = Array(D.rankAccounts(["Assets:", "Liabilities:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(8))
        let others = d.kind == .expense ? d.extraFunds.filter { !$0.account.isEmpty }.count : 0
        let title = (d.funding.isEmpty ? (d.kind == .income ? LS("收款账户") : LS("付款账户")) : accountTitle(L, d.funding))
            + (cardTail(d.funding).map { " · " + $0 } ?? "")
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
            Button { picking = .funding } label: { Label(LS("更多账户…"), systemImage: "building.columns") }
            if d.kind == .expense {
                Button { splittingPay = true } label: { Label(LS("组合付款…"), systemImage: "square.split.2x1") }
            }
        } label: {
            HStack(spacing: AppSpacing.icon) {
                Image(systemName: d.funding.isEmpty ? "creditcard" : store.groupIcon(d.funding).symbol).foregroundStyle(Color.jade)
                Text(title).foregroundStyle(d.funding.isEmpty ? Color.secondary : Color.primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.kind == .income ? LS("收款账户") : LS("付款账户"))
        .accessibilityValue(title)
    }

    /// one of 报销 · 优惠 · 标签 · 更多: an icon over nothing, its name beside it, in the theme's colour when set
    private func mark(_ text: String, icon: String, on: Bool) -> some View {
        HStack(spacing: AppSpacing.icon) {
            Image(systemName: icon).font(.footnote)
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(on ? Color.jade : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.icon)
        .contentShape(Rectangle())
    }

    /// 标记: the entry's tags, its events and 待确认 (!) in one place; the chip says what is set
    private func markChip(_ d: Draft, _ L: Ledger) -> some View {
        let evs = d.kind == .transfer ? [] : ledgerEvents(L, today: d.date).filter { d.events.contains($0.tag) }.map { $0.title }
        let parts = evs + d.tags.map { "#" + $0 } + (d.flag == "!" ? ["!"] : [])
        return Button { marking = true } label: {
            mark(parts.isEmpty ? LS("标签") : parts.joined(separator: " "), icon: "tag", on: !parts.isEmpty)
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
            mark(label + (d.reimb && !d.voucher.isEmpty ? " · " + d.voucher : ""), icon: d.reimb ? "checkmark.circle.fill" : "doc.text", on: d.reimb)
        }
    }

    // MARK: amount

    private func amountCard(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let other = conversionCurrency(d, L, D)
        let cross = other != nil && other != d.currency && !(d.kind != .transfer && hasCombo(d))
        return VStack(alignment: .leading, spacing: AppSpacing.icon) {
            Text(d.kind == .income ? LS("收入金额") : d.kind == .transfer ? LS("转出金额") : LS("支出金额"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: AppSpacing.icon) {
                Text(SYM[d.currency] ?? "").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(kindColor)
                // smaller as the expression grows (a fixed size each step, so it doesn't wobble while typing)
                Text(d.amount.isEmpty ? "0.00" : d.amount)
                    .font(.system(size: d.amount.count <= 10 ? 38 : d.amount.count <= 15 ? 28 : 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(d.amount.isEmpty ? Color.secondary.opacity(0.5) : kindColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(LS("金额"))
                    .accessibilityValue(d.amount.isEmpty ? "0" : d.amount)
                if isExpression(d.amount) {
                    Text("= " + (evalAmount(d.amount).map { fmtNum($0) } ?? "?")).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                // the currency, and the rate when the account is in another one
                Button { field = nil; writing = false; hideKeyboard(); rating = true } label: {
                    HStack(spacing: AppSpacing.detail) {
                        Text(d.currency).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(d.kind == .expense || d.kind == .transfer ? LS("币种、汇率与手续费") : LS("币种与汇率"))
                .accessibilityValue(d.currency)
                .accessibilityIdentifier("draft.rate")
            }
            if cross, let o = other {
                // the rate as the draft has it ("1 USD = 6.70408 CNY"); the sheet fills it in
                Button { field = nil; writing = false; hideKeyboard(); rating = true } label: {
                    Label(draftRate(d).map { "1 \(d.currency) = \(rateString($0)) \(o)" } ?? LS("填汇率…"), systemImage: "arrow.left.arrow.right").labelStyle(ControlLabelStyle())
                        .font(.footnote)
                        .foregroundStyle(draftRate(d) == nil ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            if d.kind == .expense || d.kind == .transfer, let fee = evalAmount(d.transferFee ?? ""), fee > 0 {
                Button { field = nil; writing = false; hideKeyboard(); feeEditing = true } label: {
                    Label(LS("手续费 %@", money(fee, d.feeCurrency ?? other ?? d.currency)), systemImage: "percent")
                        .labelStyle(ControlLabelStyle()).font(.footnote).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(d.kind == .transfer ? "transfer.fee" : "expense.fee")
                .accessibilityValue(d.transferFee ?? "")
            }
            if !writing, let s = comboSummary(d, L) {
                let issue = comboIssue(d, L, D)
                Label(issue ?? s, systemImage: issue == nil ? "square.split.2x1" : "exclamationmark.triangle").labelStyle(ControlLabelStyle())
                    .font(.footnote).foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .onTapGesture { splittingPay = true }
            }
            if attemptedSave, d.edited == nil, let issue = draftIssue(d, L, D) {
                Button { locate(issue) } label: {
                    Label(issue.message, systemImage: "exclamationmark.circle.fill").labelStyle(ControlLabelStyle())
                        .font(.footnote).foregroundStyle(Color.loss)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quick.validation")
            }
            Divider()
            if writing {
                textFields(d, D)
            } else {
                merchantRow(d, L)
            }
        }
        .padding(AppSpacing.control)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 瑞幸咖啡 · 冰美式: who and what for in one line; tap to type them
    private func merchantRow(_ d: Draft, _ L: Ledger) -> some View {
        let summary = [d.payee.trimmed, d.narration.trimmed].filter { !$0.isEmpty }.joined(separator: " · ")
        let icon = d.account.isEmpty ? "storefront" : store.catIcon(catOf(d.account))
        return Button { startWriting(d.payee.trimmed.isEmpty ? .payee : .narration) } label: {
            HStack(spacing: AppSpacing.icon) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    if summary.isEmpty {
                        Text(d.kind == .income ? LS("付款方 · 备注") : LS("商户 · 备注")).foregroundStyle(.secondary)
                    } else {
                        if !d.payee.trimmed.isEmpty { Text(d.payee).lineLimit(2) }
                        if !d.narration.trimmed.isEmpty { Text(d.narration).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LS("收付款方与备注"))
        .accessibilityValue(summary)
    }

    /// show the payee and description fields, then put the cursor in one (a field can only be focused once it exists)
    private func startWriting(_ f: Field) {
        writing = true
        DispatchQueue.main.async { field = f }
    }

    /// 今天, 昨天, or the day ("10月14日"; with the year when it isn't this year's)
    private func dayLabel(_ day: String) -> String {
        let today = Day.today()
        if day == today { return LS("今天") }
        if day == Day.shift(today, -1) { return LS("昨天") }
        let m = Int(day.dropFirst(5).prefix(2)) ?? 0, dd = Int(day.suffix(2)) ?? 0
        return day.prefix(4) == today.prefix(4) ? LS("%@月%@日", String(m), String(dd)) : day
    }

    /// Text fields only; their candidates live in the dedicated keyboard-safe bar.
    @ViewBuilder
    private func textFields(_ d: Draft, _ D: Derived) -> some View {
        let narrs = Array((D.payee(d.payee.trimmed)?.narrations ?? []).prefix(6))
        labeled(LS("收付款方")) {
            TextField(LS("如 便利店、淘宝，可不填"), text: Binding(get: { store.draft.payee }, set: { updateText(\.payee, $0) }))
                .focused($field, equals: .payee)
                .id(Field.payee)
                .accessibilityIdentifier("quick.payee")
                .submitLabel(.next)
                .onSubmit { applyPayee(store.draft.payee.trimmed, onlyBlanks: false); field = .narration }
        }
        labeled(LS("备注")) {
            TextField(narrs.first.map { LS("如 %@，可不填", $0) } ?? LS("买了什么、做什么用，可不填"),
                      text: Binding(get: { store.draft.narration }, set: { updateText(\.narration, $0) }))
                .focused($field, equals: .narration)
                .id(Field.narration)
                .accessibilityIdentifier("quick.narration")
                .submitLabel(.done)
                .onSubmit { field = nil; writing = false }
        }
    }

    /// A dedicated keyboard-safe area keeps candidates tappable on small screens.
    private func textSuggestions(_ d: Draft, _ D: Derived) -> some View {
        HStack(spacing: AppSpacing.icon) {
            if field == .payee {
                let q = d.payee.trimmed
                let items = Array(D.payees.lazy.filter { q.isEmpty || fuzzy(q, $0.name) > 0 }.prefix(8))
                ChipRow {
                    ForEach(items, id: \.name) { p in
                        Chip(label: p.name) { applyPayee(p.name, onlyBlanks: false); field = .narration }
                            .accessibilityIdentifier("quick.payee.suggestion")
                    }
                }
            } else {
                let narrs = Array((D.payee(d.payee.trimmed)?.narrations ?? []).prefix(6))
                ChipRow {
                    ForEach(narrs, id: \.self) { n in
                        Chip(label: n, selected: d.narration == n) { updateText(\.narration, n) }
                            .accessibilityIdentifier("quick.narration.suggestion")
                    }
                }
            }
            Button { field = nil; writing = false; hideKeyboard(); store.persistActiveDraft() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }
                .fontWeight(.semibold).padding(.vertical, AppSpacing.icon)
                .accessibilityIdentifier("quick.text.done")
        }
        .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func updateText(_ key: WritableKeyPath<Draft, String>, _ value: String) {
        var next = store.draft
        next[keyPath: key] = value
        next.edited = nil
        guard next != store.draft else { return }
        store.draft = next
    }

    private func labeled<F: View>(_ label: String, @ViewBuilder _ f: () -> F) -> some View {
        HStack(spacing: AppSpacing.control) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            f()
        }
        .padding(.vertical, AppSpacing.detail)
    }

    /// a payee picked by hand (or typed and left) fills in its usual category and account; ones picked here stay
    private func applyPayee(_ name: String, onlyBlanks: Bool) {
        guard !name.isEmpty, store.D?.payee(name) != nil else { return }
        store.applyPayee(name, onlyBlanks: onlyBlanks)
    }

    // MARK: keypad

    private func keypad(_ d: Draft) -> some View {
        let expr = isExpression(d.amount)
        return Grid(horizontalSpacing: AppSpacing.icon, verticalSpacing: AppSpacing.icon) {
            GridRow { digit("1"); digit("2"); digit("3"); KeyCap(systemImage: "delete.left", label: LS("退格"), tap: { key("⌫") }, hold: { setAmount("") }) }
            GridRow { digit("4"); digit("5"); digit("6"); KeyCap(text: "+  ×", label: LS("加，长按为乘"), tap: { key("+") }, hold: { key("×") }) }
            GridRow { digit("7"); digit("8"); digit("9"); KeyCap(text: "−  ÷", label: LS("减，长按为除"), tap: { key("-") }, hold: { key("÷") }) }
            GridRow {
                digit(".")
                digit("0")
                if d.replacing != nil {
                    // editing: there is no next one; its text instead.
                    // The 更多 menu has another control with this same title, so the key has its own id.
                    KeyCap(text: LS("源文本"), font: .system(size: 16, weight: .semibold), tap: { editingText = true })
                        .accessibilityIdentifier("quick.keypad.source")
                } else {
                    KeyCap(text: LS("保存再记"), font: .system(size: 16, weight: .semibold), tint: saveTint, soft: true, tap: { submit(close: false) })
                }
                KeyCap(text: expr ? "=" : LS("保存"), font: .system(size: expr ? 24 : 17, weight: .semibold), filled: true,
                       tint: saveTint, tap: { expr ? equals() : submit(close: true) })
                    .accessibilityLabel(expr ? "=" : d.replacing != nil ? LS("保存修改") : LS("保存并关闭"))
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
        Haptics.selection()
        setAmount(a)
    }

    private func equals() {
        guard let v = evalAmount(store.draft.amount) else { return }
        Haptics.selection()
        setAmount(v > 0 ? jsNumberString(roundTo(v, 2)) : "")
    }

    private func locate(_ issue: DraftIssue) {
        field = nil; writing = false
        switch issue.field {
        case .fee: feeEditing = true
        case .category: allCategories = true
        case .funding: picking = store.draft.kind == .transfer ? .from : .funding
        case .to: picking = .to
        case .rate, .paid, .toAmount: rating = true
        case .combined: splittingPay = true
        case .date: dating = true
        default: break
        }
    }

    private func submit(close: Bool) {
        guard !saving else { return }
        if isExpression(store.draft.amount) { equals() }
        attemptedSave = true
        if store.draft.edited == nil, let L = store.L, let D = store.D, let issue = draftIssue(store.draft, L, D) {
            Haptics.error(); store.show(issue.message)
            locate(issue)
            return
        }
        field = nil
        writing = false
        saving = true
        Task {
            let ok = await store.saveDraft {
                // Close as soon as the change is in the local queue. Rebuild and the balance
                // line continue after the card is gone.
                if close { store.adding = false }
            }
            saving = false
            guard ok else { return }
            attemptedSave = false
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

/// the category grid: four to a row (three with the largest text). Equatable, so typing an amount (which changes
/// nothing here) doesn't redraw it
struct CategoryGridView: View, Equatable {
    let cells: [GridCell]
    let picked: String?
    var large = false
    let tap: (String) -> Void
    let menu: (String) -> AnyView

    static func == (a: CategoryGridView, b: CategoryGridView) -> Bool { a.cells == b.cells && a.picked == b.picked && a.large == b.large }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.icon, alignment: .top), count: large ? 3 : 4), spacing: AppSpacing.control) {
            ForEach(cells, id: \.id) { c in cell(c, selected: c.id == picked) }
        }
    }

    private func cell(_ c: GridCell, selected: Bool) -> some View {
        Button { tap(c.id) } label: {
            VStack(spacing: AppSpacing.icon) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: c.icon)
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 54, height: 54)
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
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.jade : Color.secondary)
                    // a long name on two lines rather than shrunk
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category." + c.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { menu(c.id) }
    }
}

/// 全部分类: the common ones in a row, then every category four to a row; search finds a category, a sub-category
/// or an account by any of its names. Picking a category shows its sub-categories below, with 使用「餐饮 · 咖啡」.
/// No keypad here: what was typed on the card stays as it was.
struct AllCategoriesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let groups: [CategoryGroup]
    let common: [CategoryGroup]
    /// the account picked on the card
    let current: String?
    let L: Ledger
    let menu: (CategoryGroup) -> AnyView
    let manage: () -> Void
    let use: (String) -> Void
    @State private var query = ""
    @State private var group: String?
    @State private var account: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                if query.trimmed.isEmpty {
                    Text(LS("常用分类")).font(.footnote).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.control) { ForEach(common) { g in cell(g).frame(width: 64) } }
                    }
                    Divider()
                    Text(LS("所有分类")).font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.icon, alignment: .top), count: typeSize.isAccessibilitySize ? 3 : 4), spacing: AppSpacing.control) {
                        ForEach(groups) { g in cell(g) }
                    }
                } else {
                    let hits = matches()
                    if hits.isEmpty { Text(LS("没有找到「%@」", query.trimmed)).foregroundStyle(.secondary).padding(.top, AppSpacing.content) }
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                        let (g, a) = hit
                        Button { choose(g, a); Haptics.selection() } label: {
                            HStack(spacing: AppSpacing.icon) {
                                Image(systemName: store.catIcon(Store.cellKey(g))).frame(width: 30, height: 30)
                                    .background(Color(.tertiarySystemFill), in: Circle())
                                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                    Text(store.catTitle(g, L) + (g.single ? "" : " › " + leaf(a))).foregroundStyle(.primary)
                                    Text(a).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if a == account { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(AppSpacing.content)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: LS("搜索分类"))
        .navigationTitle(LS("全部分类"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: manage) { Label(LS("管理"), systemImage: "slider.horizontal.3").labelStyle(ControlLabelStyle()) }
                Button(action: finish) { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.disabled(account == nil).fontWeight(.semibold)
            }
        }
        .safeAreaInset(edge: .bottom) { if let id = group, let g = groups.first(where: { $0.id == id }) { picker(g) } }
        .onAppear {
            if let c = current { group = catOf(c); account = c }
            if let q = store.demoEnv["LEDGER_CAT_QUERY"] { query = q }
        }
    }

    private func leaf(_ a: String) -> String {
        if let n = store.displayName(a), !n.isEmpty { return n }
        return a.components(separatedBy: ":").last ?? a
    }

    private func cell(_ g: CategoryGroup) -> some View {
        let on = group == g.id
        return Button {
            withAnimation(AppMotion.quick) { choose(g, nil) }
            Haptics.selection()
        } label: {
            VStack(spacing: AppSpacing.icon) {
                Image(systemName: store.catIcon(Store.cellKey(g)))
                    .font(.system(size: 22))
                    .frame(width: 54, height: 54)
                    .foregroundStyle(on ? Color.onJade : Color.primary)
                    .background(on ? Color.jade : Color(.secondarySystemGroupedBackground), in: Circle())
                Text(store.catTitle(g, L)).font(.footnote.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.jade : Color.secondary)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(g) }
    }

    /// a group, and an account in it (the one used last there when none is given)
    private func choose(_ g: CategoryGroup, _ a: String?) {
        group = g.id
        if let a = a { account = a }
        else if let c = current, catOf(c) == g.id { account = c }
        else { account = g.accounts.first }
    }

    private func finish() { if let a = account { use(a) } }

    /// the picked category's sub-categories and 使用「…」
    private func picker(_ g: CategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            Text(store.catTitle(g, L)).font(.headline)
            if !g.single {
                FlowLayout(spacing: AppSpacing.icon) {
                    ForEach(g.accounts, id: \.self) { a in
                        Chip(label: leaf(a), selected: account == a) { account = a }
                    }
                }
            }
            Button { finish() } label: {
                Label(LS("使用「%@」", store.catTitle(g, L) + (g.single || account == nil ? "" : " · " + leaf(account!))), systemImage: "checkmark").labelStyle(ControlLabelStyle())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large).fontWeight(.semibold)
            .disabled(account == nil)
        }
        .padding(AppSpacing.content)
        .background(.bar)
    }

    /// what the search finds: (group, account), the group's own name first
    private func matches() -> [(CategoryGroup, String)] {
        let q = query.trimmed.lowercased()
        var out: [(CategoryGroup, String)] = []
        for g in groups {
            let gName = store.catTitle(g, L).lowercased()
            for a in g.accounts {
                let names = [gName, leaf(a).lowercased(), a.lowercased(), acctDisplay(a).lowercased()]
                if names.contains(where: { $0.contains(q) }) { out.append((g, a)) }
            }
        }
        return out
    }
}

/// a group's sub-categories, to pick one
struct SubCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pending: String?
    let group: CategoryGroup
    let title: String
    let L: Ledger
    let current: String
    let pick: (String) -> Void

    var body: some View {
        NavigationStack {
            List(group.accounts, id: \.self) { a in
                Button { pending = a; Haptics.selection() } label: {
                    HStack(spacing: AppSpacing.control) {
                        Text(accountTitle(L, a)).foregroundStyle(Color.primary)
                        Spacer()
                        if a == (pending ?? current) { Image(systemName: "checkmark").foregroundStyle(Color.jade).fontWeight(.semibold) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { pick(pending ?? current); dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }
                        .disabled((pending ?? current).isEmpty)
                }
            }
        }
    }
}

/// the entry's day: 今天, 昨天, 前天 one tap away, any other on the calendar
struct DaySheet: View {
    @Binding var date: String
    let done: () -> Void

    var body: some View {
        let today = Day.today()
        let quick = [(LS("今天"), today), (LS("昨天"), Day.shift(today, -1)), (LS("前天"), Day.shift(today, -2))]
        NavigationStack {
            VStack(spacing: AppSpacing.control) {
                ActionRow(size: .small, items: quick.map { q in
                    ActionRow.Item(title: q.0, systemImage: "calendar", emphasis: date == q.1 ? .primary : .regular) {
                        date = q.1
                        done()
                    }
                }, containsLabel: true)
                DatePicker(LS("日期"), selection: Binding(get: { Day.date(date) ?? Date() }, set: { date = Day.string($0) }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.content)
            .padding(.top, AppSpacing.detail)
            .navigationTitle(LS("日期"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(action: done) { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) } }
        }
    }
}

/// 标记: the events of the entry's day (and any picked), its tags, and 待确认 (!)
struct MarkSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    var body: some View {
        MarkEditor(L: L, draft: store.draft)
    }
}

private struct MarkEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    @State var draft: Draft
    @State private var query = ""
    @State private var newTag = ""
    @State private var badTag = false

    var body: some View {
        let d = draft
        let evs = d.kind == .transfer ? [] : ledgerEvents(L, today: d.date).filter { ($0.entry != nil && $0.covers(d.date)) || d.events.contains($0.tag) }
        let eventTags = Set(evs.map { $0.tag })
        let skip: Set<String> = ["transfer", "fx", "reimbursed", "refund", "reimbursement"]
        let known = Array(Set(L.txns.suffix(2000).flatMap { $0.tags })).filter { t in !skip.contains(t) && !d.tags.contains(t) && !eventTags.contains(t) }.filter { query.isEmpty || fuzzy(query, $0) > 0 }.sorted()
        let suggestions = query.isEmpty ? Array(known.prefix(12)) : known
        NavigationStack {
            List {
                if !evs.isEmpty {
                    Section(LS("事件")) {
                        ForEach(evs) { e in
                            Button {
                                var x = draft
                                if let i = x.events.firstIndex(of: e.tag) { x.events.remove(at: i) } else { x.events.append(e.tag) }
                                x.eventsTouched = true
                                x.edited = nil
                                draft = x
                            } label: {
                                HStack(spacing: AppSpacing.control) {
                                    Label(e.title, systemImage: "flag").labelStyle(ControlLabelStyle()).foregroundStyle(Color.primary)
                                    Spacer()
                                    if d.events.contains(e.tag) { Image(systemName: "checkmark").foregroundStyle(Color.jade).fontWeight(.semibold) }
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(d.tags, id: \.self) { t in
                        HStack(spacing: AppSpacing.control) {
                            Text("#" + t)
                            Spacer()
                            Button { draft.tags.removeAll { $0 == t }; draft.edited = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: AppSpacing.control) {
                        TextField(LS("新标签，如 trip-shanghai"), text: $newTag)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit(addTag)
                        Button(action: addTag) { Label(LS("添加"), systemImage: "plus").labelStyle(ControlLabelStyle()) }.disabled(newTag.trimmed.isEmpty)
                    }
                    if !suggestions.isEmpty {
                        ChipRow { ForEach(suggestions, id: \.self) { t in Chip(label: "#" + t) { add(t) } } }
                    }
                } header: {
                    Text(LS("标签"))
                } footer: {
                    if badTag { Text(LS("标签只能用英文字母、数字和 - _ / .（Beancount 的规定）")).foregroundStyle(Color.warn) }
                }
                Section {
                    Toggle(LS("待确认（!）"), isOn: Binding(get: { draft.flag == "!" }, set: { draft.flag = $0 ? "!" : "*"; draft.edited = nil }))
                } footer: {
                    Text(LS("金额或分类还要核对的，记为待确认；明细里用 ! 可以找出来。"))
                }
            }
            .searchable(text: $query, prompt: LS("搜索标签"))
            .navigationTitle(LS("标记"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!newTag.trimmed.isEmpty || !sameDraftContent(draft, store.draft))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if !newTag.trimmed.isEmpty { addTag(); if badTag { return } }
                        if draft.tags != store.draft.tags || draft.events != store.draft.events
                            || draft.eventsTouched != store.draft.eventsTouched || draft.flag != store.draft.flag {
                            var updated = store.draft
                            updated.tags = draft.tags; updated.events = draft.events
                            updated.eventsTouched = draft.eventsTouched; updated.flag = draft.flag
                            updated.edited = nil
                            store.draft = updated
                        }
                        Haptics.selection(); dismiss()
                    } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold)
                }
            }
        }
    }

    private func addTag() { add(newTag); if !badTag { newTag = "" } }

    private func add(_ raw: String) {
        let t = raw.trimmed.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "-")
        // Beancount takes only these in a tag
        badTag = !t.isEmpty && t.range(of: #"^[A-Za-z0-9\-_/.]+$"#, options: .regularExpression) == nil
        guard !t.isEmpty, !badTag, !draft.tags.contains(t) else { return }
        draft.tags.append(t)
        draft.edited = nil
    }
}

/// a key of the 记一笔 keypad; `hold` is what a long press types (× on +, clear on ⌫)
struct KeyCap: View {
    var text: String? = nil
    var systemImage: String? = nil
    var label: String? = nil
    var font: Font = .system(size: 24, weight: .regular, design: .rounded)
    var filled = false
    /// the filled or soft key's colour (the theme's by default)
    var tint: Color? = nil
    /// a light key in the tint's colour (保存再记)
    var soft = false
    let tap: () -> Void
    var hold: (() -> Void)? = nil

    private var color: Color { tint ?? Color.jade }
    private var ink: Color {
        if filled { return tint == nil ? Color.onJade : Color.white }
        return soft ? color : Color.primary
    }
    private var fill: Color {
        if filled { return color }
        return soft ? color.opacity(0.14) : Color(.secondarySystemGroupedBackground)
    }

    var body: some View {
        Group {
            if let s = systemImage { Image(systemName: s).font(.system(size: 20, weight: .medium)) }
            else if let title = text, let symbol = actionSymbol {
                VStack(spacing: AppSpacing.detail) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    Text(title).font(font).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            else { Text(text ?? "").font(font).lineLimit(1).minimumScaleFactor(0.7) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .foregroundStyle(ink)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: tap)
        .onLongPressGesture(minimumDuration: 0.45) {
            if let h = hold { Haptics.selection(); h() } else { tap() }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? text ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
    }

    private var actionSymbol: String? {
        if text == LS("源文本") { return "chevron.left.forwardslash.chevron.right" }
        if text == LS("保存再记") { return "plus.circle" }
        if text == LS("保存") { return "checkmark" }
        return nil
    }
}

