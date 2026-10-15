import SwiftUI
import UIKit
import LedgerKit

/// The bar above the keyboard in the source editor: shortcuts for what is awkward to type on a phone (dates,
/// flags, @ @@ # ^, quotes, account names, the indent), a new transaction, laying out the entry the cursor is in,
/// and 完成. Every edit goes through the text view, so it can be undone like typing.
final class EditorBar: UIInputView {
    private weak var textView: UITextView?
    private let language: CodeLanguage

    init(textView: UITextView, language: CodeLanguage) {
        self.textView = textView
        self.language = language
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 50) }

    // MARK: layout

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        for item in language == .bql ? bqlItems() : beancountItems() { stack.addArrangedSubview(item) }
        scroll.addSubview(stack)

        var cfg = UIButton.Configuration.plain()
        cfg.title = LS("完成")
        cfg.baseForegroundColor = .tintColor
        cfg.attributedTitle = AttributedString(LS("完成"), attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .semibold)]))
        let done = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in self?.textView?.resignFirstResponder() })

        let line = UIView()
        line.backgroundColor = .separator
        for v in [scroll, done, line] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: line.leadingAnchor, constant: -4),
            line.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            line.heightAnchor.constraint(equalToConstant: 26),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -2),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    /// a key: an SF Symbol over a short caption, or a short text alone
    private func key(_ caption: String, symbol: String? = nil, label: String? = nil, menu: UIMenu? = nil, _ act: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = .label
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
        if let s = symbol {
            cfg.image = UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            cfg.imagePlacement = .top
            cfg.imagePadding = 2
            cfg.attributedTitle = AttributedString(caption, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 10.5)]))
        } else {
            cfg.attributedTitle = AttributedString(caption, attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)]))
        }
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            act()
        })
        if let m = menu { b.menu = m; b.showsMenuAsPrimaryAction = false }
        b.accessibilityLabel = label ?? caption
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: symbol == nil ? 36 : 44).isActive = true
        return b
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    private func beancountItems() -> [UIView] {
        [
            key(LS("日期"), symbol: "calendar", label: LS("插入今天的日期，长按选其他日子"), menu: dateMenu()) { [weak self] in self?.insertWord(Day.today()) },
            key(LS("新交易"), symbol: "plus.rectangle.on.rectangle") { [weak self] in self?.newTransaction() },
            key(LS("账户"), symbol: "creditcard") { [weak self] in self?.pickAccount() },
            divider(),
            key("*", label: LS("标记为已确认（*）")) { [weak self] in self?.flag("*") },
            key("!", label: LS("标记为待确认（!）")) { [weak self] in self?.flag("!") },
            divider(),
            key("@") { [weak self] in self?.insertWord("@") },
            key("@@") { [weak self] in self?.insertWord("@@") },
            key("#") { [weak self] in self?.insertWord("#", spaceAfter: false) },
            key("^") { [weak self] in self?.insertWord("^", spaceAfter: false) },
            key("\"\"", label: LS("引号")) { [weak self] in self?.insertPair("\"") },
            divider(),
            key(LS("缩进"), symbol: "arrow.right.to.line", label: LS("缩进两格")) { [weak self] in self?.insert("  ") },
            key(LS("对齐"), symbol: "text.alignright", label: LS("对齐光标所在的这笔")) { [weak self] in self?.align() },
        ]
    }

    private func bqlItems() -> [UIView] {
        ["SELECT", "FROM", "WHERE", "AND", "GROUP BY", "ORDER BY", "DESC", "LIMIT"].map { w in
            key(w) { [weak self] in self?.insertWord(w) }
        } + [
            divider(),
            key("''", label: LS("引号")) { [weak self] in self?.insertPair("'") },
            key(LS("账户"), symbol: "creditcard") { [weak self] in self?.pickAccount() },
            key(LS("日期"), symbol: "calendar", menu: dateMenu()) { [weak self] in self?.insertWord(Day.today()) },
        ]
    }

    /// long press on 日期: the last week's days
    private func dateMenu() -> UIMenu {
        let today = Day.today()
        let days = (1...6).map { Day.shift(today, -$0) }
        let names = [LS("昨天"), LS("前天")]
        return UIMenu(children: days.enumerated().map { i, d in
            UIAction(title: i < names.count ? "\(names[i])  \(d)" : d) { [weak self] _ in self?.insertWord(d) }
        })
    }

    // MARK: edits

    private var text: String { textView?.text ?? "" }
    private var cursor: Int { textView?.selectedRange.location ?? 0 }

    /// replace `r` with `s` the way typing would (so it can be undone), then put the cursor at `caret`
    private func replace(_ r: NSRange, _ s: String, caret: Int? = nil) {
        guard let tv = textView else { return }
        // a word still being composed (pinyin) would swallow what is put in
        if tv.markedTextRange != nil { tv.unmarkText() }
        guard let a = tv.position(from: tv.beginningOfDocument, offset: r.location),
              let b = tv.position(from: a, offset: r.length),
              let range = tv.textRange(from: a, to: b) else { return }
        tv.replace(range, withText: s)
        if let c = caret { tv.selectedRange = NSRange(location: c, length: 0) }
        tv.delegate?.textViewDidChange?(tv)
    }

    private func insert(_ s: String, caretAt offset: Int? = nil) {
        guard let tv = textView else { return }
        if tv.markedTextRange != nil { tv.unmarkText() }
        let r = tv.selectedRange
        replace(r, s, caret: r.location + (offset ?? (s as NSString).length))
    }

    /// a word set apart from what is before it by a space (and after it, unless it starts a tag or link)
    private func insertWord(_ w: String, spaceAfter: Bool = true) {
        let ns = text as NSString, c = cursor
        let before = c > 0 ? ns.substring(with: NSRange(location: c - 1, length: 1)) : "\n"
        let lead = before == " " || before == "\n" || before == "\t" ? "" : " "
        insert(lead + w + (spaceAfter ? " " : ""))
    }

    /// a pair of quotes, the cursor between them (around the selection, if there is one)
    private func insertPair(_ q: String) {
        guard let tv = textView else { return }
        let r = tv.selectedRange
        let inner = (text as NSString).substring(with: r)
        replace(r, q + inner + q, caret: r.location + 1 + (inner as NSString).length)
    }

    /// in a transaction: its flag set to `f`; elsewhere the character itself
    private func flag(_ f: String) {
        if let t = toggledFlag(text, at: cursor) {
            let current = (text as NSString).substring(with: t.range)
            if current != f { let c = cursor; replace(t.range, f, caret: c) }
        } else {
            insertWord(f)
        }
    }

    private func align() {
        guard let a = alignedEntry(text, at: cursor) else { return }
        replace(a.range, a.with, caret: a.range.location + (a.with as NSString).length - (a.with.hasSuffix("\n") ? 1 : 0))
    }

    /// a new transaction after the entry the cursor is in (a blank line between), the cursor in its payee
    private func newTransaction() {
        let ns = text as NSString
        let t = transactionTemplate(date: Day.today())
        var at = cursor
        var lead = ""
        if let e = entryRange(text, at: cursor) {
            at = NSMaxRange(e)
            lead = ns.substring(to: at).hasSuffix("\n") ? "\n" : "\n\n"
        } else if at > 0 && !ns.substring(to: at).hasSuffix("\n") {
            lead = "\n"
        }
        replace(NSRange(location: at, length: 0), lead + t.text, caret: at + (lead as NSString).length + t.cursor)
    }

    /// the account picker, then its name where the cursor was
    private func pickAccount() {
        guard let tv = textView, var top = tv.window?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let saved = tv.selectedRange
        let picker = AccountPicker(title: LS("插入账户"), prefixes: ["Assets:", "Liabilities:", "Equity:", "Income:", "Expenses:"]) { [weak self, weak tv] a in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let self = self, let tv = tv else { return }
                tv.becomeFirstResponder()
                tv.selectedRange = saved
                self.insertWord(a)
            }
        }
        let host = UIHostingController(rootView: picker
            .environmentObject(Store.shared)
            .tint(AppTheme.current.color)
            .environment(\.locale, AppLanguage.current.locale))
        top.present(host, animated: true)
    }
}
