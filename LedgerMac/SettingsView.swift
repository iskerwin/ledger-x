import SwiftUI
import LedgerKit

enum Appearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// what this computer keeps for itself; what the ledger shares stays in its ledger-x.json
struct SettingsView: View {
    let folder: String
    @Binding var picking: Bool
    @AppStorage("defaultPage") private var defaultPage = Page.overview.rawValue
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("hideAmounts") private var hideAmounts = false

    var body: some View {
        TabView {
            Form {
                Picker("默认打开", selection: $defaultPage) {
                    ForEach(Page.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            }
            .tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                Picker("外观", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            }
            .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            Form {
                Toggle("隐藏金额", isOn: $hideAmounts)
            }
            .tabItem { Label("安全", systemImage: "lock") }
            Form {
                LabeledContent("当前账本") {
                    Text(folder.isEmpty ? "未打开" : folder).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("切换账本…") { picking = true }
            }
            .tabItem { Label("账本", systemImage: "folder") }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 320)
    }
}
