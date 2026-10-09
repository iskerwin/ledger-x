import SwiftUI
import LedgerKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var first = false
    @State private var cfg = RepoConfig()
    @State private var testing = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            if first {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image("Logo").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("Ledger").font(.largeTitle.bold())
                        Text("连接你在 GitHub 上的 Beancount 仓库。账目只在你的手机和 GitHub 之间传输。").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            Section {
                SecureField("github_pat_…", text: $cfg.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("用户") { TextField("GitHub 用户名", text: $cfg.owner).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                LabeledContent("仓库") { TextField("账本仓库名", text: $cfg.repo).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                LabeledContent("分支") { TextField("main", text: $cfg.branch).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text(first ? "连接" : "保存并重新同步"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(!cfg.isComplete || testing)
            } header: {
                Text("GitHub")
            } footer: {
                Text("在 GitHub 新建 fine-grained token：只选你的账本仓库，Contents 设为 Read and write；再加 Actions: Read-only 可以看到 bean-check 结果。Token 存在本机钥匙串里。")
            }

            if !first, let L = store.L, let D = store.D {
                Section("记账") {
                    Picker("默认付款账户", selection: Binding(get: { store.defaultFunding ?? "" }, set: { store.defaultFunding = $0.isEmpty ? nil : $0 })) {
                        Text("自动（最常用）").tag("")
                        ForEach(D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(15), id: \.self) { a in
                            Text(acctDisplay(a)).tag(a)
                        }
                    }
                    Toggle("分录里把自动补平的金额写出来", isOn: $store.explicitAmounts).tint(.jade)
                    PrivacyToggle()
                }

                Section {
                    LabeledContent("主文件") {
                        TextField("main.bean", text: $store.mainFile)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("交易写入") {
                        TextField(store.detectedLayout.journal, text: $store.journalPattern)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("报销应收账户") {
                        TextField("Assets:Receivable:Reimbursement", text: $store.receivableAccount)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("仓库结构")
                } footer: {
                    Text("留空就按账本自动识别：交易写进最近一年交易所在的文件（{year} 换成年份，新的一年会自动在主文件里加 include）；余额断言、价格、开户写进账本里放同类内容最多的文件。改了主文件或应收账户后点上面的「保存并重新同步」。")
                }

                Section {
                    if store.pending.isEmpty { Text("没有待同步的修改").foregroundStyle(.secondary) }
                    ForEach(store.pending) { o in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(o.label ?? o.summary ?? "\(o.kind.rawValue) \(o.path)").font(.subheadline)
                            Text("\(o.path)\(o.silent == true ? " · 随上一项提交" : "")").font(.caption).foregroundStyle(.secondary)
                            if let f = o.failed { Text(f).font(.caption).foregroundStyle(Color.loss) }
                        }
                        .swipeActions { Button("删除", role: .destructive) { Task { await store.dropPending(o) } } }
                    }
                    Button { Task { await store.syncNow() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                } header: {
                    Text("待同步")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let d = store.lastSync { Text("上次同步 \(d.formatted(date: .abbreviated, time: .shortened))") }
                        if !store.syncError.isEmpty { Text(store.syncError).foregroundStyle(Color.loss) }
                        Text("没联网时记的账先存在手机上，联网后自动提交。左滑可以删掉某一项。")
                    }
                }

                Section("账本") {
                    NavigationLink { ErrorsView() } label: {
                        LabeledContent("应用内检查", value: L.errors.isEmpty ? "通过" : "\(L.errors.count) 个问题")
                    }
                    LabeledContent("交易", value: "\(L.txns.count) 笔")
                    LabeledContent("余额断言", value: "\(L.balanceResults.filter { $0.ok }.count)/\(L.balanceResults.count)")
                    LabeledContent("文件", value: "\(L.files.count) 个")
                    CIRow()
                    if let u = URL(string: "https://github.com/\(store.cfg.owner)/\(store.cfg.repo)") { Link("在 GitHub 打开仓库", destination: u) }
                    Button("清除缓存并重新下载", role: .destructive) { confirmReset = true }
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } footer: {
                    Text("账本仍是普通的 Beancount 文件：在这里记的账，电脑上 git pull 之后就能看到，也能继续用 Fava、bean-check 等工具。")
                }
            }
        }
        .keyboardDone()
        .navigationTitle(first ? "" : "设置")
        .onAppear { cfg = store.cfg }
        .confirmationDialog("清除本机缓存？待同步的修改会保留。", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("清除并重新下载", role: .destructive) { Task { await store.resetCache() } }
        }
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        var c = cfg
        c.owner = c.owner.trimmed; c.repo = c.repo.trimmed; c.branch = c.branch.trimmed; c.token = c.token.trimmed
        do {
            _ = try await GitHub(cfg: c).fetchTree()
        } catch {
            store.show("连接失败：\(error.localizedDescription)")
            return
        }
        store.saveConfig(c)
        store.show(first ? "已连接，正在下载账本…" : "已保存")
        await store.refresh()
        if !first { await store.rebuild() }
    }
}

struct PrivacyToggle: View {
    @AppStorage("ledger.privacy") private var privacy = false
    var body: some View { Toggle("隐藏金额", isOn: $privacy).tint(.jade) }
}
