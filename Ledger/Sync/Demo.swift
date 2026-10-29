import Foundation
import SwiftUI
import LedgerKit

// 演示账本: the public ledger-demo repository (made-up data). A copy of it is built into the app (Ledger/Demo,
// copied in by tools/ship.py when the release app is built) so it opens at once and offline; newer versions are fetched from that
// public GitHub repository without reinstalling the app. The
// copy on this phone is local: edits stay here and nothing is pushed upstream. From it, 我的账本: a new ledger on
// this phone with the demo's accounts and categories and no transactions.

extension Store {
    static let demoID = "demo"
    /// the folder names under On My iPhone › Ledger
    static let demoFolder = "Demo"
    static let demoEntryKey = "ledger.demo.entry"
    /// the ledger-demo commit of the copy on this phone
    static let demoCommitKey = "ledger.demo.commit"
    private static let demoCheckedKey = "ledger.demo.checked"

    var isDemo: Bool { cfg.id == Store.demoID }
    /// the ledgers other than the demo
    var ownSources: [RepoConfig] { sources.filter { $0.id != Store.demoID } }

    private var demoRoot: URL { FolderBackend.localRoot(Store.demoFolder) }
    /// the copy built into the app, and the commit it is (Info.plist, set by tools/ship.py; none in test and Xcode builds)
    private var bundledDemo: URL? { Bundle.main.url(forResource: "Demo", withExtension: nil) }
    private var bundledCommit: String? { (Bundle.main.object(forInfoDictionaryKey: "LedgerDemoCommit") as? String).flatMap { $0.count == 40 ? $0 : nil } }
    /// GitHub first, then the mirror the app's sources use (Info.plist)
    private var demoSources: [DemoRepository.Source] {
        let mirror = (Bundle.main.object(forInfoDictionaryKey: "LedgerDemoMirror") as? String).flatMap { URL(string: $0) }
        return [.github] + (mirror.map { [.mirror($0)] } ?? [])
    }
    private var demoCommit: String? {
        get { UserDefaults.standard.string(forKey: Store.demoCommitKey) }
        set { UserDefaults.standard.set(newValue, forKey: Store.demoCommitKey) }
    }

    /// the built-in copy in place of the one on this phone
    private func installBundledDemo() async throws {
        guard let src = bundledDemo else { throw DemoRepository.Failure.invalidSnapshot }
        let dst = demoRoot
        try await Task.detached { try DemoRepository.put(try DemoRepository.folderFiles(src), at: dst) }.value
        demoCommit = bundledCommit
    }

    /// a commit of ledger-demo (main's latest when none is given) in place of the copy on this phone
    private func downloadDemo(_ commit: String? = nil) async throws {
        let installed = try await DemoRepository.install(at: demoRoot, reset: true, commit: commit, sources: demoSources)
        demoCommit = installed
        demoUpdate = nil
    }

    private var demoConfig: RepoConfig {
        var c = RepoConfig()
        c.id = Store.demoID
        c.kind = .local
        c.name = LS("演示账本")
        c.folderName = Store.demoFolder
        return c
    }

    /// open the demo: the copy on this phone, else the built-in one (downloaded only when the app has none)
    func openDemo() async {
        guard !demoBusy else { return }
        demoBusy = true
        defer { demoBusy = false }
        if !FileManager.default.fileExists(atPath: demoRoot.appendingPathComponent("main.bean").path) {
            do {
                if bundledDemo != nil { try await installBundledDemo() } else { try await downloadDemo() }
            } catch {
                showFailure(LS("无法打开演示账本：%@", error.localizedDescription))
                return
            }
        }
        guard !isDemo else { return }
        await saveConfig(demoConfig)
        await refresh()
        tab = .overview
        show(LS("已打开演示账本，数据均为虚构"))
    }

    /// whether ledger-demo has moved on from the copy on this phone: at most every few hours, quietly (offline,
    /// rate-limited or unreachable is simply no news)
    func checkDemoUpdate(force: Bool = false) async {
        guard isDemo, !demo else { return }
        let last = UserDefaults.standard.double(forKey: Store.demoCheckedKey)
        if !force, Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        guard let latest = try? await DemoRepository.latestCommit(sources: demoSources) else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Store.demoCheckedKey)
        demoUpdate = latest == demoCommit ? nil : latest
    }

    /// the demo as it came, from the latest of ledger-demo (`update`: that commit), or the built-in copy when it
    /// can't be reached: what was recorded in it is gone. A failure keeps the copy that was there.
    func resetDemo(to update: String? = nil) async {
        guard isDemo, !demoBusy else { return }
        demoBusy = true
        defer { demoBusy = false }
        var word = update != nil ? LS("演示账本已更新") : LS("演示账本已重置")
        do {
            try await downloadDemo(update)
        } catch {
            guard update == nil, bundledDemo != nil else { showFailure(LS("更新失败，已保留原演示账本：%@", error.localizedDescription)); return }
            do { try await installBundledDemo() } catch { showFailure(LS("重置失败，已保留原演示账本：%@", error.localizedDescription)); return }
            word = LS("连不上演示账本仓库，已恢复为 App 内置的版本")
        }
        if isDemo {
            pending = []
            savePending()
            forgetTree()
            await refresh()
        } else {
            // The user may switch ledgers while the download is running. Clear only the demo's
            // old queue/cache, so it cannot replay pre-reset edits when opened again.
            Prefs.set(Store.key("pending", Store.demoID), [Op]())
            Prefs.set(Store.key("tree", Store.demoID), RepoTree?.none)
        }
        show(word)
    }

    /// back to the ledger used before (the first of one's own)
    func leaveDemo() async {
        guard isDemo, let c = ownSources.first else { return }
        await switchLedger(c.id)
    }

    /// a new ledger on this phone with the demo's accounts and categories, opened at once: from the demo as
    /// loaded, the copy on this phone, or the built-in one (downloaded only when the app has none)
    func createEmptyLedger() async {
        guard !demoBusy else { return }
        demoBusy = true
        defer { demoBusy = false }
        let from: Ledger
        if isDemo, let L = L { from = L } else {
            let local = demoRoot
            var folder: URL? = FileManager.default.fileExists(atPath: local.appendingPathComponent("main.bean").path) ? local : bundledDemo
            if folder == nil {
                do { try await downloadDemo(); folder = local } catch { showFailure(LS("无法下载账户与分类：%@", error.localizedDescription)); return }
            }
            let src = folder!
            from = await Task.detached {
                loadLedger(root: "main.bean") { p in try String(contentsOf: src.appendingPathComponent(p), encoding: .utf8) }
            }.value
        }
        let fm = FileManager.default
        var title = LS("我的账本"), n = 1
        while fm.fileExists(atPath: FolderBackend.localRoot(title).path) { n += 1; title = LS("我的账本") + " \(n)" }
        let root = FolderBackend.localRoot(title)
        let files = EmptyLedger.files(from: from, title: title, year: String(Day.today().prefix(4)))
        do {
            for (path, text) in files {
                let u = root.appendingPathComponent(path)
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: u, options: .atomic)
            }
        } catch {
            showFailure(LS("新建账本失败：%@", error.localizedDescription))
            return
        }
        var c = RepoConfig()
        c.id = UUID().uuidString
        c.kind = .local
        c.name = title
        c.folderName = title
        await saveConfig(c)
        await refresh()
        tab = .overview
        show(LS("已新建「%@」，可以开始记账了", title))
    }
}

