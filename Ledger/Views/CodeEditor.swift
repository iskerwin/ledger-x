import SwiftUI
import UIKit
import LedgerKit

// Source text in colour: Beancount (entries, files) and BQL (queries). LedgerKit says what each piece is
// (codeSpans); this only picks the colours, which follow light and dark mode. The text is never changed.

/// 设置 → 外观 → 代码配色. 默认 follows the system colours (no background of its own); the others are the
/// well-known editor themes with their published colours — light and dark versions where the theme has both,
/// the dark-only ones keep their dark background in light mode too, like a code block on a web page.
enum CodeTheme: String, CaseIterable, Identifiable {
    case system, github, xcode, one, solarized, dracula, monokai, nord
    var id: String { rawValue }
    static let key = "ledger.codeTheme"
    static var current: CodeTheme { CodeTheme(rawValue: AppSettings.shared.codeTheme) ?? .system }

    var name: String {
        switch self {
        case .system: return LS("默认")
        case .github: return "GitHub"
        case .xcode: return "Xcode"
        case .one: return "One"
        case .solarized: return "Solarized"
        case .dracula: return "Dracula"
        case .monokai: return "Monokai"
        case .nord: return "Nord"
        }
    }
    var darkOnly: Bool { self == .dracula || self == .monokai || self == .nord }

    struct Palette {
        let bg: UInt32
        let fg: UInt32
        let c: [CodeToken: UInt32]
    }

    /// nil: the system colours
    func palette(dark: Bool) -> Palette? {
        switch self {
        case .system: return nil
        case .github:
            return dark
                ? Palette(bg: 0x0D1117, fg: 0xE6EDF3, c: [.date: 0xFFA657, .flag: 0xFF7B72, .keyword: 0xFF7B72, .string: 0xA5D6FF, .account: 0xD2A8FF,
                          .number: 0x79C0FF, .currency: 0xFFA657, .tag: 0x7EE787, .link: 0x79C0FF, .metaKey: 0x8B949E, .comment: 0x8B949E, .op: 0xFF7B72, .function: 0xD2A8FF])
                : Palette(bg: 0xFFFFFF, fg: 0x24292F, c: [.date: 0x953800, .flag: 0xCF222E, .keyword: 0xCF222E, .string: 0x0A3069, .account: 0x8250DF,
                          .number: 0x0550AE, .currency: 0x953800, .tag: 0x116329, .link: 0x0550AE, .metaKey: 0x6E7781, .comment: 0x6E7781, .op: 0xCF222E, .function: 0x8250DF])
        case .xcode:
            return dark
                ? Palette(bg: 0x1F1F24, fg: 0xFFFFFF, c: [.date: 0xFD8F3F, .flag: 0xFC5FA3, .keyword: 0xFC5FA3, .string: 0xFC6A5D, .account: 0x5DD8FF,
                          .number: 0xD0BF69, .currency: 0xD0A8FF, .tag: 0x67B7A4, .link: 0x5482FF, .metaKey: 0xBF8555, .comment: 0x6C7986, .op: 0xFC5FA3, .function: 0x67B7A4])
                : Palette(bg: 0xFFFFFF, fg: 0x000000, c: [.date: 0x643820, .flag: 0x9B2393, .keyword: 0x9B2393, .string: 0xC41A16, .account: 0x0B4F79,
                          .number: 0x1C00CF, .currency: 0x3900A0, .tag: 0x326D74, .link: 0x0F68A0, .metaKey: 0x815F03, .comment: 0x5D6C79, .op: 0x9B2393, .function: 0x326D74])
        case .one:
            return dark
                ? Palette(bg: 0x282C34, fg: 0xABB2BF, c: [.date: 0xE06C75, .flag: 0xC678DD, .keyword: 0xC678DD, .string: 0x98C379, .account: 0x61AFEF,
                          .number: 0xD19A66, .currency: 0xE5C07B, .tag: 0x56B6C2, .link: 0x56B6C2, .metaKey: 0xE06C75, .comment: 0x5C6370, .op: 0xC678DD, .function: 0x61AFEF])
                : Palette(bg: 0xFAFAFA, fg: 0x383A42, c: [.date: 0xE45649, .flag: 0xA626A4, .keyword: 0xA626A4, .string: 0x50A14F, .account: 0x4078F2,
                          .number: 0x986801, .currency: 0xC18401, .tag: 0x0184BC, .link: 0x0184BC, .metaKey: 0xE45649, .comment: 0xA0A1A7, .op: 0xA626A4, .function: 0x4078F2])
        case .solarized:
            let accents: [CodeToken: UInt32] = [.date: 0xCB4B16, .flag: 0xDC322F, .keyword: 0x859900, .string: 0x2AA198, .account: 0x268BD2,
                                                .number: 0xD33682, .currency: 0xB58900, .tag: 0x6C71C4, .link: 0x6C71C4, .op: 0xDC322F, .function: 0x268BD2]
            var c = accents
            c[.comment] = dark ? 0x586E75 : 0x93A1A1
            c[.metaKey] = dark ? 0x586E75 : 0x93A1A1
            return Palette(bg: dark ? 0x002B36 : 0xFDF6E3, fg: dark ? 0x839496 : 0x657B83, c: c)
        case .dracula:
            return Palette(bg: 0x282A36, fg: 0xF8F8F2, c: [.date: 0xFFB86C, .flag: 0xFF79C6, .keyword: 0xFF79C6, .string: 0xF1FA8C, .account: 0x8BE9FD,
                           .number: 0xBD93F9, .currency: 0x50FA7B, .tag: 0x50FA7B, .link: 0x8BE9FD, .metaKey: 0xFF79C6, .comment: 0x6272A4, .op: 0xFF79C6, .function: 0x50FA7B])
        case .monokai:
            return Palette(bg: 0x272822, fg: 0xF8F8F2, c: [.date: 0xFD971F, .flag: 0xF92672, .keyword: 0xF92672, .string: 0xE6DB74, .account: 0xA6E22E,
                           .number: 0xAE81FF, .currency: 0x66D9EF, .tag: 0xFD971F, .link: 0x66D9EF, .metaKey: 0xFD971F, .comment: 0x75715E, .op: 0xF92672, .function: 0xA6E22E])
        case .nord:
            return Palette(bg: 0x2E3440, fg: 0xD8DEE9, c: [.date: 0xD08770, .flag: 0x81A1C1, .keyword: 0x81A1C1, .string: 0xA3BE8C, .account: 0x88C0D0,
                           .number: 0xB48EAD, .currency: 0x8FBCBB, .tag: 0xEBCB8B, .link: 0xEBCB8B, .metaKey: 0x8FBCBB, .comment: 0x616E88, .op: 0x81A1C1, .function: 0x88C0D0])
        }
    }

