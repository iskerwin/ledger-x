import SwiftUI
import LedgerKit

/// 组合付款 and 优惠 for the expense in the form: other accounts paying set parts, a discount recorded as income; the
/// main paying account pays what is left.
struct PaySplitSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var dm: DraftModel
    @Environment(\.dismiss) private var dismiss
    @State private var picking: Pick?

    enum Pick: Identifiable, Hashable {
        case extra(UUID), discount
        var id: String { switch self { case .extra(let u): return u.uuidString; case .discount: return "discount" } }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let L = store.L, let D = store.D { content(store.draft, L, D) }
            }
            .navigationTitle(LS("组合付款与优惠"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button { hideKeyboard() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) }
            }
            .sheet(item: $picking) { p in picker(p) }
        }
    }

    @ViewBuilder
    private func content(_ d: Draft, _ L: Ledger, _ D: Derived) -> some View {
        let rest = comboRest(d)
        Section {
            LabeledContent(LS("总额")) { Text(evalAmount(d.amount).map { money($0, d.currency) } ?? "—").monospacedDigit().sensitive() }
            LabeledContent(d.funding.isEmpty ? LS("主账户") : accountTitle(L, d.funding)) {
                Text(rest.map { LS("付余下的 %@", money(max(0, $0), d.currency)) } ?? LS("付余下的部分"))
                    .monospacedDigit().foregroundStyle(.secondary).sensitive()
            }
        } footer: {
            Text(LS("主账户就是记一笔里选的付款账户，自动支付扣除下面各项后余下的金额。"))
        }
        Section {
            ForEach(d.extraFunds) { x in extraRow(x, L) }
                .onDelete { idx in store.draft.extraFunds.remove(atOffsets: idx); store.draft.edited = nil }
            Button {
                store.draft.extraFunds.append(ExtraFund(account: ""))
                store.draft.edited = nil
            } label: { Label(LS("添加付款账户"), systemImage: "plus.circle").labelStyle(ControlLabelStyle()) }
        } header: {
            Text(LS("其他付款账户"))
        } footer: {
            Text(LS("每个账户填它付了多少，要与支出同币种；左滑删除。"))
        }
        if discountAllowed(d) {
            Section {
                HStack(spacing: AppSpacing.control) {
                    Text(LS("优惠金额"))
                    Spacer()
                    TextField("0.00", text: Binding(get: { store.draft.discount }, set: { store.draft.discount = $0; store.draft.edited = nil }))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(maxWidth: 140)
                }
                Button { picking = .discount } label: {
                    LabeledContent {
                        let t = accountTitle(L, d.discountAccount), l = acctLabel(d.discountAccount)
                        Text(t == l ? t : t + " · " + l).foregroundStyle(.primary).lineLimit(1)
                    } label: {
                        Label { Text(LS("记到")) } icon: { ChosenAccountIcon(account: d.discountAccount) }
                            .labelStyle(ControlLabelStyle())
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text(LS("优惠"))
            } footer: {
                Text(LS("立减、红包、券抵扣等没付的部分。支出按原价记，优惠记为收入，账本里能看到原价和省下的钱。"))
            }
        } else if d.kind == .expense {
            Section {
            } footer: {
                Text(LS("可报销或 AA 的支出不单列优惠，金额请直接填实付。"))
            }
        }
        if let issue = comboIssue(d, L, D) {
            Section { Label(issue, systemImage: "exclamationmark.triangle").labelStyle(ControlLabelStyle()).foregroundStyle(Color.warn).font(.footnote) }
        }
    }

    private func extraRow(_ x: ExtraFund, _ L: Ledger) -> some View {
        HStack(spacing: AppSpacing.control) {
            Button { picking = .extra(x.id) } label: {
                Label {
                    Text(x.account.isEmpty ? LS("选择账户") : accountTitle(L, x.account))
                        .foregroundStyle(x.account.isEmpty ? Color.secondary : Color.primary)
                } icon: {
                    ChosenAccountIcon(account: x.account)
                }
                .labelStyle(ControlLabelStyle())
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
            TextField("0.00", text: Binding(get: { x.amount }, set: { v in
                guard let i = store.draft.extraFunds.firstIndex(where: { $0.id == x.id }) else { return }
                store.draft.extraFunds[i].amount = v
                store.draft.edited = nil
            }))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(maxWidth: 120)
        }
    }

    @ViewBuilder
    private func picker(_ p: Pick) -> some View {
        switch p {
        case .extra(let id):
            AccountPicker(title: LS("付款账户"), prefixes: ["Assets:", "Liabilities:"],
                          current: store.draft.extraFunds.first { $0.id == id }?.account ?? "") { a in
                guard let i = store.draft.extraFunds.firstIndex(where: { $0.id == id }) else { return }
                store.draft.extraFunds[i].account = a
                store.draft.edited = nil
            }
        case .discount:
            AccountPicker(title: LS("优惠记到"), prefixes: ["Income:"], current: store.draft.discountAccount) { a in
                store.draft.discountAccount = a
                store.draft.edited = nil
            }
        }
    }
}

/// "支付宝 ¥50 + 招行 ¥40 · 优惠 ¥10": who pays what, for under the amount
@MainActor func comboSummary(_ d: Draft, _ L: Ledger) -> String? {
    guard hasCombo(d) else { return nil }
    var parts: [String] = []
    if let r = comboRest(d), r > 0.004, !d.funding.isEmpty { parts.append(accountTitle(L, d.funding) + " " + money(r, d.currency)) }
    for x in d.extraFunds where !x.account.isEmpty {
        parts.append(accountTitle(L, x.account) + " " + (evalAmount(x.amount).map { money($0, d.currency) } ?? "?"))
    }
    var s = parts.joined(separator: " + ")
    if discountAllowed(d), let v = evalAmount(d.discount), v > 0 { s += (s.isEmpty ? "" : " · ") + LS("优惠 %@", money(v, d.currency)) }
    return s
}
