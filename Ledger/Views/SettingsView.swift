import SwiftUI
import LedgerKit

struct SettingsView: View {
    @Environment(Store.self) var store
    var first = false
    @State private var cfg = RepoConfig()
    @State private var testing = false
    @State private var editingLedger: RepoConfig?
    @State private var demoLayout = false
    @State private var demoGuide = false
    @State private var managingCats = false
    @AppStorage(Store.demoEntryKey) private var demoEntry = true
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(OverviewChart.styleKey) private var chartStyle = "list"
    @AppStorage(AppLock.enabledKey) private var lockOn = false
    @AppStorage(AppLock.graceKey) private var grace = 0

    var body: some View {
        Form {
            if first {
                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.icon) {
                        Image("Logo").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: AppRadius.panel))
                        Text("Ledger X").font(.largeTitle.bold())
                        Text(LS("连接你的 Beancount 账本：GitHub、GitLab、Gitea 仓库，「文件」App 中的文件夹，或 WebDAV。账本数据只在本机与你选择的存储之间传输。")).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, AppSpacing.icon)
                }
            }
            if first {
                Section { LanguagePicker() }
                Section {
                    Button { Task { await store.openDemo() } } label: {
                        if store.demoBusy { ProgressView(LS("正在下载演示账本…")) }
                        else { Label(LS("先看看演示账本"), systemImage: "sparkles").labelStyle(ControlLabelStyle()) }
                    }
                    Button { Task { await store.createEmptyLedger() } } label: {
                        Label(LS("在本机新建空账本"), systemImage: "iphone").labelStyle(ControlLabelStyle())
                    }
                } footer: {
                    Text(LS("演示账本的数据均为虚构，修改只保存在本机，有新版本时可在里面一键更新。新建的空账本带有常用的账户和分类，保存在这台手机上（「文件」App › 我的 iPhone › Ledger X），以后可以再放到 Git 仓库。也可以在下面直接连接已有的账本。"))
                }
            }
            if first {
                ConnectionSections(cfg: $cfg)
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack(spacing: AppSpacing.control) { Label(LS("连接"), systemImage: "network").labelStyle(ControlLabelStyle()); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(!cfg.isComplete || testing)
                }
            } else {
                ledgerCard
                // 账本与同步
                Section {
                    NavigationLink { LedgersPage(editing: $editingLedger) } label: {
                        row("books.vertical", LS("账本管理"), LS("%@ 个账本", store.sources.count))
                    }
                    NavigationLink { SyncView() } label: {
                        row("arrow.triangle.2.circlepath", LS("同步与最近改动"), syncSummary)
                    }
                    NavigationLink { BackupView() } label: {
                        row("externaldrive", LS("备份与导出"), Backup.folderName == nil ? LS("未设置") : (Backup.last(store).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                    }
                    Button {
                        store.openCheckAfterSettings = true
                        store.tab = .overview
                        store.showSettings = false
                    } label: {
                        HStack(spacing: AppSpacing.control) { LedgerCheckRow(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                            .contentShape(Rectangle())
                    }
                } header: { Text(LS("账本与同步")) }
                // 记账偏好
                Section {
                    NavigationLink { BookkeepingPrefsPage() } label: { row("square.and.pencil", LS("记账偏好"), "") }
                    Button { managingCats = true } label: { row("square.grid.2x2", LS("分类与常用交易"), "", chevron: true) }
                    NavigationLink { NetWorthSettingsView() } label: { row("chart.bar", LS("统计范围"), exclusionSummary) }
                    NavigationLink { Form { RemindersSection() }.navigationTitle(LS("提醒")) } label: {
                        row("bell", LS("提醒"), Reminders.enabled ? LS("已开启") : LS("未开启"))
                    }
                    NavigationLink { ShortcutsSettingsView() } label: { row("bolt.horizontal.circle", LS("快捷指令与 Apple Pay"), "") }
                } header: { Text(LS("记账偏好")) }
                // 外观
                Section {
                    NavigationLink { Form { appearanceSection }.navigationTitle(LS("外观")) } label: {
                        row("paintpalette", LS("外观"), AppTheme.current.name + " · " + (AppAppearance(rawValue: appearance) ?? .system).name)
                    }
                    LanguagePicker(badge: true)
                } header: { Text(LS("外观")) }
                securitySection
                // 高级
                Section {
                    NavigationLink { AdvancedPage() } label: { row("gearshape.2", LS("高级设置"), "") }
                    NavigationLink { GuideView() } label: { row("questionmark.circle", LS("使用指南与常见问题"), "") }
                    Toggle(isOn: $demoEntry) { SettingsRow(symbol: "sparkles", title: LS("概览显示演示账本入口")) }
                    .tint(.jade)
                    NavigationLink { AboutPage() } label: {
                        row("info.circle", LS("关于 Ledger X"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    }
                } header: {
                    Text(LS("更多"))
                } footer: {
                    Text(LS("账本保存在你选择的位置 · Ledger X %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .keyboardDone()
        .navigationDestination(isPresented: $demoLayout) { RepoLayoutView() }
        .navigationDestination(isPresented: $demoGuide) { GuideView() }
        .task { if store.demoEnv["LEDGER_GUIDE"] != nil { try? await Task.sleep(nanoseconds: 500_000_000); demoGuide = true } }
        .task { if store.demoEnv["LEDGER_LAYOUT"] != nil { try? await Task.sleep(nanoseconds: 500_000_000); demoLayout = true } }
        .navigationTitle(first ? "" : LS("设置"))
        .onAppear { cfg = store.cfg }
        .sheet(isPresented: $managingCats) { CategoryManager(root: "Expenses:") }
    }

    /// the ledger in use: where it is, and whether it is in sync; tap for 账本同步
    private var ledgerCard: some View {
        Section {
            NavigationLink { SyncView() } label: {
                HStack(spacing: AppSpacing.icon) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.jadeInk)
                        .frame(width: 54, height: 54)
                        .background(Color.jade.soft, in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(store.cfg.title).font(.headline)
                        Text(store.cfg.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: AppSpacing.icon) {
                            // a scaled square: each state's symbol has its own height, which moved the card
                            ControlIcon(systemName: store.syncAppearance.symbol)
                                .foregroundStyle(store.syncAppearance.color)
                            Text(syncSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, AppSpacing.detail)
            }
        }
    }

    private var syncSummary: String {
        if store.syncState == .syncing { return LS("同步中…") }
        if store.syncAppearance == .failed { return LS("同步出错") }
        if store.syncAppearance == .held { return LS("暂存本机") }
        if store.syncState == .offline { return LS("离线 · %@ 项待同步", store.pending.count) }
        if !store.pending.isEmpty { return LS("%@ 项待同步", store.pending.count) }
        return store.lastSync.map { LS("已同步 · %@", $0.formatted(date: .omitted, time: .shortened)) } ?? LS("已同步")
    }

    /// a settings row: an icon in the theme's colour, the name, what is set on the right
    private func row(_ icon: String, _ title: String, _ value: String, chevron: Bool = false) -> some View {
        SettingsRow(symbol: icon, title: title, value: value, chevron: chevron)
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        guard let c = await testConnection(cfg, store) else { return }
        guard await store.saveConfig(c) else { return }
        store.show(first ? LS("已连接，正在下载账本…") : LS("已保存"))
        await store.refresh()
        if !first { await store.rebuild() }
    }
}

struct PrivacyToggle: View {
    /// with its badge, as a row of 设置
    var badge = false
    var body: some View {
        Toggle(isOn: Binding(get: { AppSettings.shared.privacy }, set: { AppSettings.shared.privacy = $0 })) {
            if badge { SettingsRow(symbol: "eye.slash", title: LS("隐藏金额")) } else { Text(LS("隐藏金额")) }
        }
    }
}

extension SettingsView {
    private var exclusionSummary: String {
        let n = Set(store.netWorthExclude + store.balanceExclude).count
        return n == 0 ? LS("全部计入") : LS("已排除 %@ 个", n)
    }

    var appearanceSection: some View {
        Section {
            ThemePicker()
            LanguagePicker()
            Picker(LS("显示模式"), selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.name).tag($0.rawValue) }
            }
            Picker(LS("明细样式"), selection: Binding(get: { AppSettings.shared.journalStyle }, set: { AppSettings.shared.journalStyle = $0 })) {
                ForEach(JournalStyle.allCases) { Text($0.name).tag($0.rawValue) }
            }
            NavigationLink {
                CodeThemePicker()
            } label: {
                LabeledContent(LS("代码配色"), value: CodeTheme.current.name)
            }
            Toggle(LS("触感反馈"), isOn: Binding(get: { AppSettings.shared.haptics }, set: { AppSettings.shared.haptics = $0 }))
            if AppSettings.shared.haptics {
                Picker(LS("点按触感强度"), selection: Binding(get: { AppSettings.shared.hapticStrength }, set: { AppSettings.shared.hapticStrength = $0; Haptics.selection() })) {
                    Text(LS("轻")).tag(0)
                    Text(LS("标准")).tag(1)
                    Text(LS("强")).tag(2)
                }
            }
            Picker(LS("概览图表"), selection: $chartStyle) {
                Text(LS("排行列表")).tag("list")
                Text(LS("环形图")).tag("donut")
            }
        } header: {
            Text(LS("外观"))
        } footer: {
            Text(LS("主题色用于按钮、选中状态与图表；收入与亏损分别固定以绿色与红色表示。触感强度影响点按反馈，保存和警告使用系统触感。动态效果遵循系统的「减少动态效果」设置。"))
        }
    }

    var securitySection: some View {
        let b = AppLock.biometry
        return Section {
            Toggle(isOn: Binding(get: { lockOn }, set: { on in
                Task {
                    if await AppLock.verify(on ? LS("启用%@锁定", b.name) : LS("关闭%@锁定", b.name)) { lockOn = on }
                    else { store.showFailure(b.available ? LS("验证未通过") : LS("本机未设置密码，无法启用")) }
                }
            })) {
                SettingsRow(symbol: b.symbol, title: LS("%@锁定", b.name))
            }
            if lockOn {
                Picker(LS("自动锁定"), selection: $grace) {
                    Text(LS("立即")).tag(0)
                    Text(LS("1 分钟后")).tag(60)
                    Text(LS("5 分钟后")).tag(300)
                    Text(LS("15 分钟后")).tag(900)
                }
            }
            PrivacyToggle(badge: true)
        } header: {
            Text(LS("安全"))
        } footer: {
            if lockOn && store.hasLedgerInFiles {
                Text(LS("锁定只保护 App 的界面：本机账本存在「文件」App › 我的 iPhone › Ledger X 里，在那里或用数据线连电脑时仍然可以直接打开。"))
            }
        }
    }
}

// MARK: - the pages behind 设置

/// the ledgers on this phone, to switch, edit, add or remove
struct LedgersPage: View {
    @Environment(Store.self) var store
    @Binding var editing: RepoConfig?
    var body: some View {
        Form {
            LedgersSection(editing: $editing)
            if store.sources.contains(where: { Keychain.inFallback(account: $0.keychainAccount) }) {
                Section {
                    Label(LS("访问令牌未能存入钥匙串，目前保存在 App 自己受保护的文件里（不随备份带走）。通常是安装包的签名缺少钥匙串权限，换用带钥匙串权限的签名重新安装后会自动移入钥匙串。"), systemImage: "exclamationmark.lock").labelStyle(ControlLabelStyle())
                        .font(.footnote).foregroundStyle(Color.warn)
                }
            }
        }
        .navigationTitle(LS("账本管理"))
        .navigationDestination(item: $editing) { s in LedgerEditView(initial: s) }
    }
}

/// 记账偏好: the default paying account and currency, how postings are written
struct BookkeepingPrefsPage: View {
    @Environment(Store.self) var store
    var body: some View {
        Form {
            if let D = store.D {
                Section {
                    Picker(LS("默认付款账户"), selection: Binding(get: { store.defaultFunding ?? "" }, set: { store.defaultFunding = $0.isEmpty ? nil : $0 })) {
                        Text(LS("自动（使用频率最高）")).tag("")
                        ForEach(D.rankAccounts(["Assets:", "Liabilities:CreditCard"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(15), id: \.self) { a in
                            Text(acctDisplay(a)).tag(a)
                        }
                    }
                    Picker(LS("默认币种"), selection: Binding(get: { store.defaultCurrency ?? "" }, set: { store.defaultCurrency = $0.isEmpty ? nil : $0 })) {
                        Text(LS("跟随付款账户")).tag("")
                        ForEach(D.currencies, id: \.self) { c in Text(c).tag(c) }
                    }
                } footer: {
                    Text(LS("默认币种用于新的支出、收入和退款；付款账户是其他币种时，可填写账户实付金额。转账始终使用转出账户的币种。"))
                }
                Section {
                    Toggle(LS("分录显式写出自动补平金额"), isOn: Bindable(store).explicitAmounts)
                } footer: {
                    Text(LS("关闭时和手写一样，最后一行的金额留空由 Beancount 补平；打开后每一行都写出金额。"))
                }
            }
        }
        .navigationTitle(LS("记账偏好"))
    }
}

/// 高级设置: the repository's layout, its files, the cache
struct AdvancedPage: View {
    @Environment(Store.self) var store
    @State private var confirmReset = false
    /// what is running: the button shows it, and says how it went
    @State private var reloading = false
    @State private var resetting = false
    var body: some View {
        Form {
            Section {
                NavigationLink { RepoLayoutView() } label: {
                    LabeledContent(LS("仓库结构与共用设置"), value: store.main)
                }
                Button { Task { await reload() } } label: {
                    HStack(spacing: AppSpacing.control) {
                        Label(LS("应用并重新加载"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle())
                        if reloading { Spacer(); ProgressView() }
                    }
                }
                .disabled(reloading || resetting)
            } footer: {
                Text(LS("主文件、各类记录写入哪个文件、记账偏好、统计范围等跟账本有关的设置都保存在仓库的 ledger-x.json，所有设备共用；主题、语言、提醒等只存在这台手机。"))
            }
            if let L = store.L {
                Section(LS("账本")) {
                    LabeledContent(LS("交易"), value: LS("%@ 笔", L.txns.count))
                    LabeledContent(LS("余额断言"), value: "\(L.balanceResults.filter { $0.ok }.count)/\(L.balanceResults.count)")
                    NavigationLink { SourceFilesView() } label: {
                        LabeledContent(LS("源文件"), value: LS("%@ 个", L.files.count))
                    }
                    if store.cfg.kind == .github { CIRow() }
                    if let u = store.backend.repoURL { Link(destination: u) { Label(LS("在网页中打开仓库"), systemImage: "safari").labelStyle(ControlLabelStyle()) } }
                }
            }
            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    HStack(spacing: AppSpacing.control) {
                        Label(LS("清除缓存并重新下载"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle())
                        if resetting { Spacer(); ProgressView() }
                    }
                }
                .disabled(reloading || resetting)
            } footer: {
                Text(LS("需要联网：先重新下载账本文件，全部成功后才替换这台手机上的副本；同步队列中的变更会保留。"))
            }
        }
        .navigationTitle(LS("高级设置"))
        .confirmationDialog(LS("清除并重新下载本机缓存？需要联网，下载失败时本机副本保持不变；同步队列中的变更将保留。"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await reset() } } label: { Text(LS("清除并重新下载")) }
        }
    }

    private func reload() async {
        reloading = true
        defer { reloading = false }
        await store.rebuild()
        if let e = store.loadError { store.showFailure(e) } else { store.showSuccess(LS("已重新加载")) }
    }

    private func reset() async {
        resetting = true
        defer { resetting = false }
        guard await store.resetCache() else { return }
        if let e = store.loadError { store.showFailure(e) }
        else if store.syncState == .error || store.syncState == .offline { store.showFailure(LS("重新下载失败：%@", store.syncError)) }
        else { store.showSuccess(LS("已清除缓存并重新下载")) }
    }
}

/// 关于: the version, and what the ledger stays
struct AboutPage: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: AppSpacing.icon) {
                    Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Ledger X").font(.title2.weight(.bold))
                    // with the build: two installs of the same version (a preview, the dev build) are told apart
                    Text(LS("版本 %@（构建 %@）", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")).foregroundStyle(.secondary)
                        .accessibilityIdentifier("about.version")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.icon)
            }
            Section {
                Text(LS("账本始终为标准 Beancount 文本文件：本应用写入的内容在电脑上 git pull 后即可查看，并可继续使用 Fava、bean-check 等工具处理。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(LS("关于 Ledger X"))
    }
}
