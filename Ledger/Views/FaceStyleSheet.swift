import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import LedgerKit

/// 长按卡面 → 编辑卡面: one account's card changed by hand: its institution, colour, texture and watermark (a text,
/// an icon of one's own, or none). Kept on this phone for this ledger; the preview at the top follows each change.
struct FaceStyleSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let account: String
    let title: String
    let tint: Color
    @State private var style = FaceStyle()
    @State private var loaded = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    /// icons added while the sheet is open: the ones not kept are removed on leaving
    @State private var added: [String] = []
    @State private var iconFailed = false

    private enum MarkChoice: String, CaseIterable { case auto, text, icon, off }

    private var markChoice: Binding<MarkChoice> {
        Binding {
            switch style.mark {
            case nil: .auto
            case .text?: .text
            case .icon?, .symbol?: .icon
            case .off?: .off
            }
        } set: { c in
            switch c {
            case .auto: style.mark = nil
            case .text: style.mark = .text(FacePattern.mark(title))
            // the built-in icon of the institution the card is for; an uploaded one when there is one
            case .icon: style.mark = style.icon != nil ? .icon : institutionID.map(FaceStyle.Mark.symbol) ?? .icon
            case .off: style.mark = .off
            }
        }
    }

    private var markText: Binding<String> {
        Binding {
            if case .text(let t)? = style.mark { return t }
            return ""
        } set: { t in style.mark = .text(String(t.prefix(4))) }
    }

    /// what 自动 stands for: the institution recognised from the account's name
    private var recognised: String? {
        institution(account: account, name: title).flatMap { i in FaceLook.named.first { $0.id == i.id }?.name }
    }

    /// the institution the card is drawn for: the one picked, else the one recognised
    private var institutionID: String? {
        style.institution.map { $0 == FaceStyle.noInstitution ? nil : $0 } ?? institution(account: account, name: title)?.id
    }

    var body: some View {
        let ledger = store.cfg.id
        NavigationStack {
            Form {
                Section {
                    FaceCard(account: account, title: title, tint: tint, preview: style) { _ in
                        VStack(alignment: .leading, spacing: AppSpacing.control) {
                            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(LS("当前余额")).font(.caption)
                            Text(masked("1,234.56")).heroAmount().monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("face.preview")
                }
                Section {
                    Picker(LS("机构"), selection: $style.institution) {
                        Text(recognised.map { LS("自动（%@）", $0) } ?? LS("自动（未识别）")).tag(String?.none)
                        Text(LS("不用")).tag(String?.some(FaceStyle.noInstitution))
                        ForEach(FaceLook.named, id: \.id) { i in Text(i.name).tag(String?.some(i.id)) }
                    }
                    .accessibilityIdentifier("face.institution")
                } footer: {
                    Text(LS("按账户名自动认出常见银行和钱包；认错或想换时在这里选，「不用」就用大类颜色。"))
                }
                Section {
                    IconTintGrid(tint: $style.color, fallback: FaceDesign(account: account, title: title, tint: tint, style: withoutColor, ledger: ledger).fill)
                } header: {
                    Text(LS("颜色"))
                } footer: {
                    Text(LS("「默认」是机构的配色，没有机构时是大类颜色。"))
                }
                Section {
                    Picker(LS("纹理"), selection: $style.pattern) {
                        Text(LS("自动")).tag(String?.none)
                        Text(LS("斜线")).tag(String?.some(FacePatternKind.stripes.rawValue))
                        Text(LS("圆环")).tag(String?.some(FacePatternKind.rings.rawValue))
                        Text(LS("圆点")).tag(String?.some(FacePatternKind.dots.rawValue))
                        Text(LS("网格")).tag(String?.some(FacePatternKind.grid.rawValue))
                        Text(LS("无")).tag(String?.some(FacePatternKind.none.rawValue))
                    }
                    .accessibilityIdentifier("face.pattern")
                }
                markSection(ledger)
                Section {
                    Button {
                        style = FaceStyle()
                    } label: {
                        Label(LS("恢复默认"), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle())
                    }
                    .disabled(style.isEmpty)
                    .accessibilityIdentifier("face.reset")
                } footer: {
                    Text(LS("卡面设置和上传的图标只存在这台手机，按账本分开，不写进账本。"))
                }
            }
            .navigationTitle(LS("编辑卡面"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { leave(keep: false) } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { leave(keep: true) } label: { SaveLabel() }
                        .accessibilityIdentifier("face.save")
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    adopt(data, ledger: ledger)
                    photo = nil
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.png, .image]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                adopt(try? Data(contentsOf: url), ledger: ledger)
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                style = store.faceStyles[account] ?? FaceStyle()
                // UI tests: an icon as if picked, so the upload path can be checked without the photo library
                if let path = store.demoEnv["LEDGER_FACE_ICON"] { adopt(FileManager.default.contents(atPath: path), ledger: ledger) }
            }
        }
        .formSheet()
    }

    private var withoutColor: FaceStyle { var s = style; s.color = nil; return s }

    @ViewBuilder
    private func markSection(_ ledger: String) -> some View {
        Section {
            Picker(LS("水印"), selection: markChoice) {
                Text(LS("自动")).tag(MarkChoice.auto)
                Text(LS("文字")).tag(MarkChoice.text)
                Text(LS("图标")).tag(MarkChoice.icon)
                Text(LS("不显示")).tag(MarkChoice.off)
            }
            .accessibilityIdentifier("face.mark")
            if markChoice.wrappedValue == .text {
                TextField(LS("最多 4 个字"), text: markText)
                    .accessibilityIdentifier("face.markText")
            }
            if markChoice.wrappedValue == .icon {
                SymbolGrid(mark: $style.mark, uploaded: style.icon != nil)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(style.icon == nil ? LS("从照片选择图标") : LS("从照片换一个图标"), systemImage: "photo").labelStyle(ControlLabelStyle())
                }
                Button { choosingFile = true } label: {
                    Label(LS("从文件选择图标"), systemImage: "folder").labelStyle(ControlLabelStyle())
                }
                if style.icon != nil, style.mark == .icon {
                    Picker(LS("图标样式"), selection: Binding { style.iconMono ?? true } set: { style.iconMono = $0 }) {
                        Text(LS("单色")).tag(true)
                        Text(LS("原色")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("face.iconStyle")
                    if style.iconMono ?? true {
                        LabeledSlider(title: LS("强度"), value: Binding { style.strength ?? FaceStyle.defaultStrength } set: { style.strength = $0 }, range: 0...1)
                    }
                }
            }
            if markChoice.wrappedValue != .off {
                LabeledSlider(title: LS("大小"), value: Binding { style.size ?? 1 } set: { style.size = $0 }, range: 0.5...1.5)
                LabeledSlider(title: LS("透明度"), value: Binding { style.opacity ?? FaceStyle.defaultOpacity } set: { style.opacity = $0 }, range: 0.04...0.4)
            }
        } header: {
            Text(LS("水印"))
        } footer: {
            if markChoice.wrappedValue == .icon {
                Text(iconFailed ? LS("这个文件不是能读的图片，换一张试试。")
                     : LS("点一个内置图标直接换；也可以从照片或文件选自己的图标。单色时图标变成卡面文字颜色的剪影：透明背景的 PNG 直接用它的形状；有底色的图片按四个角的颜色去掉背景，去不干净时调「强度」。"))
            }
        }
    }

    private func adopt(_ data: Data?, ledger: String) {
        guard let data, let name = FaceIcons.save(data, ledger: ledger) else { iconFailed = true; return }
        iconFailed = false
        added.append(name)
        style.icon = name
        style.mark = .icon
    }

    private func leave(keep: Bool) {
        let ledger = store.cfg.id
        let before = store.faceStyles[account]?.icon
        let kept = keep ? style.icon : before
        // icons no longer used: the ones picked here and not kept, and the old one when it was replaced or reset
        for name in Set(added + [before].compactMap { $0 }) where name != kept { FaceIcons.remove(name, ledger: ledger) }
        if keep {
            var s = style
            if s.icon != nil, s.mark != .icon { FaceIcons.remove(s.icon!, ledger: ledger); s.icon = nil }
            store.faceStyles[account] = s.isEmpty ? nil : s
        }
        dismiss()
    }
}

/// 水印 → 图标: the built-in institution icons to pick from, and the uploaded one when there is one
private struct SymbolGrid: View {
    @Binding var mark: FaceStyle.Mark?
    let uploaded: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.icon), count: 6), spacing: AppSpacing.control) {
            if uploaded {
                cell(.icon, LS("自己的图标")) { Image(systemName: "photo").font(.title3) }
            }
            ForEach(FaceLook.named, id: \.id) { i in
                if let image = FaceMarks.image(i.id) {
                    cell(.symbol(i.id), i.name) { image.renderingMode(.template).resizable().scaledToFit().frame(width: 26, height: 26) }
                        .accessibilityIdentifier("face.symbol." + i.id)
                }
            }
        }
        .padding(.vertical, AppSpacing.icon)
    }

    private func cell<V: View>(_ value: FaceStyle.Mark, _ title: String, @ViewBuilder _ image: () -> V) -> some View {
        let on = mark == value
        return Button { mark = value } label: {
            image()
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous).fill(Color(.tertiarySystemFill)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous).stroke(on ? Color.primary : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// a slider with its name before it, for the watermark's size, opacity and strength
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: AppSpacing.control) {
            Text(title).frame(minWidth: 56, alignment: .leading)
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
        }
    }
}
