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
                Section {
                    Button { Task { await store.openDemo() } } label: {
                        if store.demoBusy { ProgressView(LS("正在下载演示账本…")) }
                        else { Label(LS("先看看演示账本"), systemImage: "sparkles") }
                    }
                    Button { Task { await store.createEmptyLedger() } } label: {
                        Label(LS("在本机新建空账本"), systemImage: "iphone")
                    }
                } footer: {
                    Text(LS("演示账本的数据均为虚构，修改只保存在本机，有新版本时可在里面一键更新。新建的空账本带有常用的账户和分类，保存在这台手机上（「文件」App › 我的 iPhone › Ledger），以后可以再放到 Git 仓库。也可以在下面直接连接已有的账本。"))
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
                        HStack { LedgerCheckRow(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: { Text(LS("账本与同步")) }
                // 记账偏好
                Section {
                    NavigationLink { BookkeepingPrefsPage() } label: { row("square.and.pencil", LS("记账偏好"), "") }
                    Button { managingCats = true } label: { row("square.grid.2x2", LS("分类与常用交易"), "", chevron: true) }
                        .buttonStyle(.plain)
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
                    LanguagePicker()
                } header: { Text(LS("外观")) }
                securitySection
                // 高级
                Section {
                    NavigationLink { AdvancedPage(confirmReset: $confirmReset) } label: { row("gearshape.2", LS("高级设置"), "") }
                    NavigationLink { GuideView() } label: { row("questionmark.circle", LS("使用指南与常见问题"), "") }
                    Toggle(isOn: $demoEntry) {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").foregroundStyle(Color.jade).frame(width: 26)
                            Text(LS("概览显示演示账本入口"))
                        }
                    }
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
        .confirmationDialog(LS("清除本机缓存？同步队列中的变更将保留。"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(LS("清除并重新下载"), role: .destructive) { Task { await store.resetCache() } }
        }
        .sheet(isPresented: $managingCats) { CategoryManager(root: "Expenses:") }
    }

    /// the ledger in use: where it is, and whether it is in sync; tap for 账本同步
    private var ledgerCard: some View {
        Section {
            NavigationLink { SyncView() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.jade)
                        .frame(width: 54, height: 54)
                        .background(Color.jade.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.cfg.title).font(.headline)
                        Text(store.cfg.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: store.pending.isEmpty && store.syncState != .error ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(store.pending.isEmpty && store.syncState != .error ? Color.jade : Color.orange)
                            Text(syncSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var syncSummary: String {
        if store.syncState == .syncing { return LS("同步中…") }
        if store.syncState == .error { return LS("同步出错") }
        if store.syncState == .offline { return LS("离线 · %@ 项待同步", store.pending.count) }
        if !store.pending.isEmpty { return LS("%@ 项待同步", store.pending.count) }
        return store.lastSync.map { LS("已同步 · %@", $0.formatted(date: .omitted, time: .shortened)) } ?? LS("已同步")
    }

    /// a settings row: an icon in the theme's colour, the name, what is set on the right
    private func row(_ icon: String, _ title: String, _ value: String, chevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(Color.jade).frame(width: 26)
            Text(title).foregroundStyle(.primary)
            Spacer()
            if !value.isEmpty { Text(value).foregroundStyle(.secondary).lineLimit(1) }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
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
    var body: some View { Toggle(LS("隐藏金额"), isOn: Binding(get: { AppSettings.shared.privacy }, set: { AppSettings.shared.privacy = $0 })) }
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
            NavigationLink {
                CodeThemePicker()
            } label: {
                LabeledContent(LS("代码配色"), value: CodeTheme.current.name)
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
            Text(LS("安全"))
        }
    }
}

// MARK: - the pages behind 设置

/// the ledgers on this phone, to switch, edit, add or remove
struct LedgersPage: View {
    @EnvironmentObject var store: Store
    @Binding var editing: RepoConfig?
    var body: some View {
        Form {
            LedgersSection(editing: $editing)
            if store.sources.contains(where: { Keychain.inFallback(account: $0.keychainAccount) }) {
                Section {
                    Label(LS("访问令牌未能存入钥匙串，目前未加密保存在本机。通常是安装包的签名缺少钥匙串权限，换用带钥匙串权限的签名重新安装后会自动移入钥匙串。"), systemImage: "exclamationmark.lock")
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
    @EnvironmentObject var store: Store
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
                    Toggle(LS("分录显式写出自动补平金额"), isOn: $store.explicitAmounts)
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
    @EnvironmentObject var store: Store
    @Binding var confirmReset: Bool
    var body: some View {
        Form {
            Section {
                NavigationLink { RepoLayoutView() } label: {
                    LabeledContent(LS("仓库结构与共用设置"), value: store.main)
                }
                Button { Task { await store.rebuild() } } label: { Label(LS("应用并重新加载"), systemImage: "arrow.clockwise") }
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
                    if let u = store.backend.repoURL { Link(LS("在网页中打开仓库"), destination: u) }
                }
            }
            Section {
                Button(LS("清除缓存并重新下载"), role: .destructive) { confirmReset = true }
            } footer: {
                Text(LS("只清除这台手机上的副本，同步队列中的变更会保留。"))
            }
        }
        .navigationTitle(LS("高级设置"))
    }
}

/// 关于: the version, and what the ledger stays
struct AboutPage: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Ledger X").font(.title2.weight(.bold))
                    Text(LS("版本 %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            Section {
                Text(LS("账本始终为标准 Beancount 文本文件：本应用写入的内容在电脑上 git pull 后即可查看，并可继续使用 Fava、bean-check 等工具处理。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(LS("关于 Ledger X"))
    }
}
