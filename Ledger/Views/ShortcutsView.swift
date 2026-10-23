import SwiftUI
import LedgerKit

/// 设置 → 快捷指令与 Apple Pay
struct ShortcutsSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var cards: [String: String] = Prefs.get(IntentPrefs.cardsKey, [String: String]())
    @State private var seen: [String] = Prefs.get(IntentPrefs.seenKey, [String]())
    @State private var newCard = ""

    var body: some View {
        List {
            Section {
                step(1, LS("打开「快捷指令」App →「自动化」→ 右上角 + →「钱包」。"))
                step(2, LS("选择要记账的卡片（可多选），勾选「立即运行」。"))
                step(3, LS("新建空白快捷指令，添加操作「快速记一笔」（Ledger X）。"))
                step(4, LS("金额选「快捷指令输入 → 金额」，收付款方选「商户」，卡片或付款方式选「卡片」或「名称」。"))
            } header: {
                Text(LS("Apple Pay 自动记账"))
            } footer: {
                Text(LS("每次用 Apple Pay 付款后自动入账：按该收付款方上一次的分类记账；第一次遇到的收付款方或提交前检查有问题时，会发通知请你确认。"))
            }

            Section {
                step(1, LS("在「快捷指令」App 新建快捷指令，添加「截屏」，再添加「截图记账」（Ledger X），截图选「截屏」的结果。"))
                step(2, LS("设置 → 辅助功能 → 触控 → 轻点背面，选这个快捷指令：付款完成页面上轻点两下手机背面即可。"))
                step(3, LS("也可以在快捷指令的详细信息里打开「在共享表单中显示」，在相册里选截图后从分享菜单运行。"))
            } header: {
                Text(LS("截图记账"))
            } footer: {
                Text(LS("在本机识别截图里的文字，截图读完即丢弃，不保存、不上传。"))
            }

            Section {
                ForEach(allCards, id: \.self) { c in
                    CardMappingRow(card: c, account: Binding(get: { cards[c] ?? "" }, set: { cards[c] = $0.isEmpty ? nil : $0; save() }))
                }
                .onDelete { idx in
                    for i in idx { let c = allCards[i]; cards[c] = nil; seen.removeAll { $0 == c } }
                    save()
                }
                HStack(spacing: AppSpacing.control) {
                    TextField(LS("卡片名称，如「招商银行信用卡」"), text: $newCard)
                    Button {
                        let n = newCard.trimmed
                        guard !n.isEmpty, !seen.contains(n) else { return }
                        seen.append(n); newCard = ""; save()
                    } label: { Label(LS("添加"), systemImage: "plus").labelStyle(ControlLabelStyle()) }
                    .disabled(newCard.trimmed.isEmpty)
                }
            } header: {
                Text(LS("卡片对应的付款账户"))
            } footer: {
                Text(LS("快捷指令传来的卡片名称会出现在这里。未设置时按银行名称自动匹配账户。"))
            }

            Section {
                row("square.and.pencil", LS("记一笔（在 App 中确认）"), LS("打开记账页并预填，核对后保存"))
                row("bolt.fill", LS("快速记一笔"), LS("直接入账，适合自动化"))
                row("text.viewfinder", LS("截图记账"), LS("识别付款截图，在 App 中确认"))
                row("chart.bar.xaxis", LS("本月支出"), LS("「嘿 Siri，Ledger X 本月支出」"))
                row("calendar.badge.clock", LS("待付款项"), LS("订阅、信用卡还款与资金预测"))
            } header: {
                Text(LS("可用的快捷指令操作"))
            } footer: {
                Text(LS("这些操作也可以放到操作按钮、主屏幕或 Siri 中使用。"))
            }
        }
        .navigationTitle(LS("快捷指令与 Apple Pay"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var allCards: [String] { Array(Set(seen).union(cards.keys)).sorted() }

    private func save() {
        Prefs.set(IntentPrefs.cardsKey, cards)
        Prefs.set(IntentPrefs.seenKey, seen)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.icon) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(Color.onJade)
                .frame(width: 22, height: 22).background(Color.jade, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: AppSpacing.icon) {
            IconBadge(symbol: symbol, color: .indigo, size: 28)
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CardMappingRow: View {
    @EnvironmentObject var store: Store
    let card: String
    @Binding var account: String
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: AppSpacing.control) {
                Text(card)
                Spacer()
                Text(account.isEmpty ? (guess.map { LS("自动：%@", acctLabel($0)) } ?? LS("选择")) : acctDisplay(account))
                    .foregroundStyle(account.isEmpty ? Color.secondary : Color.primary).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .sheet(isPresented: $picking) {
            AccountPicker(title: card, prefixes: ["Liabilities:", "Assets:"], current: account) { account = $0 }
        }
    }

    private var guess: String? {
        guard let L = store.L, let D = store.D else { return nil }
        return guessFunding(card, source: .bank, L, D)
    }
}
