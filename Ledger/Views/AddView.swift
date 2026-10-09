import SwiftUI
import LedgerKit

enum AddField: Hashable { case amount, toAmount, paid, payee, narration, link, tags, row(UUID) }

struct AddView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    @FocusState private var focus: AddField?
    @State private var confirmOverwrite: [Entry] = []
    @State private var showOverwrite = false
    @State private var managingTemplates = false
    @State private var editingText = false

    @State private var path = NavigationPath()
    @State private var importing = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L, let D = store.D { content(L, D) } else { ProgressView() }
            }
            .navigationTitle(LS("记账"))
            .toolbar {
                StandardToolbar()
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down.on.square") }
                        .accessibilityLabel(LS("导入账单"))
                }
            }
            .sheet(isPresented: $importing) { ImportView() }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0) }
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task { if store.demoEnv["LEDGER_IMPORT"] != nil { importing = true } }
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
        let v: Validation? = text.trimmed.isEmpty ? nil : validateText(text, L, single: d.kind != .raw)
        Form {
            if d.kind == .refund {
                refundBanner(d)
            } else {
                Section {
                    Picker(LS("类型"), selection: Binding(get: { store.draft.kind }, set: { setKind($0, D) })) {
                        ForEach(DraftKind.allCases.filter { $0 != .refund }) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if d.kind == .expense || d.kind == .income { templateSection(d.kind, L, D) }
            switch d.kind {
            case .multi: multiSection(L, D)
            case .raw: EmptyView()
            default: simpleSection(d, L, D)
            }
            previewSection(text, v, L)
            Section {
                Button {
                    Task { await save(L, D) }
                } label: {
                    Text(LS("保存")).frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.jade)
                .controlSize(.large)
                .disabled(!(v?.ok ?? false))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            recentSection(L, D)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { keyboardBar }
        }
        .confirmationDialog(LS("同一天已有余额断言"), isPresented: $showOverwrite, titleVisibility: .visible) {
            Button(LS("覆盖 %@ 条断言", confirmOverwrite.count), role: .destructive) { Task { await saveRaw(L, overwriteOK: true) } }
            Button(LS("取消"), role: .cancel) {}
        } message: {
            Text(confirmOverwrite.map { "\($0.date) \($0.account ?? "")" }.joined(separator: "\n"))
        }
        .sheet(isPresented: $managingTemplates) { TemplateManager() }
        .sheet(isPresented: $editingText) {
            TextEditSheet(title: LS("编辑源文本"), initial: text, validate: { t in validateText(t, L, single: true) }) { new in
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

    private func setKind(_ k: DraftKind, _ D: Derived) {
        var d = store.draft
        d.kind = k
        d.edited = nil
        if k == .transfer { d.currency = D.acctCcy[d.funding] ?? d.currency }
        if k == .multi && !d.rows.contains(where: { !$0.account.isEmpty }) {
            d.rows = [DraftRow(), DraftRow(account: d.funding, currency: D.acctCcy[d.funding] ?? "CNY")]
        }
        store.draft = d
    }

    private func applyPayee(_ name: String, _ D: Derived) {
        var d = store.draft
        d.payee = name
        d.edited = nil
        if let p = D.payee(name) {
            let t = p.last
            if d.kind == .multi {
                if !d.rows.contains(where: { !$0.amount.trimmed.isEmpty }) { d.rows = rowsFromTxn(t, withAmounts: false) }
            } else {
                let cat = t.postings.first { $0.account.hasPrefix(d.kind == .income ? "Income:" : "Expenses:") }
                let fund = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }
                if let cat = cat { d.account = cat.account; d.currency = cat.currency ?? d.currency }
                if let fund = fund, !fund.account.hasPrefix("Assets:Receivable") { d.funding = fund.account }
            }
        }
        store.draft = d
    }

    // MARK: 常用

    @ViewBuilder
    private func templateSection(_ kind: DraftKind, _ L: Ledger, _ D: Derived) -> some View {
        let list = Array(store.templateList.filter { $0.kind == (kind == .income ? .income : .expense) }.prefix(8))
        if !list.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(list) { x in templateChip(x, L, D) }
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

    private func templateChip(_ x: Template, _ L: Ledger, _ D: Derived) -> some View {
        HStack(spacing: 0) {
            Button {
                var d = store.newDraftFor(x.kind == .income ? .income : .expense)
                d.payee = x.payee; d.narration = x.narration; d.account = x.account; d.funding = x.funding; d.currency = x.currency
                d.amount = x.fixed.map { jsNumberString($0) } ?? ""
                store.draft = d
                if x.fixed == nil { focus = .amount }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if x.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.jade) }
                        Text(x.label).font(.subheadline.weight(.medium)).lineLimit(1)
                        if !x.payee.isEmpty && !x.narration.isEmpty { Text(x.narration).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    HStack(spacing: 4) {
                        Text(x.fixed.map { money($0, x.currency) } ?? LS("金额待填")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                        if x.due { Text(LS("本月未入账")).font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            if x.fixed != nil {
                Divider().frame(height: 28)
                Button { Task { await saveTemplateNow(x, L, D) } } label: {
                    Text(LS("入账")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.jade).padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("直接入账：%@", x.label))
            }
        }
        .background(x.due ? Color.orange.opacity(0.12) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private func saveTemplateNow(_ x: Template, _ L: Ledger, _ D: Derived) async {
        var d = store.newDraftFor(x.kind == .income ? .income : .expense)
        d.payee = x.payee; d.narration = x.narration; d.account = x.account; d.funding = x.funding; d.currency = x.currency
        d.amount = x.fixed.map { jsNumberString($0) } ?? ""
        d.date = Day.today()
        let text = draftText(d, L, D)
        guard let ops = store.makeOps(text, single: true), let ins = ops.first(where: { $0.kind == .insert }) else { return }
        let label = LS("已入账：%@ %@", x.label, money(x.fixed ?? 0, x.currency))
        await store.commit(ops, word: label, undo: { @MainActor in
            if store.pending.contains(where: { $0.id == ins.id }) {
                await store.dropPending(ins)
                store.show(LS("已撤销"))
                return
            }
            var rm = Op(kind: .remove, path: ins.path)
            rm.old = ins.text
            rm.label = LS("撤销：%@ %@", ins.date ?? "", ins.summary ?? "")
            await store.commit([rm], word: LS("已撤销"))
        })
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
        return FormContext(payeeStat: stat, catPrefix: catPrefix, cats: cats, funds: funds, fc: D.acctCcy[d.funding], tc: D.acctCcy[d.to])
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
            if d.kind == .expense { reimbSection(d, D) }
            if d.kind == .refund {
                Section(LS("关联")) {
                    TextField(LS("^refund-… 可留空"), text: field(\.link)).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
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
                        applyPayee(store.draft.payee.trimmed, D)
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
            if let fc = ctx.fc, fc != d.currency {
                LabeledContent(LS("实付 ") + fc) {
                    TextField(LS("账户实际扣款"), text: field(\.paid))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .paid)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func reimbSection(_ d: Draft, _ D: Derived) -> some View {
        let links = Array(D.openLinks.filter { $0.link.hasPrefix("reimburse") }.suffix(4))
        let hint = LS("关联 ^link，如 reimburse-work-") + Day.today().replacingOccurrences(of: "-", with: "")
        let reimb = Binding<Bool>(get: { store.draft.reimb }, set: { store.draft.reimb = $0; store.draft.edited = nil })
        return Section {
            Toggle(LS("可报销（计入应收款并标记 #reimbursed）"), isOn: reimb).tint(.jade)
            if d.reimb {
                TextField(hint, text: field(\.link))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !links.isEmpty {
                    ChipRow {
                        ForEach(links, id: \.link) { x in
                            Chip(label: x.link, selected: d.link == x.link) {
                                store.draft.link = x.link
                                store.draft.edited = nil
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func payeeSuggestions(_ q: String, _ D: Derived) -> some View {
        let t = q.trimmed
        let items = D.payees.filter { t.isEmpty || fuzzy(t, $0.name) > 0 }.prefix(6)
        if !(items.count == 1 && items.first?.name == t) && !items.isEmpty {
            ChipRow {
                ForEach(Array(items), id: \.name) { p in
                    Chip(label: p.name) { applyPayee(p.name, D); focus = .narration }
                }
            }
        }
    }

    // MARK: 分录

    @ViewBuilder
    private func multiSection(_ L: Ledger, _ D: Derived) -> some View {
        Section {
            DateField(value: field(\.date))
            TextField(LS("商户"), text: field(\.payee)).focused($focus, equals: .payee).onSubmit { applyPayee(store.draft.payee.trimmed, D) }
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
                TextEditor(text: Binding(get: { text }, set: { nv in store.draft.raw = nv }))
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minHeight: 220)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .tags)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(LS("直接输入 Beancount 指令，可一次输入多条，例如：\n2026-10-08 price USD 7.10 CNY\n2026-10-09 balance Assets:Cash 400.00 CNY"))
                                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false)
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
                    Text(o.amountText ?? "").monospacedDigit().sensitive()
                }
            }
            ForEach(recent, id: \.id) { t in
                NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) }
            }
        }
    }

    // MARK: save

    private func save(_ L: Ledger, _ D: Derived) async {
        let d = store.draft
        let text = draftText(d, L, D, explicit: store.explicitAmounts).trimmed
        let v = validateText(text, L, single: d.kind != .raw)
        guard v.ok else { store.show(v.msg ?? LS("内容校验未通过")); return }
        focus = nil
        if d.kind == .raw { await saveRaw(L, overwriteOK: false); return }
        if d.kind == .multi {
            guard let ops0 = store.makeOps(text, single: true), let ops = await store.review(ops0) else { return }
            var nd = store.newDraftFor(.multi)
            nd.date = d.date
            nd.rows = d.rows.map { r in var x = r; x.amount = ""; x.id = UUID(); return x }
            store.draft = nd
            await store.commit(ops, checked: true)
            return
        }
        guard var ops = store.makeOps(text, single: true) else { return }
        if let o = d.refundOf {
            var link = Op(kind: .link, path: o.path)
            link.headerLine = o.line; link.header = o.header; link.link = o.link; link.silent = true
            ops.append(link)
        }
        guard let checked = await store.review(ops) else { return }
        ops = checked
        var nd = store.newDraftFor(d.kind == .refund ? .expense : d.kind)
        nd.funding = d.funding
        nd.date = d.date
        nd.currency = D.acctCcy[d.funding] ?? "CNY"
        store.draft = nd
        await store.commit(ops, checked: true)
    }

    private func saveRaw(_ L: Ledger, overwriteOK: Bool) async {
        let text = store.draft.raw.trimmed
        let v = validateText(text, L, single: false)
        guard v.ok else { store.show(v.msg ?? LS("内容校验未通过")); return }
        if !overwriteOK {
            let dups = duplicateBalances(v.entries, L)
            if !dups.isEmpty { confirmOverwrite = dups; showOverwrite = true; return }
        }
        guard let ops0 = store.makeOps(alignText(text), single: false), let ops = await store.review(ops0) else { return }
        var nd = store.newDraftFor(.raw)
        nd.date = store.draft.date
        store.draft = nd
        await store.commit(ops, checked: true)
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
                                if x.pinned { store.tplPinned.removeAll { $0 == x.id } } else { store.tplPinned.append(x.id) }
                            }
                            .buttonStyle(.bordered).tint(x.pinned ? .jade : .gray).controlSize(.small)
                        }
                        .swipeActions {
                            Button(LS("隐藏"), role: .destructive) {
                                store.tplHidden.append(x.id)
                                store.tplPinned.removeAll { $0 == x.id }
                            }
                        }
                    }
                } footer: {
                    Text(LS("近 120 天内出现 3 次及以上的交易将自动列入；置顶项优先显示，左滑可隐藏。"))
                }
                if !store.tplHidden.isEmpty {
                    Button(LS("恢复 %@ 项已隐藏", store.tplHidden.count)) { store.tplHidden = [] }
                }
            }
            .navigationTitle(LS("常用交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() } } }
        }
    }
}