    /// light or dark version for this trait (dark-only themes are always dark)
    private func palette(_ t: UITraitCollection) -> Palette? { palette(dark: darkOnly || t.userInterfaceStyle == .dark) }

    /// the code area's background; nil for 默认 (it sits on the page as it is)
    var background: UIColor? {
        guard self != .system else { return nil }
        return UIColor { t in hex(self.palette(t)?.bg ?? 0) }
    }
    var foreground: UIColor {
        guard self != .system else { return .label }
        return UIColor { t in hex(self.palette(t)?.fg ?? 0) }
    }
    /// dark-only themes: their text needs a dark keyboard and selection
    var forcesDark: Bool { darkOnly }

    func color(_ k: CodeToken) -> UIColor {
        guard self != .system else { return systemColor(k) }
        return UIColor { t in
            guard let p = self.palette(t) else { return .label }
            return hex(p.c[k] ?? p.fg)
        }
    }
}

private func hex(_ v: UInt32) -> UIColor {
    UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// 默认: the system colours, light and dark
private func systemColor(_ k: CodeToken) -> UIColor {
    switch k {
    case .date: return .secondaryLabel
    case .flag: return .systemOrange
    case .keyword: return .systemPurple
    case .string: return UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.99, green: 0.62, blue: 0.47, alpha: 1) : UIColor(red: 0.70, green: 0.27, blue: 0.10, alpha: 1) }
    case .account: return .systemBlue
    case .number: return .label
    case .currency: return .systemIndigo
    case .tag: return .systemGreen
    case .link: return .systemTeal
    case .metaKey: return .systemGray
    case .comment: return .tertiaryLabel
    case .op: return .systemPink
    case .function: return .systemCyan
    }
}

