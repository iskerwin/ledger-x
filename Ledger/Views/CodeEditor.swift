import SwiftUI
import UIKit
import LedgerKit

// Source text in colour: Beancount (entries, files) and BQL (queries). LedgerKit says what each piece is
// (codeSpans); this only picks the colours, which follow light and dark mode. The text is never changed.

/// the colour of each kind of piece
func codeColor(_ k: CodeToken) -> UIColor {
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

/// `text` in colour, for SwiftUI Text (read-only places)
func highlighted(_ text: String, _ lang: CodeLanguage, size: CGFloat = 12) -> AttributedString {
    var out = AttributedString(text)
    guard lang != .plain else { return out }
    for s in codeSpans(text, lang) {
        guard let r = Range(NSRange(location: s.location, length: s.length), in: text),
              let a = Range(r, in: out) else { continue }
        out[a].foregroundColor = Color(uiColor: codeColor(s.kind))
        if s.kind == .number || s.kind == .flag { out[a].font = .system(size: size, weight: .semibold, design: .monospaced) }
    }
    return out
}

/// colours a text view's text as it changes: only the lines an edit touched, so long files stay quick to type in
final class CodeHighlighter: NSObject, NSTextStorageDelegate {
    var language: CodeLanguage
    var font: UIFont
    var bold: UIFont
    init(_ language: CodeLanguage, size: CGFloat) {
        self.language = language
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        bold = .monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    var base: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: UIColor.label] }

    func apply(_ ts: NSTextStorage, _ range: NSRange) {
        guard ts.length > 0 else { return }
        let lines = (ts.string as NSString).lineRange(for: NSRange(location: min(range.location, ts.length), length: min(range.length, ts.length - min(range.location, ts.length))))
        ts.setAttributes(base, range: lines)
        for s in codeSpans(ts.string, language, in: lines) {
            let r = NSRange(location: s.location, length: s.length)
            guard NSMaxRange(r) <= ts.length else { continue }
            ts.addAttribute(.foregroundColor, value: codeColor(s.kind), range: r)
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

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        let h = context.coordinator.highlighter
        h.language = language
        v.textStorage.delegate = h
        v.font = h.font
        v.typingAttributes = h.base
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.spellCheckingType = .no
        v.keyboardDismissMode = .interactive
        v.isFindInteractionEnabled = true
        v.backgroundColor = .clear
        if fitsContent {
            v.isScrollEnabled = false
            v.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            v.textContainer.lineFragmentPadding = 0
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            v.alwaysBounceVertical = true
            v.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
        }
        v.isEditable = editable
        v.inputAccessoryView = Self.doneBar(v)
        v.delegate = context.coordinator
        v.text = text
        return v
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

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        let h = context.coordinator.highlighter
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
