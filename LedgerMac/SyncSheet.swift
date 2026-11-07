import SwiftUI
import LedgerKit

struct SyncSheet: View {
    let folder: URL
    let status: FolderGitStatus
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var syncing = false

    var body: some View {
        VStack(spacing: 0) {
            List(status.paths, id: \.self) { Text($0).lineLimit(1).truncationMode(.middle) }
                .frame(height: 200)
            if status.ahead > 0 {
                Text(chinese ? "另有 \(status.ahead) 个本机提交" : "Plus \(status.ahead) local commits")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 16)
            HStack {
                Spacer()
                Button(chinese ? "取消" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(syncing)
                Button(chinese ? "提交并推送" : "Commit and Push") { sync() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(syncing || !status.canSync)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460)
        .interactiveDismissDisabled(syncing)
    }

    private func sync() {
        syncing = true
        message = ""
        let folder = folder, paths = status.paths
        Task { @MainActor in
            let result = await Task.detached { Result { try syncFolderGit(folder, paths: paths) } }.value
            syncing = false
            onChange()
            switch result {
            case .success: dismiss()
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
}
