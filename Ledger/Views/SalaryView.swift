import SwiftUI
import LedgerKit

struct SalaryDest: Hashable {}

/// a payslip to fill in, or a template to edit
struct PayslipTarget: Identifiable {
    let id = UUID()
    let template: PayslipTemplate
}

/// 工资: one payslip template per employer, this month's payslip, and each year's salary
struct SalaryView: View {
    @EnvironmentObject var store: Store
    @State private var filling: PayslipTarget?
    @State private var editing: PayslipTarget?
    @State private var openYear: String?

    var body: some View {
        List {
            if let L = store.L {
                let ts = store.effectiveConfig.payslips ?? []
                Section {
                    ForEach(ts) { t in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(t.employer).font(.headline)
                                Spacer()
                                Button(LS("模板")) { editing = PayslipTarget(template: t) }.font(.footnote).buttonStyle(.borderless)
                            }
                            if let e = lastPayslip(L, employer: t.employer) {
                                Text(LS("上次：%@ %@", e.date, e.narration)).font(.caption).foregroundStyle(.secondary)
                            }
                            Button {
                                filling = PayslipTarget(template: t)
                            } label: {
                                Label(LS("记一个月工资"), systemImage: "doc.text").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.jade)
                        }
                        .padding(.vertical, 4)
                    }
                    Button { editing = PayslipTarget(template: PayslipTemplate(employer: suggestedEmployer(L, ts))) } label: {
                        Label(LS("添加公司的工资条"), systemImage: "plus")
                    }
                } header: {
                    Text(LS("工资条"))
                } footer: {
                    Text(LS("每家公司一份模板：工资条上的项目、对应科目和收款账户，保存在账本的 ledger-x.json，所有设备共用。记工资时带出上个月的数字，改掉变了的几项即可。"))
                }
                let years = salaryYears(L)
                if !years.isEmpty {
                    Section(LS("每年")) {
                        ForEach(years, id: \.year) { y in yearRow(y) }
                    }
                }
            }
        }
        .navigationTitle(LS("工资"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $filling) { PayslipSheet(template: $0.template) }
        .sheet(item: $editing) { PayslipTemplateSheet(original: $0.template) }
    }

    private func suggestedEmployer(_ L: Ledger, _ ts: [PayslipTemplate]) -> String {
        let have = Set(ts.map { $0.employer })
        return L.txns.last { t in !t.payee.isEmpty && !have.contains(t.payee) && t.postings.contains { $0.account.hasPrefix("Income:Salary") } }?.payee ?? ""
    }

    private func yearRow(_ y: SalaryYear) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { openYear == y.year }, set: { openYear = $0 ? y.year : nil })) {
            ForEach(y.earnings.sorted { $0.value > $1.value }, id: \.key) { e in
                LabeledContent(acctLabel(e.key)) { Amount(n: e.value) }
            }
            if y.deductions > 0.005 { LabeledContent(LS("工资扣款")) { Amount(n: -y.deductions) } }
            if y.tax > 0.005 { LabeledContent(LS("个人所得税")) { Amount(n: -y.tax) } }
            LabeledContent(LS("实发合计")) { Amount(n: y.net) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LS("%@年", y.year))
                    Text(LS("%@ 个月有工资", y.months)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Amount(n: y.gross)
                    if y.months > 0 { Text(LS("月均 ") + money(y.gross / Double(y.months))).font(.caption).foregroundStyle(.secondary).sensitive() }
                }
            }
        }
    }
}

