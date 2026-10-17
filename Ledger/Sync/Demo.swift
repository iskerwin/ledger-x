import Foundation
import SwiftUI
import LedgerKit

// The public ledger-demo repository supplies the demo on first use and reset. The installed
// copy is local: edits stay on this phone, existing copies work offline, and nothing is pushed upstream.

extension Store {
    static let demoID = "demo"
    /// the folder names under On My iPhone › Ledger
    static let demoFolder = "Demo"
    static let demoEntryKey = "ledger.demo.entry"

    var isDemo: Bool { cfg.id == Store.demoID }
    /// the ledgers other than the demo
    var ownSources: [RepoConfig] { sources.filter { $0.id != Store.demoID } }

    private func installDemo(reset: Bool) async throws {
        try await DemoRepository.install(at: FolderBackend.localRoot(Store.demoFolder), reset: reset)
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
        guard !demoBusy else { return }
        demoBusy = true
        defer { demoBusy = false }
        do { try await installDemo(reset: false) } catch { show(LS("无法打开演示账本：%@", error.localizedDescription)); return }
        guard !isDemo else { return }
        await saveConfig(demoConfig)
        await refresh()
        tab = .overview
        show(LS("已打开演示账本，数据均为虚构"))
    }

    /// the demo as it came: what was recorded in it is gone
    func resetDemo() async {
        guard isDemo, !demoBusy else { return }
        demoBusy = true
        defer { demoBusy = false }
        do { try await installDemo(reset: true) } catch { show(LS("更新失败，已保留原演示账本：%@", error.localizedDescription)); return }
        guard isDemo else { return }
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
        guard !demoBusy else { return }
        demoBusy = true
        defer { demoBusy = false }
        let from: Ledger
        if isDemo, let L = L { from = L } else {
            do { try await installDemo(reset: false) } catch { show(LS("无法下载账户与分类：%@", error.localizedDescription)); return }
            let src = FolderBackend.localRoot(Store.demoFolder)
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
                if store.demoBusy { ProgressView(LS("正在下载演示账本…")) }
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
        .confirmationDialog(LS("下载最新演示账本并重置？成功后，在里面记的和改的都会清除。"), isPresented: $confirmReset, titleVisibility: .visible) {
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
                    if store.demoBusy { ProgressView() }
                    Button(LS("打开")) { Task { await store.openDemo() } }
                        .disabled(store.demoBusy)
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