/// the colour of each kind of piece, in the chosen theme
func codeColor(_ k: CodeToken, _ theme: CodeTheme = .current) -> UIColor { theme.color(k) }

/// `text` in colour, for SwiftUI Text (read-only places)
func highlighted(_ text: String, _ lang: CodeLanguage, size: CGFloat = 12, theme: CodeTheme = .current) -> AttributedString {
    var out = AttributedString(text)
    if theme != .system { out.foregroundColor = Color(uiColor: theme.foreground) }
    guard lang != .plain else { return out }
    for s in codeSpans(text, lang) {
        guard let r = Range(NSRange(location: s.location, length: s.length), in: text),
              let a = Range(r, in: out) else { continue }
        out[a].foregroundColor = Color(uiColor: codeColor(s.kind, theme))
        if s.kind == .number || s.kind == .flag { out[a].font = .system(size: size, weight: .semibold, design: .monospaced) }
    }
    return out
}

/// colours a text view's text as it changes: only the lines an edit touched, so long files stay quick to type in
final class CodeHighlighter: NSObject, NSTextStorageDelegate {
    var language: CodeLanguage
    var theme: CodeTheme = .current
    var font: UIFont
    var bold: UIFont
    init(_ language: CodeLanguage, size: CGFloat) {
        self.language = language
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        bold = .monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    var base: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: theme.foreground] }
    static func attrs(_ theme: CodeTheme, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: theme.foreground]
    }

    func apply(_ ts: NSTextStorage, _ range: NSRange) {
        guard ts.length > 0 else { return }
        let lines = (ts.string as NSString).lineRange(for: NSRange(location: min(range.location, ts.length), length: min(range.length, ts.length - min(range.location, ts.length))))
        ts.setAttributes(base, range: lines)
        for s in codeSpans(ts.string, language, in: lines) {
            let r = NSRange(location: s.location, length: s.length)
            guard NSMaxRange(r) <= ts.length else { continue }
            ts.addAttribute(.foregroundColor, value: codeColor(s.kind, theme), range: r)
            if s.kind == .number || s.kind == .flag { ts.addAttribute(.font, value: bold, range: r) }
        }
    }

    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorage.EditActions, range: NSRange, changeInLength: Int) {
        guard mask.contains(.editedCharacters) else { return }
        apply(ts, range)
    }
}

