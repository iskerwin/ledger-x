import Foundation
import SwiftUI
import LedgerKit

// 演示账本: the demo ledger that comes with the app (made-up data), kept in the app's own files so it can be
// tried out like a real one — recorded in, edited, reset. From it, 我的账本: a new ledger on this phone with the
// demo's accounts and categories and no transactions, ready to use (and to move to a Git repository later).

extension Store {
    static let demoID = "demo"
    /// the folder names under On My iPhone › Ledger
    static let demoFolder = "Demo"
    static let demoEntryKey = "ledger.demo.entry"

    var isDemo: Bool { cfg.id == Store.demoID }
    /// the ledgers other than the demo
    var ownSources: [RepoConfig] { sources.filter { $0.id != Store.demoID } }

    /// the bundled demo copied into the app's files (again, from scratch, with `reset`)
    private func installDemo(reset: Bool) throws {
        let fm = FileManager.default
        let dst = FolderBackend.localRoot(Store.demoFolder)
        if reset, fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        if fm.fileExists(atPath: dst.appendingPathComponent("main.bean").path) { return }
        guard let src = Bundle.main.url(forResource: "Demo", withExtension: nil) else {
            throw GitHubError(status: 404, message: LS("找不到内置的演示账本"))
        }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
    }

    private var demoConfig: RepoConfig {
        var c = RepoConfig()
        c.id = Store.demoID
        c.kind = .local
        c.name = LS("演示账本")
        c.folderName = Store.demoFolder
        return c
    }

    /// open the demo (installed the first time)
    func openDemo() async {
        do { try installDemo(reset: false) } catch { show(error.localizedDescription); return }
        guard !isDemo else { return }
        await saveConfig(demoConfig)
        await refresh()
        tab = .overview
        show(LS("已打开演示账本，数据均为虚构"))
    }

    /// the demo as it came: what was recorded in it is gone
    func resetDemo() async {
        guard isDemo else { return }
        do { try installDemo(reset: true) } catch { show(error.localizedDescription); return }
        pending = []
        savePending()
        forgetTree()
        await refresh()
        show(LS("演示账本已重置"))
    }

    /// back to the ledger used before (the first of one's own)
    func leaveDemo() async {
        guard isDemo, let c = ownSources.first else { return }
        await switchLedger(c.id)
    }

    /// a new ledger on this phone with the demo's accounts and categories, opened at once
    func createEmptyLedger() async {
        // the structure: the demo as loaded, or read from the bundle when it isn't open
        let from: Ledger
        if isDemo, let L = L { from = L } else {
            guard let src = Bundle.main.url(forResource: "Demo", withExtension: nil) else { show(LS("找不到内置的演示账本")); return }
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
            show(LS("新建账本失败：%@", error.localizedDescription))
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
    @EnvironmentObject var store: Store
    @State private var confirmReset = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.jade)
                    Text(LS("正在查看演示账本")).font(.headline)
                    Spacer()
                    Menu {
                        Button(role: .destructive) { confirmReset = true } label: { Label(LS("重置演示账本"), systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                }
                Text(LS("数据均为虚构，可以随意记账、修改，随时重置。觉得合适，就用它的账户和分类新建一个空账本。"))
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    // an icon and its words side by side (a Label in a list row's button shows the words only)
                    Button { Task { await store.createEmptyLedger() } } label: {
                        HStack(spacing: 6) { Image(systemName: "doc.on.doc"); Text(LS("复制为我的空账本")) }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if !store.ownSources.isEmpty {
                        Button { Task { await store.leaveDemo() } } label: {
                            HStack(spacing: 6) { Image(systemName: "arrow.uturn.backward"); Text(LS("返回我的账本")) }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .tint(.jade)
                .controlSize(.regular)
                .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .background(Color.jade.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.jade.opacity(0.25), lineWidth: 1))
            .cardRow()
        }
        .confirmationDialog(LS("重置演示账本？在里面记的和改的都会清除。"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(LS("重置"), role: .destructive) { Task { await store.resetDemo() } }
        }
    }
}

/// on one's own overview: the demo, one tap away (closed with ✕, back on in 设置)
struct DemoEntryCard: View {
    @EnvironmentObject var store: Store
    @AppStorage(Store.demoEntryKey) private var shown = true

    var body: some View {
        if shown && !store.isDemo {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.jade)
                        .frame(width: 40, height: 40)
                        .background(Color.jade.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LS("演示账本")).font(.subheadline.weight(.semibold))
                        Text(LS("看看完整功能用起来的样子，数据均为虚构")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button(LS("打开")) { Task { await store.openDemo() } }
                        .buttonStyle(.bordered).tint(.jade).controlSize(.small)
                    Button { withAnimation { shown = false } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LS("不再显示"))
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .cardRow()
            } footer: {
                Text(LS("关掉后可在「设置 → 更多」里重新打开。"))
            }
        }
    }
}
