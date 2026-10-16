import SwiftUI
import LedgerKit

/// 账本同步: whether what was recorded is only on this phone or already in the ledger's storage, why not, and
/// what to do about it — instead of a cloud icon alone. Opened from the status icon in the bar and from 设置.
struct SyncView: View {
    @EnvironmentObject var store: Store
    /// a pending change opened to see why it was not sent
    @State private var why: Op?

    private var waiting: [Op] { store.pending.filter { $0.failed == nil && $0.held == nil } }
    private var held: [Op] { store.pending.filter { $0.held != nil } }
    private var failed: [Op] { store.pending.filter { $0.failed != nil } }

    var body: some View {
        List {
            hero
            banner
            if !store.pending.isEmpty {
                Section(LS("待同步")) {
                    ForEach(failed + held + waiting) { o in opRow(o) }
                }
            }
            Section {
                NavigationLink { HistoryView() } label: {
                    LabeledContent(LS("已同步记录"), value: store.history.isEmpty ? "" : LS("%@ 项", store.history.count))
                }
            } footer: {
                Text(LS("最近的改动可以在这里撤回。"))
            }
            Section(LS("连接状态")) {
                LabeledContent {
                    Text(store.syncState == .offline ? LS("未连接") : LS("已连接")).foregroundStyle(store.syncState == .offline ? Color.orange : Color.secondary)
                } label: { Label(LS("网络"), systemImage: store.syncState == .offline ? "wifi.slash" : "wifi") }
                LabeledContent { Text(store.cfg.title) } label: { Label(LS("账本"), systemImage: "book.closed") }
                LabeledContent { Text(store.cfg.kind.name) } label: { Label(LS("存储"), systemImage: store.cfg.kind.symbol) }
                if !store.syncError.isEmpty && store.syncState == .error {
                    DisclosureGroup(LS("错误详情")) {
                        Text(store.syncError).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button { Task { await store.syncNow() } } label: {
                    HStack {
                        if store.syncState == .syncing { ProgressView().tint(Color.onJade) }
                        Text(store.syncState == .syncing ? LS("同步中…") : LS("重新同步"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large).fontWeight(.semibold)
                .disabled(store.syncState == .syncing)
                Text(LS("同步成功后，电脑上 git pull 即可看到这些记录。")).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            .background(.bar)
        }
        .navigationTitle(LS("账本同步"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(LS("没有提交的原因"), isPresented: Binding(get: { why != nil }, set: { if !$0 { why = nil } }), presenting: why) { o in
            if o.held != nil { Button(LS("推送")) { Task { await store.release(o) } } }
            Button(LS("移除这项改动"), role: .destructive) { Task { await store.dropPending(o) } }
            Button(LS("保留"), role: .cancel) {}
        } message: { o in
            Text(o.failed ?? o.held ?? "")
        }
    }

    // MARK: the state

    private enum Shown { case synced, local, failed, syncing }
    private var shown: Shown {
        if store.syncState == .syncing { return .syncing }
        if store.syncState == .error || !failed.isEmpty { return .failed }
        if !store.pending.isEmpty || store.syncState == .offline { return .local }
        return .synced
    }

    private var hero: some View {
        let s = shown
        let (icon, color, title): (String, Color, String) = {
            switch s {
            case .synced: return ("checkmark.icloud", .jade, LS("已同步"))
            case .local: return ("iphone", .jade, LS("已保存到本机"))
            case .failed: return ("exclamationmark.icloud", .orange, LS("同步没有完成"))
            case .syncing: return ("arrow.triangle.2.circlepath.icloud", .jade, LS("正在同步"))
            }
        }()
        return Section {
            HStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(color)
                        .frame(width: 70, height: 70)
                    if s == .local {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.jade)
                            .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.semibold))
                    if !store.pending.isEmpty { Text(LS("%@ 项变更等待同步", store.pending.count)).font(.subheadline).foregroundStyle(.secondary) }
                    if store.syncState == .offline {
                        Text(LS("离线")).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2)
                            .foregroundStyle(Color.orange).background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    if let d = store.lastSync {
                        Text(LS("上次同步 %@", d.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .cardRow()
        }
    }

    @ViewBuilder
    private var banner: some View {
        let text: String? = {
            if store.syncState == .offline { return LS("联网后将自动重试，现在可以继续记账") }
            if !failed.isEmpty { return LS("%@ 项改动没有提交（别处已改了同一处，或内容有冲突），点开看原因，可以移除或保留", failed.count) }
            if !held.isEmpty { return LS("%@ 项改动没通过提交前检查，暂存在本机，点开可以推送或移除", held.count) }
            if store.syncState == .error { return LS("同步出错：%@", store.syncError) }
            return nil
        }()
        if let t = text {
            Section {
                Label(t, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(Color.orange)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .cardRow()
            }
        }
    }

    private func opRow(_ o: Op) -> some View {
        let state: (String, Color) = o.failed != nil ? (LS("未提交"), .loss) : o.held != nil ? (LS("暂存本机"), .orange) : (LS("等待上传"), .orange)
        return Button { if o.failed != nil || o.held != nil { why = o } } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(o.summary ?? o.label ?? o.path).lineLimit(1).foregroundStyle(.primary)
                    Text([o.date ?? "", o.path].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let a = o.amountText, !a.isEmpty { Text(masked(a)).monospacedDigit().foregroundStyle(.primary).sensitive() }
                    Text(state.0).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(state.1).background(state.1.opacity(0.14), in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(LS("移除"), role: .destructive) { Task { await store.dropPending(o) } }
            if o.held != nil { Button(LS("推送")) { Task { await store.release(o) } }.tint(Color.jade) }
        }
    }
}