/// a monospaced text view for source text, coloured: no autocorrection; read-only unless `editable`.
/// `fitsContent` grows it with its text (inside a Form) instead of scrolling inside it.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage = .beancount
    var editable = true
    /// bumped to open the find bar
    var find = 0
    var fontSize: CGFloat = 13
    var fitsContent = false
    /// the keyboard is up in it (set to true to bring it up)
    var focused: Binding<Bool>? = nil
    /// read where the view is built, so a new choice in 设置 redraws it in place
    var theme: CodeTheme = .current

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        let h = context.coordinator.highlighter
        h.language = language
        h.theme = theme
        v.textStorage.delegate = h
        v.font = h.font
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.spellCheckingType = .no
        v.keyboardDismissMode = .interactive
        v.isFindInteractionEnabled = true
        if fitsContent {
            v.isScrollEnabled = false
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            v.alwaysBounceVertical = true
            v.textContainerInset = UIEdgeInsets(top: AppSpacing.control, left: 10, bottom: 40, right: 10)
        }
        style(v)
        v.isEditable = editable
        // the shortcut bar while editing only: a read-only view can still be selected, and would show it with no keyboard
        v.inputAccessoryView = editable ? accessory(v) : nil
        v.delegate = context.coordinator
        v.text = text
        return v
    }

    /// the shortcut bar for Beancount and BQL; plain text gets 完成 alone
    private func accessory(_ v: UITextView) -> UIView {
        language == .plain ? Self.doneBar(v) : EditorBar(textView: v, language: language)
    }

    /// 完成 above the keyboard (a UIKit view gets no SwiftUI keyboard toolbar)
    private static func doneBar(_ v: UITextView) -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(title: LS("完成"), primaryAction: UIAction { [weak v] _ in v?.resignFirstResponder() })
        done.style = .done
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        bar.sizeToFit()
        return bar
    }

    /// the theme's background (a rounded block inside a Form), its text colour and, for the dark-only themes,
    /// a dark keyboard and selection
    private func style(_ v: UITextView) {
        v.backgroundColor = theme.background ?? .clear
        v.overrideUserInterfaceStyle = theme.forcesDark ? .dark : .unspecified
        v.typingAttributes = CodeHighlighter.attrs(theme, size: fontSize)
        if fitsContent {
            let pad: CGFloat = theme == .system ? 0 : 8
            v.textContainerInset = UIEdgeInsets(top: 6 + pad / 2, left: pad, bottom: 6 + pad / 2, right: pad)
            v.textContainer.lineFragmentPadding = 0
            v.layer.cornerRadius = pad
        }
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        let h = context.coordinator.highlighter
        if h.theme != theme {
            h.theme = theme
            style(v)
            h.apply(v.textStorage, NSRange(location: 0, length: v.textStorage.length))
            if fitsContent { v.invalidateIntrinsicContentSize() }
        }
        if h.language != language {
            h.language = language
            h.apply(v.textStorage, NSRange(location: 0, length: v.textStorage.length))
        }
        if v.text != text {
            let sel = v.selectedRange
            v.text = text
            if NSMaxRange(sel) <= (text as NSString).length { v.selectedRange = sel }
            if fitsContent { v.invalidateIntrinsicContentSize() }
        }
        if context.coordinator.find != find {
            context.coordinator.find = find
            v.findInteraction?.presentFindNavigator(showingReplace: editable)
        }
        if v.isEditable != editable {
            v.isEditable = editable
            v.inputAccessoryView = editable ? accessory(v) : nil
            if v.isFirstResponder { v.reloadInputViews() }
            if editable && !fitsContent { v.becomeFirstResponder() } else if !editable { v.resignFirstResponder() }
        }
        if let f = focused, f.wrappedValue, editable, !v.isFirstResponder {
            DispatchQueue.main.async { v.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        guard fitsContent, let w = proposal.width, w > 0 else { return nil }
        let s = v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: s.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        var find = 0
        let highlighter: CodeHighlighter
        init(_ p: CodeTextView) {
            parent = p
            highlighter = CodeHighlighter(p.language, size: p.fontSize)
        }
        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            if parent.fitsContent { v.invalidateIntrinsicContentSize() }
        }
        func textViewDidBeginEditing(_ v: UITextView) { if parent.focused?.wrappedValue == false { parent.focused?.wrappedValue = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused?.wrappedValue == true { parent.focused?.wrappedValue = false } }
    }
}

/// 设置 → 外观 → 代码配色: each theme with a short Beancount sample in it
struct CodeThemePicker: View {
    private static let sample = """
    2026-10-14 * "丽娜超市" "日用品" #trip ^doc-1
      Expenses:Shopping                  23.00 CNY @ 1.17912 HKD
      Assets:Bank:HSBC                  -27.12 HKD  ; 账单汇率
    """

    var body: some View {
        List {
            Section {
                ForEach(CodeTheme.allCases) { t in
                    Button { AppSettings.shared.codeTheme = t.rawValue } label: {
                        VStack(alignment: .leading, spacing: AppSpacing.icon) {
                            HStack(spacing: AppSpacing.control) {
                                Label(t.name, systemImage: "paintpalette").labelStyle(ControlLabelStyle()).foregroundStyle(Color.primary)
                                if t.darkOnly { Text(LS("深色")).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if CodeTheme.current == t { Image(systemName: "checkmark").foregroundStyle(Color.jade).fontWeight(.semibold) }
                            }
                            preview(t)
                        }
                        .padding(.vertical, AppSpacing.detail)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(LS("用于交易原文、编辑源文本、源文件和查询。默认跟随系统配色；有浅、深两版的配色随显示模式切换；Dracula、Monokai、Nord 只有深色版。只存在这台手机。"))
            }
        }
        .navigationTitle(LS("代码配色"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func preview(_ t: CodeTheme) -> some View {
        Text(highlighted(Self.sample, .beancount, size: 11, theme: t))
            .font(.system(size: 11, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppSpacing.icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.background.map { Color(uiColor: $0) } ?? Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .environment(\.colorScheme, t.forcesDark ? .dark : colorScheme)
    }
    @Environment(\.colorScheme) private var colorScheme
}
