import SwiftUI
import LedgerKit

/// 截图记账: what was read off the screenshot, row by row as on the screen (a tab between pieces on one row).
/// For now it is shown as read, to copy; turning it into an entry comes next.
struct ScanResultView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let result: ScanResult
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(ocrRows(result.boxes).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            ForEach(Array(row.enumerated()), id: \.offset) { i, b in
                                Text(b.text)
                                    .font(.callout)
                                    .foregroundStyle(i == 0 && row.count > 1 ? Color.secondary : Color.primary)
                                    .frame(maxWidth: i == 0 && row.count > 1 ? nil : .infinity, alignment: i == 0 ? .leading : .trailing)
                            }
                        }
                        .textSelection(.enabled)
                    }
                } header: {
                    Text(LS("识别出 %@ 行", String(ocrRows(result.boxes).count))).textCase(nil)
                } footer: {
                    Text(LS("在本机识别，截图读完即丢弃，没有保存或上传。这一版先显示识别出的文字；复制后发给开发者，用来完善自动填写。"))
                }
            }
            .navigationTitle(LS("识别结果"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("关闭")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? LS("已复制") : LS("复制")) {
                        UIPasteboard.general.string = result.text
                        copied = true
                    }
                }
            }
        }
    }
}
