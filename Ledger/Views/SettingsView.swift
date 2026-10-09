import SwiftUI
import LedgerKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var first = false
    @State private var cfg = RepoConfig()
    @State private var testing = false
    @State private var confirmReset = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppLock.enabledKey) private var lockOn = false
    @AppStorage(AppLock.graceKey) private var grace = 0

    var body: some View {
        Form {
            if first {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image("Logo").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("Ledger").font(.largeTitle.bold())
                        Text("连接存放于 GitHub 的 Beancount 账本仓库。账本数据仅在本机与 GitHub 之间传输。").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            if !first {
                appearanceSection
                securitySection
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
                Text("GitHub 连接")
            } footer: {
                Text("请在 GitHub 创建 fine-grained token：仓库范围仅选择账本仓库，Contents 权限设为 Read and write；如需显示 bean-check 结果，另授予 Actions: Read-only。Token 保存在本机钥匙串中。")
            }

            if !first, let L = store.L, let D = store.D {
                Section("记账偏好") {
                    Picker("默认付款账户", selection: Binding(get: { store.defaultFunding ?? "" }, set: { store.defaultFunding = $0.isEmpty ? nil : $0 })) {
                        Text("自动（使用频率最高）").tag("")
                        ForEach(D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(15), id: \.self) { a in
                            Text(acctDisplay(a)).tag(a)
                        }
                    }
                    Toggle("分录显式写出自动补平金额", isOn: $store.explicitAmounts)
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
                    LabeledContent("报销应收科目") {
                        TextField("Assets:Receivable:Reimbursement", text: $store.receivableAccount)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("仓库结构")
                } footer: {
                    Text("留空则根据账本自动识别：交易写入最近年度交易所在的文件（{year} 替换为年份，跨年时自动新建文件并在主文件中添加 include）；余额断言、价格、开户等指令写入同类指令最多的文件。修改主文件或应收科目后，请点按上方「保存并重新同步」。")
                }

                Section {
                    if store.pending.isEmpty { Text("无待同步的变更").foregroundStyle(.secondary) }
                    ForEach(store.pending) { o in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(o.label ?? o.summary ?? "\(o.kind.rawValue) \(o.path)").font(.subheadline)
                            Text("\(o.path)\(o.silent == true ? " · 与上一项合并提交" : "")").font(.caption).foregroundStyle(.secondary)
                            if let f = o.failed { Text(f).font(.caption).foregroundStyle(Color.loss) }
                        }
                        .swipeActions { Button("删除", role: .destructive) { Task { await store.dropPending(o) } } }
                    }
                    Button { Task { await store.syncNow() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                } header: {
                    Text("同步队列")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let d = store.lastSync { Text("上次同步 \(d.formatted(date: .abbreviated, time: .shortened))") }
                        if !store.syncError.isEmpty { Text(store.syncError).foregroundStyle(Color.loss) }
                        Text("离线时的变更暂存于本机，恢复联网后自动提交。左滑可移除单项。")
                    }
                }

                Section("账本") {
                    NavigationLink { ErrorsView() } label: {
                        LabeledContent("账本校验", value: L.errors.isEmpty ? "通过" : "\(L.errors.count) 项错误")
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
                    Text("账本始终为标准 Beancount 文本文件：本应用写入的内容在电脑上 git pull 后即可查看，并可继续使用 Fava、bean-check 等工具处理。")
                }
            }
        }
        .keyboardDone()
        .navigationTitle(first ? "" : "设置")
        .onAppear { cfg = store.cfg }
        .confirmationDialog("清除本机缓存？同步队列中的变更将保留。", isPresented: $confirmReset, titleVisibility: .visible) {
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
    var body: some View { Toggle("隐藏金额", isOn: $privacy) }
}

extension SettingsView {
    var appearanceSection: some View {
        Section {
            ThemePicker()
            Picker("外观", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.name).tag($0.rawValue) }
            }
        } header: {
            Text("外观")
        } footer: {
            Text("主题色用于按钮、选中状态与图表；收入与亏损分别固定以绿色与红色表示。")
        }
    }

    var securitySection: some View {
        let b = AppLock.biometry
        return Section {
            Toggle(isOn: Binding(get: { lockOn }, set: { on in
                Task {
                    if await AppLock.verify(on ? "启用\(b.name)锁定" : "关闭\(b.name)锁定") { lockOn = on }
                    else { store.show(b.available ? "验证未通过" : "本机未设置密码，无法启用") }
                }
            })) {
                Label("\(b.name)锁定", systemImage: b.symbol)
            }
            if lockOn {
                Picker("自动锁定", selection: $grace) {
                    Text("立即").tag(0)
                    Text("1 分钟后").tag(60)
                    Text("5 分钟后").tag(300)
                    Text("15 分钟后").tag(900)
                }
            }
            PrivacyToggle()
        } header: {
            Text("安全与隐私")
        } footer: {
            Text("启用后，打开应用或从后台返回时需验证\(b.name)；在多任务界面中隐藏账本内容。")
        }
    }
}
