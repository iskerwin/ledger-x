import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

/// the connection fields for one ledger (GitHub, GitLab, Gitea, a folder or WebDAV)
struct ConnectionSections: View {
    @Binding var cfg: RepoConfig
    @State private var picking = false

    var body: some View {
        Section {
            Picker(LS("存储位置"), selection: $cfg.kind) {
                ForEach(SourceKind.allCases) { k in Label(k.name, systemImage: k.symbol).tag(k) }
            }
            LabeledContent(LS("名称")) {
                TextField(LS("可选，如「个人账本」"), text: $cfg.name).multilineTextAlignment(.trailing)
            }
        } footer: {
            Text(kindHint)
        }

        switch cfg.kind {
        case .github, .gitlab, .gitea: gitSection
        case .folder: folderSection
        case .webdav: davSection
        }
    }

    private var kindHint: String {
        switch cfg.kind {
        case .github, .gitlab, .gitea: return LS("通过 API 直接读写仓库，每次保存都是一次 Git 提交。")
        case .folder: return LS("读写「文件」App 中的文件夹：我的 iPhone、iCloud Drive，或坚果云、OneDrive、Working Copy 等提供的位置。修改直接写入文件。")
        case .webdav: return LS("直接读写 WebDAV 上的账本文件夹，如坚果云、Nextcloud、群晖。")
        }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, secure: Bool = false, url: Bool = false) -> some View {
        LabeledContent(label) {
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(url ? .URL : .default)
        }
    }

    private var gitSection: some View {
        Section {
            if cfg.kind != .github {
                field(LS("服务器"), cfg.kind == .gitlab ? "https://gitlab.com" : "https://codeberg.org", $cfg.server, url: true)
            }
            field(LS("用户"), cfg.kind == .gitlab ? LS("用户或群组") : LS("用户名"), $cfg.owner)
            field(LS("仓库"), LS("账本仓库名"), $cfg.repo)
            field(LS("分支"), "main", $cfg.branch)
            field("Token", cfg.kind == .github ? "github_pat_…" : cfg.kind == .gitlab ? "glpat-…" : "Token", $cfg.token, secure: true)
        } header: {
            Text(cfg.kind.name)
        } footer: {
            switch cfg.kind {
            case .github:
                Text(LS("请在 GitHub 创建 fine-grained token：仓库范围仅选择账本仓库，Contents 权限设为 Read and write；如需显示 bean-check 结果，另授予 Actions: Read-only。Token 保存在本机钥匙串中。"))
            case .gitlab:
                Text(LS("在 GitLab → Preferences → Access tokens 创建 Personal 或 Project access token，权限勾选 api。Token 保存在本机钥匙串中。"))
            default:
                Text(LS("在 Gitea / Forgejo → 设置 → 应用 生成令牌，repository 权限设为读写。Token 保存在本机钥匙串中。"))
            }
        }
    }

    private var folderSection: some View {
        Section {
            Button {
                picking = true
            } label: {
                HStack {
                    Label(cfg.bookmark == nil ? LS("选择文件夹") : cfg.folderName, systemImage: "folder")
                    Spacer()
                    if cfg.bookmark != nil { Text(LS("更换")).foregroundStyle(.secondary) }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    cfg.bookmark = bm
                    cfg.folderName = url.lastPathComponent
                }
            }
        } header: {
            Text(LS("文件夹"))
        } footer: {
            Text(LS("选择包含主文件（默认 main.bean）的文件夹。用 Working Copy 管理的仓库，可在电脑或 Working Copy 中提交和推送。"))
        }
    }

    private var davSection: some View {
        Section {
            field(LS("地址"), "https://dav.jianguoyun.com/dav/ledger/", $cfg.server, url: true)
            field(LS("用户"), LS("账号"), $cfg.username)
            field(LS("密码"), LS("应用密码"), $cfg.token, secure: true)
        } header: {
            Text("WebDAV")
        } footer: {
            Text(LS("地址填写账本所在文件夹。坚果云请在「账户信息 → 安全选项」中添加第三方应用密码。密码保存在本机钥匙串中。"))
        }
    }
}