/// one month's payslip
struct PayslipSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let template: PayslipTemplate
    @State private var d: PayslipDraft?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D, d != nil { form(L, D) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(LS("%@ 工资", template.employer))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
            .onAppear {
                guard d == nil, let L = store.L else { return }
                let month = Day.addMonth(Day.ym(Day.today()), -1)
                d = payslipDraft(L, template: template, month: month, date: Day.today())
            }
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { d?.values[name] ?? "" }, set: { d?.values[name] = $0 })
    }

    private func form(_ L: Ledger, _ D: Derived) -> some View {
        let x = d!
        let text = payslipText(x, L, receivable: L.accounts.keys.filter(isSalaryClearing).sorted().first ?? "Assets:Receivable:Employer")
        let v = text.isEmpty ? nil : validateText(text, L, single: false)
        let taken = L.txns.contains { $0.links.contains(x.link) }
        return Form {
            Section {
                Stepper(value: Binding(get: { 0 }, set: { k in
                    guard var y = d else { return }
                    y.month = Day.addMonth(y.month, k)
                    d = y
                }), in: -1...1) {
                    LabeledContent(LS("工资月份"), value: x.month)
                }
                DateField(value: Binding(get: { d?.date ?? Day.today() }, set: { d?.date = $0 }))
                LabeledContent(LS("应出勤天数")) {
                    TextField("21", text: Binding(get: { d?.days ?? "" }, set: { d?.days = $0 }))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } footer: {
                if taken { Text(LS("^%@ 已经有记录，确认不是重复记账（补发请在「往来」里结清或另记）。", x.link)).foregroundStyle(Color.warn) }
                else { Text(LS("日期是到账那天。")) }
            }
            Section(LS("应发")) {
                ForEach(template.items.filter { !$0.deduct }) { i in itemRow(i) }
                LabeledContent(LS("应发工资")) { Amount(n: x.gross) }
            }
            Section(LS("扣款")) {
                ForEach(template.items.filter { $0.deduct }) { i in itemRow(i) }
            }
            Section {
                LabeledContent(LS("实发工资")) { Amount(n: x.net) }
                LabeledContent(LS("实际到账")) {
                    TextField(fmtNum(x.net), text: Binding(get: { d?.received ?? "" }, set: { d?.received = $0 }))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                }
                AccountField(label: LS("收款账户"), prefixes: ["Assets:"],
                             chips: Array(D.rankAccounts(["Assets:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(5)),
                             value: Binding(get: { d?.account ?? "" }, set: { d?.account = $0 }))
            } footer: {
                if abs(x.pending) > 0.004 {
                    Text(x.pending > 0 ? LS("少到账 %@，记入公司往来 ^%@，补发后在「往来」里对上", money(x.pending), x.link)
                                       : LS("多到账 %@，记入公司往来 ^%@，退回后对上", money(-x.pending), x.link))
                }
            }
            Section(LS("将写入")) {
                if text.isEmpty { Text(LS("填写应发金额和收款账户后生成")).font(.footnote).foregroundStyle(.secondary) }
                else {
                    MonoText(text: text)
                    if let m = v?.msg, v?.ok == false { Text(m).font(.footnote).foregroundStyle(Color.loss) }
                }
            }
            Section {
                Button { Task { await save(text) } } label: {
                    HStack { Spacer(); if saving { ProgressView() } else { Text(LS("保存")).fontWeight(.semibold) }; Spacer() }
                }
                .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large)
                .disabled(text.isEmpty || v?.ok != true || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func itemRow(_ i: PayslipItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(i.name)
                Text(acctLabel(i.account)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("0.00", text: binding(i.name))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                .frame(maxWidth: 140)
        }
    }

    private func save(_ text: String) async {
        guard !text.isEmpty, let x = d else { return }
        saving = true
        defer { saving = false }
        // the template remembers the account the pay went to
        if x.account != template.account {
            var c = store.effectiveConfig
            var ts = c.payslips ?? []
            if let k = ts.firstIndex(where: { $0.employer == template.employer }) { ts[k].account = x.account; c.payslips = ts }
            _ = await store.saveRepoConfig(c)
        }
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("%@ %@ 工资", template.employer, x.month)), single: false),
              let checked = await store.review(ops) else { return }
        dismiss()
        await store.commit(checked, checked: true)
    }
}

/// which items a payslip has, on which accounts, and where the pay goes
struct PayslipTemplateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let original: PayslipTemplate
    @State private var t = PayslipTemplate(employer: "")
    @State private var ready = false
    @State private var picking: Int?

    private var isNew: Bool { !(store.effectiveConfig.payslips ?? []).contains { $0.employer == original.employer } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(LS("公司（收付款方）")) {
                        TextField(LS("如 星河"), text: $t.employer).multilineTextAlignment(.trailing)
                    }
                    LabeledContent(LS("链接名")) {
                        TextField(t.linkSlug, text: Binding(get: { t.slug ?? "" }, set: { t.slug = $0 }))
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if let D = store.D {
                        AccountField(label: LS("收款账户"), prefixes: ["Assets:"],
                                     chips: Array(D.rankAccounts(["Assets:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(5)), value: $t.account)
                    }
                } footer: {
                    Text(LS("收付款方和账本里以前的工资记录一致时，记工资会带出上个月的金额。工资记录关联 ^salary-%@-年月。", t.linkSlug))
                }
                Section {
                    ForEach(t.items.indices, id: \.self) { k in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField(LS("项目名称"), text: $t.items[k].name)
                                Toggle(LS("扣款"), isOn: $t.items[k].deduct).fixedSize()
                            }
                            HStack {
                                Button { picking = k } label: {
                                    Text(t.items[k].account.isEmpty ? LS("选择科目") : t.items[k].account).font(.caption.monospaced())
                                }
                                .buttonStyle(.borderless)
                                Spacer()
                                TextField(LS("每月金额"), text: Binding(get: { t.items[k].amount.map { toFixed($0, 2) } ?? "" },
                                                                    set: { t.items[k].amount = evalAmount($0) }))
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                                    .font(.caption).frame(maxWidth: 110)
                            }
                        }
                    }
                    .onDelete { t.items.remove(atOffsets: $0) }
                    .onMove { t.items.move(fromOffsets: $0, toOffset: $1) }
                    Button { t.items.append(PayslipItem(name: "", account: "Income:Salary:Base")) } label: { Label(LS("添加项目"), systemImage: "plus") }
                } header: {
                    Text(LS("项目"))
                } footer: {
                    Text(LS("应发项记为收入，扣款项（请假、个税等）从应发里减去。几个项目可以记到同一个科目；还没有的科目在第一次记工资时开立。填了每月金额，记工资时按它带出（转正、调薪后改这里）；都不填则带出上个月的金额。左滑删除。"))
                }
                if !isNew {
                    Section {
                        Button(LS("删除这份模板"), role: .destructive) {
                            Task {
                                var c = store.effectiveConfig
                                c.payslips = (c.payslips ?? []).filter { $0.employer != original.employer }
                                if await store.saveRepoConfig(c) { dismiss() }
                            }
                        }
                    } footer: {
                        Text(LS("只删除模板，已记的工资不受影响。"))
                    }
                }
            }
            .keyboardDone()
            .navigationTitle(isNew ? LS("新的工资条") : original.employer)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { Task { await save() } }
                        .disabled(t.employer.trimmed.isEmpty || t.items.contains { $0.name.trimmed.isEmpty || !isAccountName($0.account) })
                }
            }
            .sheet(item: Binding(get: { picking.map { PickIndex(k: $0) } }, set: { picking = $0?.k })) { p in
                AccountPicker(title: LS("科目"), prefixes: ["Income:", "Expenses:", "Assets:", "Liabilities:"], current: t.items[p.k].account, allowAny: true) {
                    t.items[p.k].account = $0
                }
            }
            .onAppear {
                guard !ready else { return }
                ready = true
                t = original
            }
        }
    }

    private func save() async {
        t.employer = t.employer.trimmed
        for k in t.items.indices { t.items[k].name = t.items[k].name.trimmed }
        if (t.slug ?? "").trimmed.isEmpty { t.slug = nil }
        var c = store.effectiveConfig
        var ts = (c.payslips ?? []).filter { $0.employer != original.employer && $0.employer != t.employer }
        ts.append(t)
        c.payslips = ts
        if await store.saveRepoConfig(c) { dismiss() }
    }
}

private struct PickIndex: Identifiable { let k: Int; var id: Int { k } }
