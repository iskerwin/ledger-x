import SwiftUI
import LedgerKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var first = false
    @State private var cfg = RepoConfig()
    @State private var testing = false
    @State private var confirmReset = false
    @State private var editingLedger: RepoConfig?
    @State private var demoLayout = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(OverviewChart.styleKey) private var chartStyle = "list"
    @AppStorage(AppLock.enabledKey) private var lockOn = false
    @AppStorage(AppLock.graceKey) private var grace = 0

    var body: some View {
        Form {
            if first {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image("Logo").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("Ledger").font(.largeTitle.bold())
                        Text(LS("连接你的 Beancount 账本：GitHub、GitLab、Gitea 仓库，「文件」App 中的文件夹，或 WebDAV。账本数据只在本机与你选择的存储之间传输。")).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            if first {
                Section { LanguagePicker() }
            }
            if !first {
                appearanceSection
                securitySection
                RemindersSection()
                Section {
                    NavigationLink { ShortcutsSettingsView() } label: {
                        Label(LS("快捷指令与 Apple Pay"), systemImage: "bolt.horizontal.circle")
                    }
                }
            }
            if first {
                ConnectionSections(cfg: $cfg)
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack { Text(LS("连接")); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(!cfg.isComplete || testing)
                }
            } else {
                LedgersSection(editing: $editingLedger)
            }

            if !first, let L = store.L, let D = store.D {
                Section(LS("记账偏好")) {
                    Picker(LS("默认付款账户"), selection: Binding(get: { store.defaultFunding ?? "" }, set: { store.defaultFunding = $0.isEmpty ? nil : $0 })) {
                        Text(LS("自动（使用频率最高）")).tag("")
                        ForEach(D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(15), id: \.self) { a in
                            Text(acctDisplay(a)).tag(a)
                        }
                    }
                    Toggle(LS("分录显式写出自动补平金额"), isOn: $store.explicitAmounts)
                }

                Section {
                    LabeledContent(LS("主文件")) {
                        TextField("main.bean", text: $store.mainFile)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    NavigationLink { RepoLayoutView() } label: {
                        LabeledContent(LS("文件规则"), value: store.repoConfig == nil ? LS("自动识别") : LedgerXConfig.path)
                    }
                    Button { Task { await store.rebuild() } } label: { Label(LS("应用并重新加载"), systemImage: "arrow.clockwise") }
                } header: {
                    Text(LS("仓库结构"))
                } footer: {
                    Text(LS("主文件保存在本机；交易、开户、余额断言等各类记录写入哪个文件、按科目分流的规则和报销应收科目，保存在仓库的 ledger-x.json 中，所有设备共用。修改主文件后，请点按「应用并重新加载」。"))
                }

                Section {
                    if store.pending.isEmpty { Text(LS("无待同步的变更")).foregroundStyle(.secondary) }
                    ForEach(store.pending) { o in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(o.label ?? o.summary ?? "\(o.kind.rawValue) \(o.path)").font(.subheadline)
                            Text("\(o.path)\(o.silent == true ? LS(" · 与上一项合并提交") : "")").font(.caption).foregroundStyle(.secondary)
                            if let f = o.failed { Text(f).font(.caption).foregroundStyle(Color.loss) }
                            if let h = o.held { Text(h).font(.caption).foregroundStyle(Color.warn) }
                        }
                        .swipeActions {
                            Button(LS("删除"), role: .destructive) { Task { await store.dropPending(o) } }
                            if o.held != nil { Button(LS("推送")) { Task { await store.release(o) } }.tint(Color.jade) }
                        }
                    }
                    Button { Task { await store.syncNow() } } label: { Label(LS("立即同步"), systemImage: "arrow.triangle.2.circlepath") }
                } header: {
                    Text(LS("同步队列"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let d = store.lastSync { Text(LS("上次同步 %@", d.formatted(date: .abbreviated, time: .shortened))) }
                        if !store.syncError.isEmpty { Text(store.syncError).foregroundStyle(Color.loss) }
                        Text(LS("离线时的变更暂存于本机，恢复联网后自动提交。未通过提交前检查而暂存的项目不会自动推送，左滑可推送或移除。"))
                    }
                }

                Section(LS("账本")) {
                    NavigationLink { ErrorsView(links: false) } label: {
                        LabeledContent(LS("账本校验"), value: L.errors.isEmpty ? LS("通过") : LS("%@ 项错误", L.errors.count))
                    }
                    LabeledContent(LS("交易"), value: LS("%@ 笔", L.txns.count))
                    LabeledContent(LS("余额断言"), value: "\(L.balanceResults.filter { $0.ok }.count)/\(L.balanceResults.count)")
                    LabeledContent(LS("文件"), value: LS("%@ 个", L.files.count))
                    if store.cfg.kind == .github { CIRow() }
                    if let u = store.backend.repoURL { Link(LS("在网页中打开仓库"), destination: u) }
                    Button(LS("清除缓存并重新下载"), role: .destructive) { confirmReset = true }
                }

                Section {
                    LabeledContent(LS("版本"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } footer: {
                    Text(LS("账本始终为标准 Beancount 文本文件：本应用写入的内容在电脑上 git pull 后即可查看，并可继续使用 Fava、bean-check 等工具处理。"))
                }
            }
        }
        .keyboardDone()
        .navigationDestination(item: $editingLedger) { s in LedgerEditView(initial: s) }
        .navigationDestination(isPresented: $demoLayout) { RepoLayoutView() }
        .task { if store.demoEnv["LEDGER_LAYOUT"] != nil { try? await Task.sleep(nanoseconds: 500_000_000); demoLayout = true } }
        .navigationTitle(first ? "" : LS("设置"))
        .onAppear { cfg = store.cfg }
        .confirmationDialog(LS("清除本机缓存？同步队列中的变更将保留。"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(LS("清除并重新下载"), role: .destructive) { Task { await store.resetCache() } }
        }
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        guard let c = await testConnection(cfg, store) else { return }
        await store.saveConfig(c)
        store.show(first ? LS("已连接，正在下载账本…") : LS("已保存"))
        await store.refresh()
        if !first { await store.rebuild() }
    }
}

struct PrivacyToggle: View {
    @AppStorage("ledger.privacy") private var privacy = false
    var body: some View { Toggle(LS("隐藏金额"), isOn: $privacy) }
}

extension SettingsView {
    var appearanceSection: some View {
        Section {
            ThemePicker()
            LanguagePicker()
            Picker(LS("显示模式"), selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.name).tag($0.rawValue) }
            }
            Picker(LS("概览图表"), selection: $chartStyle) {
                Text(LS("排行列表")).tag("list")
                Text(LS("环形图")).tag("donut")
            }
        } header: {
            Text(LS("外观"))
        } footer: {
            Text(LS("主题色用于按钮、选中状态与图表；收入与亏损分别固定以绿色与红色表示。"))
        }
    }

    var securitySection: some View {
        let b = AppLock.biometry
        return Section {
            Toggle(isOn: Binding(get: { lockOn }, set: { on in
                Task {
                    if await AppLock.verify(on ? LS("启用%@锁定", b.name) : LS("关闭%@锁定", b.name)) { lockOn = on }
                    else { store.show(b.available ? LS("验证未通过") : LS("本机未设置密码，无法启用")) }
                }
            })) {
                Label(LS("%@锁定", b.name), systemImage: b.symbol)
            }
            if lockOn {
                Picker(LS("自动锁定"), selection: $grace) {
                    Text(LS("立即")).tag(0)
                    Text(LS("1 分钟后")).tag(60)
                    Text(LS("5 分钟后")).tag(300)
                    Text(LS("15 分钟后")).tag(900)
                }
            }
            PrivacyToggle()
        } header: {
            Text(LS("安全与隐私"))
        } footer: {
            Text(LS("启用后，打开应用或从后台返回时需验证%@；在多任务界面中隐藏账本内容。", b.name))
        }
    }
}