/// on the overview of the demo: what it is, and the way out (into a ledger of one's own, or back)
struct DemoBanner: View {
    @Environment(Store.self) var store
    @State private var confirmReset = false
    @State private var confirmUpdate = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.icon) {
                HStack(spacing: AppSpacing.icon) {
                    Image(systemName: "sparkles").foregroundStyle(Color.jadeInk)
                    Text(LS("正在查看演示账本")).font(.headline)
                    Spacer()
                    Menu {
                        Button(role: .destructive) { confirmReset = true } label: { Label(LS("重置演示账本"), systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .accessibilityLabel(LS("更多"))
                }
                if store.demoBusy { ProgressView(LS("正在下载演示账本…")) }
                else if store.demoUpdate != nil {
                    // ledger-demo has moved on: fetched when asked (it replaces what was recorded here)
                    HStack(spacing: AppSpacing.icon) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Color.jadeInk)
                        Text(LS("演示数据有更新")).font(.subheadline.weight(.medium))
                        Spacer()
                        Button { confirmUpdate = true } label: { Label(LS("更新"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle()) }
                            .buttonStyle(.bordered).tint(.jade).controlSize(.small)
                    }
                    .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                }
                Text(LS("数据均为虚构，可以随意记账、修改，随时重置。觉得合适，就用它的账户和分类新建一个空账本。"))
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: AppSpacing.icon) {
                    // an icon and its words side by side (a Label in a list row's button shows the words only)
                    Button { Task { await store.createEmptyLedger() } } label: {
                        HStack(spacing: AppSpacing.icon) { Image(systemName: "doc.on.doc"); Text(LS("复制为我的空账本")) }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if !store.ownSources.isEmpty {
                        Button { Task { await store.leaveDemo() } } label: {
                            HStack(spacing: AppSpacing.icon) { Image(systemName: "arrow.uturn.backward"); Text(LS("返回我的账本")) }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .tint(.jade)
                .controlSize(.regular)
                .font(.subheadline.weight(.semibold))
            }
            .padding(AppSpacing.content)
            .background(Color.jade.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).stroke(Color.jade.opacity(0.25), lineWidth: 1))
            .cardRow()
        }
        .confirmationDialog(LS("重置演示账本？会下载最新版本（连不上时恢复为 App 内置的版本），在里面记的和改的都会清除。"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await store.resetDemo() } } label: { Text(LS("重置")) }
        }
        .confirmationDialog(LS("更新演示账本？下载成功后，在里面记的和改的都会清除；失败时保留现在的。"), isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await store.resetDemo(to: store.demoUpdate) } } label: { Text(LS("更新")) }
        }
        .task {
            // screenshots: an update on offer (no network on CI)
            if store.demoEnv["LEDGER_DEMO_UPDATE"] != nil { store.demoUpdate = String(repeating: "f", count: 40); return }
            await store.checkDemoUpdate()
        }
    }
}

/// on one's own overview: the demo, one tap away (closed with ✕, back on in 设置)
struct DemoEntryCard: View {
    @Environment(Store.self) var store
    @AppStorage(Store.demoEntryKey) private var shown = true

    var body: some View {
        if shown && !store.isDemo {
            Section {
                HStack(spacing: AppSpacing.icon) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.jadeInk)
                        .frame(width: 40, height: 40)
                        .background(Color.jade.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("演示账本")).font(.subheadline.weight(.semibold))
                        Text(LS("看看完整功能用起来的样子，数据均为虚构")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if store.demoBusy { ProgressView() }
                    Button { Task { await store.openDemo() } } label: { Label(LS("打开"), systemImage: "folder").labelStyle(ControlLabelStyle()) }
                        .disabled(store.demoBusy)
                        .buttonStyle(.bordered).tint(.jade).controlSize(.small)
                    Button { withAnimation { shown = false }; store.show(LS("已关闭演示账本入口，可在「设置 → 更多」里重新打开")) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LS("不再显示"))
                }
                .padding(AppSpacing.control)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .cardRow()
            }
        }
    }
}
