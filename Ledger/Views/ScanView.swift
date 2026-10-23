import SwiftUI
import LedgerKit

/// 截图记账: what was read off the screenshot, row by row as on the screen (a tab between pieces on one row).
/// For now it is shown as read, to copy; turning it into an entry comes next.
struct ScanResultView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let result: ScanResult
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(ocrRows(result.boxes).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.control) {
                            ForEach(Array(row.enumerated()), id: \.offset) { i, b in
                                Text(b.text)
                                    .font(.callout)
                                    .foregroundStyle(i == 0 && row.count > 1 ? Color.secondary : Color.primary)
                                    .frame(maxWidth: i == 0 && row.count > 1 ? nil : .infinity, alignment: i == 0 ? .leading : .trailing)
                            }
                        }
                        .textSelection(.enabled)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: AppSpacing.icon) {
                        if let p = result.problem {
                            Label(p, systemImage: "exclamationmark.circle").labelStyle(ControlLabelStyle()).font(.subheadline).foregroundStyle(Color.warn)
                        }
                        Text(LS("识别出 %@ 行", String(ocrRows(result.boxes).count)))
                    }
                    .textCase(nil)
                } footer: {
                    Text(LS("在本机识别，截图读完即丢弃，没有保存或上传。认不出的版式可以复制这些文字发给开发者，用来完善自动填写。"))
                }
            }
            .navigationTitle(LS("识别结果"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("关闭"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        UIPasteboard.general.string = result.text
                        copied = true
                    } label: { Label(copied ? LS("已复制") : LS("复制"), systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(ControlLabelStyle()) }
                }
            }
        }
    }
}

/// on the 记一笔 card filled in from a screenshot: what to check, a payment that may already be recorded, the
/// purchase a refund goes back to, and the text that was read
struct ScanBanner: View {
    @EnvironmentObject var store: Store
    let info: ScanInfo
    @State private var showText = false

    private func name(_ c: ScanCheck) -> String {
        switch c {
        case .date: return LS("日期（截图上没有，按今天）")
        case .funding: return LS("付款账户")
        case .category: return LS("科目")
        case .charged: return LS("扣款金额（汇率暂按账本）")
        case .refundCategory: return LS("退回的科目（没找到原交易）")
        case .person: return LS("给个人的转账：支出还是借出")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            HStack(spacing: AppSpacing.control) {
                Label(LS("来自截图"), systemImage: "text.viewfinder").labelStyle(ControlLabelStyle()).font(.subheadline.weight(.semibold))
                Spacer()
                Button { showText = true } label: { Label(LS("识别文字"), systemImage: "text.viewfinder").labelStyle(ControlLabelStyle()) }.font(.footnote)
            }
            if !info.checks.isEmpty {
                Text(LS("请核对：%@", info.checks.map(name).joined(separator: LS("、"))))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let t = info.duplicate {
                Label(LS("账本里可能已有：%@ %@ %@", t.date, t.payee.isEmpty ? t.narration : t.payee, txAmountText(t)),
                      systemImage: "exclamationmark.triangle").labelStyle(ControlLabelStyle())
                    .font(.footnote).foregroundStyle(Color.warn)
            }
            if store.draft.kind == .refund && info.refundOf.count > 1 {
                Menu {
                    ForEach(info.refundOf.prefix(8), id: \.id) { t in
                        Button { store.scanRefund(of: t) } label: { Label(LS("%@ %@ %@", t.date, t.payee.isEmpty ? t.narration : t.payee, txAmountText(t)), systemImage: "arrow.uturn.backward") }
                    }
                } label: {
                    Label(store.draft.refundOf == nil ? LS("选择原交易（%@ 笔可能）", String(info.refundOf.count)) : LS("改选原交易"),
                          systemImage: "arrow.uturn.backward").font(.footnote)
                }
            }
        }
        .padding(AppSpacing.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.panel))
        .sheet(isPresented: $showText) { ScanResultView(result: ScanResult(boxes: info.boxes)) }
    }
}

/// what a transaction spent, for one line ("¥4.00")
func txAmountText(_ t: Entry) -> String {
    if let p = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = p.units { return money(abs(u), p.currency ?? "CNY") }
    if let p = t.postings.first(where: { ($0.units ?? 0) > 0 }), let u = p.units { return money(u, p.currency ?? "CNY") }
    return ""
}
