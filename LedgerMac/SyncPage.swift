import SwiftUI
import LedgerKit

/// 同步与改动: what changed here and on the remote, what goes into the commit. Written to the files, committed and pushed are three
/// steps, each said for itself; this only ever fast-forwards, through the same local git as before
struct SyncPage: View {
    let folder: URL
    let status: FolderGitStatus?
    let remoteReached: Bool
    let onChange: () -> Void
    @State private var branch: String?
    @State private var log: [FolderGitCommit] = []
    /// what is left out of the commit; a file that appears later goes in unless taken out
    @State private var excluded = Set<String>()
    @State private var shown: String?
    @State private var diff = ""
    @State private var commitMessage = ""
    @State private var busy = false
    @State private var failure = ""
    @State private var done = ""

    var body: some View {
        Group {
            if let status {
                content(status)
            } else {
                ContentUnavailableView("这个文件夹不能同步", systemImage: "arrow.up.arrow.down")
            }
        }
        .background(Color.page)
        .task(id: "\(status?.paths ?? [])|\(status?.ahead ?? 0)") { await read() }
        .task(id: shown) { await readDiff() }
    }

    private func content(_ status: FolderGitStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(status)
                // nothing here to commit: no empty card
                if !status.paths.isEmpty || status.ahead > 0 {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("本机改动").fontWeight(.medium).padding(.bottom, 8)
                            ForEach(status.paths, id: \.self) { path in
                                Divider()
                                HStack {
                                    Toggle(isOn: Binding(get: { !excluded.contains(path) }, set: { on in
                                        if on { excluded.remove(path) } else { excluded.insert(path) }
                                    })) {
                                        Text(path).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button(shown == path ? "收起差异" : "查看差异") { shown = shown == path ? nil : path }
                                        .buttonStyle(.link)
                                }
                                .padding(.vertical, 6)
                                if shown == path && !KitPrivacy.masked {
                                    ScrollView(.horizontal) {
                                        Text(diff)
                                            .font(.system(size: 11, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                    .padding(.bottom, 6)
                                }
                            }
                            if status.ahead > 0 {
                                Divider()
                                Text("另有 \(status.ahead) 个本机提交").foregroundStyle(.secondary).padding(.top, 6)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    TextField("提交说明", text: $commitMessage, prompt: Text("提交说明"))
                        .textFieldStyle(.roundedBorder)
                    Button("提交并推送") { sync(status) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || (paths(status).isEmpty && status.ahead == 0))
                }
                // always in its place, so the result moves nothing
                Text(failure.isEmpty ? done : failure)
                    .font(.callout)
                    .foregroundStyle(failure.isEmpty ? Color.secondary : Color.loss)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                if !log.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("最近提交").fontWeight(.medium).padding(.bottom, 8)
                            ForEach(log) { commit in
                                Divider()
                                HStack(spacing: 12) {
                                    Text(commit.date).monospacedDigit().foregroundStyle(.secondary)
                                    Text(commit.subject).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func header(_ status: FolderGitStatus) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(folder.lastPathComponent).font(.title2.weight(.semibold))
                    if let branch { Text(branch).font(.callout).foregroundStyle(.secondary) }
                }
                Text(summary(status)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("拉取", systemImage: "arrow.down") { pull() }
                .disabled(busy || (remoteReached && status.behind == 0))
        }
    }

    private func summary(_ status: FolderGitStatus) -> String {
        var parts = ["\(status.paths.count) 个文件改动"]
        if status.behind > 0 { parts.append("远端有 \(status.behind) 个新提交") }
        if !remoteReached { parts.append("没有连上远端") }
        return parts.joined(separator: " · ")
    }

    private func paths(_ status: FolderGitStatus) -> [String] {
        status.paths.filter { !excluded.contains($0) }
    }

    private func read() async {
        let folder = folder
        let found = await Task.detached { (folderGitBranch(folder), folderGitLog(folder)) }.value
        guard !Task.isCancelled else { return }
        branch = found.0
        log = found.1
        await readDiff()
    }

    private func readDiff() async {
        guard let shown else {
            diff = ""
            return
        }
        let folder = folder
        let text = await Task.detached { folderGitDiff(folder, path: shown) }.value
        guard !Task.isCancelled else { return }
        diff = text
    }

    private func sync(_ status: FolderGitStatus) {
        run(success: "已提交并推送") { [folder, chosen = paths(status), message = commitMessage] in
            try syncFolderGit(folder, paths: chosen, message: message)
        } after: {
            commitMessage = ""
            excluded = []
        }
    }

    private func pull() {
        run(success: "已拉取") { [folder] in try pullFolderGit(folder) } after: {}
    }

    private func run(success: String, _ work: @escaping @Sendable () throws -> Void, after: @escaping () -> Void) {
        busy = true
        failure = ""
        done = ""
        Task { @MainActor in
            let result = await Task.detached { Result { try work() } }.value
            busy = false
            onChange()
            switch result {
            case .success:
                done = success
                after()
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }
}
