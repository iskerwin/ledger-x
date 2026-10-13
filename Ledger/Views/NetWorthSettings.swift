import SwiftUI
import LedgerKit

extension Store {
    /// accounts left out of 净资产 and its trend (ledger-x.json, shared by every device)
    var netWorthExclude: [String] { repoConfig?.netWorthExclude ?? [] }
    /// accounts left out of 资产负债表
    var balanceExclude: [String] { repoConfig?.balanceExclude ?? [] }

    /// write both lists to ledger-x.json (one commit)
    @discardableResult
    func saveExclusions(netWorth: [String], balance: [String]) async -> Bool {
        var c = effectiveConfig
        c.netWorthExclude = netWorth.sorted()
        c.balanceExclude = balance.sorted()
        return await saveRepoConfig(c)
    }

    /// one account in or out of one of the lists
    func setExcluded(_ account: String, netWorth: Bool? = nil, balance: Bool? = nil) async {
        var nw = netWorthExclude, bs = balanceExclude
        if let on = netWorth { nw.removeAll { $0 == account }; if on { nw.append(account) } }
        if let on = balance { bs.removeAll { $0 == account }; if on { bs.append(account) } }
        await saveExclusions(netWorth: nw, balance: bs)
    }
}

/// 净资产与资产负债表: which asset and liability accounts count in each, picked separately
struct NetWorthSettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    enum Which: String, CaseIterable, Identifiable { case netWorth, balance; var id: String { rawValue } }
    @State var which: Which = .netWorth
    @State private var nw: Set<String> = []
    @State private var bs: Set<String> = []
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        List {
            if let L = store.L {
                Section {
                    Picker(LS("用于"), selection: $which) {
                        Text(LS("净资产")).tag(Which.netWorth)
                        Text(LS("资产负债表")).tag(Which.balance)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(which == .netWorth
                         ? LS("关掉的账户不计入概览、账户页和净资产走势里的净资产；账户本身照常显示和记账。")
                         : LS("关掉的账户不在资产负债表里列出，也不计入它的合计。"))
                }
                ForEach(["Assets", "Liabilities"], id: \.self) { root in
                    let accts = accounts(L, root)
                    if !accts.isEmpty {
                        Section(root == "Assets" ? LS("资产") : LS("负债")) {
                            ForEach(accts, id: \.self) { a in
                                // left out with a parent written in ledger-x.json by hand
                                let parent = (which == .netWorth ? nw : bs).first { a.hasPrefix($0 + ":") }
                                Toggle(isOn: binding(a)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(store.displayName(a) ?? acctLabel(a))
                                        Text(parent.map { LS("随 %@ 一起排除", $0) } ?? a).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .tint(.jade)
                                .disabled(parent != nil)
                            }
                        }
                    }
                }
                Section {
                } footer: {
                    Text(LS("保存在仓库的 %@，所有设备共用；账本文件不变。账户改名或合并时一并更新。", LedgerXConfig.path))
                }
            }
        }
        .navigationTitle(LS("净资产与资产负债表"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LS("保存")) {
                    saving = true
                    Task {
                        if await store.saveExclusions(netWorth: Array(nw), balance: Array(bs)) { dismiss() }
                        saving = false
                    }
                }
                .fontWeight(.semibold)
                .disabled(saving || (nw == Set(store.netWorthExclude) && bs == Set(store.balanceExclude)))
            }
        }
        .onAppear {
            guard !loaded else { return }
            nw = Set(store.netWorthExclude); bs = Set(store.balanceExclude); loaded = true
        }
    }

    /// the open asset / liability accounts, plus any already left out
    private func accounts(_ L: Ledger, _ root: String) -> [String] {
        let today = Day.today()
        return L.accounts.keys.filter { a in
            guard a.hasPrefix(root + ":") else { return false }
            let closed = (L.accounts[a]?.close).map { $0 <= today } ?? false
            return !closed || nw.contains(a) || bs.contains(a)
        }.sorted()
    }

    /// on = counted
    private func binding(_ a: String) -> Binding<Bool> {
        Binding(get: { !isExcluded(a, Array(which == .netWorth ? nw : bs)) }, set: { on in
            if which == .netWorth { if on { nw.remove(a) } else { nw.insert(a) } }
            else { if on { bs.remove(a) } else { bs.insert(a) } }
        })
    }
}

struct NetWorthSettingsDest: Hashable {}