/// add a ledger or change one's connection
struct LedgerEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let initial: RepoConfig
    var isNew = false
    @State private var cfg = RepoConfig()
    @State private var testing = false
    @State private var loaded = false

    var body: some View {
        Form {
            ConnectionSections(cfg: $cfg)
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text(isNew ? LS("连接并切换") : LS("保存并重新同步")); if testing { Spacer(); ProgressView() } }
                }
                .disabled(!cfg.isComplete || testing)
            }
        }
        .keyboardDone()
        .navigationTitle(isNew ? LS("添加账本") : cfg.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            cfg = initial
        }
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        guard let c = await testConnection(cfg, store) else { return }
        await store.saveConfig(c)
        store.show(isNew ? LS("已连接，正在下载账本…") : LS("已保存"))
        dismiss()
        await store.refresh()
        await store.rebuild()
    }
}

/// trim the fields and try to list the files; nil (with a toast) when it fails
@MainActor
func testConnection(_ raw: RepoConfig, _ store: Store) async -> RepoConfig? {
    var c = raw
    c.owner = c.owner.trimmed; c.repo = c.repo.trimmed; c.branch = c.branch.trimmed
    c.token = c.token.trimmed; c.server = c.server.trimmed; c.username = c.username.trimmed
    if c.kind == .webdav, !c.server.hasSuffix("/") { c.server += "/" }
    do {
        let t = try await makeBackend(c).fetchTree()
        let main = store.mainFile.trimmed.isEmpty ? "main.bean" : store.mainFile.trimmed
        if !t.files.keys.contains(main), let any = t.files.keys.sorted().first(where: { $0.hasSuffix(".bean") || $0.hasSuffix(".beancount") }) {
            store.show(LS("未找到 %@，可在「设置 → 仓库结构」中指定主文件（如 %@）", main, any))
        } else if t.files.isEmpty {
            store.show(LS("连接成功，但没有找到 .bean 文件"))
        }
    } catch {
        store.show(LS("连接失败：%@", error.localizedDescription))
        return nil
    }
    return c
}

/// 设置 → 账本：all ledgers on this phone, switch / edit / add / remove
struct LedgersSection: View {
    @EnvironmentObject var store: Store
    /// the Form owns the navigation destination (it must not sit inside a lazy List)
    @Binding var editing: RepoConfig?
    @State private var removing: RepoConfig?

    var body: some View {
        Section {
            ForEach(store.sources) { s in
                let active = s.id == store.cfg.id
                Button {
                    if !active { Task { await store.switchLedger(s.id) } }
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: s.kind.symbol, color: active ? .jade : .gray, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).foregroundStyle(.primary)
                            Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if active { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.jade) }
                    }
                }
                .swipeActions {
                    if !active { Button(LS("删除"), role: .destructive) { removing = s } }
                    Button(LS("编辑")) { editing = s }.tint(.orange)
                }
                .contextMenu {
                    Button { editing = s } label: { Label(LS("编辑连接"), systemImage: "pencil") }
                    if !active { Button(role: .destructive) { removing = s } label: { Label(LS("删除"), systemImage: "trash") } }
                }
            }
            NavigationLink {
                LedgerEditView(initial: newConfig(), isNew: true)
            } label: {
                Label(LS("添加账本"), systemImage: "plus")
            }
        } header: {
            Text(LS("账本"))
        } footer: {
            Text(LS("点按切换账本；左滑可编辑连接或删除。每个账本有独立的缓存、同步队列与仓库结构设置。"))
        }
        .confirmationDialog(LS("从本机移除「%@」？账本文件本身不受影响。", removing?.title ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(LS("移除"), role: .destructive) {
                if let r = removing { store.removeLedger(r.id) }
                removing = nil
            }
        }
    }

    private func newConfig() -> RepoConfig {
        var c = RepoConfig()
        c.id = UUID().uuidString
        return c
    }
}
