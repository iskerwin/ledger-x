import SwiftUI
import UIKit
import LedgerKit

/// The bar above the keyboard in the source editor: shortcuts for what is awkward to type on a phone (dates,
/// flags, @ @@ # ^, quotes, account names, the indent), a new transaction, laying out the entry the cursor is in,
/// and 完成. Every edit goes through the text view, so it can be undone like typing.
final class EditorBar: UIView {
    private weak var textView: UITextView?
    private let language: CodeLanguage
    private static let barHeight: CGFloat = 44
    private static let margin: CGFloat = AppSpacing.icon

    init(textView: UITextView, language: CodeLanguage) {
        self.textView = textView
        self.language = language
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.barHeight + 2 * Self.margin))
        autoresizingMask = .flexibleHeight
        backgroundColor = .clear
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight + 2 * Self.margin) }

    // MARK: layout
    //
    // A rounded glass bar floating above the keyboard, like the system's own (Notes, Mail), with 完成 as a round
    // button of its own beside it. Glass where the system has it (iOS 26), a thick blur before.

    private static func glass() -> UIVisualEffectView {
        let v: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect()
            g.isInteractive = true
            // a little of the page's colour, so what scrolls behind stays faint under the keys
            g.tintColor = UIColor.systemBackground.withAlphaComponent(0.55)
            v = UIVisualEffectView(effect: g)
        } else {
            v = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            v.layer.borderWidth = 1 / UIScreen.main.scale
            v.layer.borderColor = UIColor.separator.cgColor
        }
        v.layer.cornerRadius = barHeight / 2
        v.layer.cornerCurve = .continuous
        v.clipsToBounds = true
        return v
    }

    private func build() {
        let bar = Self.glass()
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = AppSpacing.detail
        stack.alignment = .center
        for item in language == .bql ? bqlItems() : beancountItems() { stack.addArrangedSubview(item) }
        scroll.addSubview(stack)
        bar.contentView.addSubview(scroll)

        let doneBack = Self.glass()
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        cfg.baseForegroundColor = .tintColor
        let done = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in self?.textView?.resignFirstResponder() })
        done.accessibilityLabel = LS("完成")
        doneBack.contentView.addSubview(done)

        for v in [bar, doneBack, scroll, stack, done] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar)
        addSubview(doneBack)
        let m = Self.margin, h = Self.barHeight
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: m),
            bar.heightAnchor.constraint(equalToConstant: h),
            bar.trailingAnchor.constraint(equalTo: doneBack.leadingAnchor, constant: -8),
            doneBack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            doneBack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            doneBack.widthAnchor.constraint(equalToConstant: h),
            doneBack.heightAnchor.constraint(equalToConstant: h),
            done.leadingAnchor.constraint(equalTo: doneBack.contentView.leadingAnchor),
            done.trailingAnchor.constraint(equalTo: doneBack.contentView.trailingAnchor),
            done.topAnchor.constraint(equalTo: doneBack.contentView.topAnchor),
            done.bottomAnchor.constraint(equalTo: doneBack.contentView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    /// a key: an SF Symbol, or a short text (a symbol or a BQL word). Its name shows on a long press (unless the
    /// long press has a menu of its own), and is what VoiceOver reads.
    private func key(_ caption: String, symbol: String? = nil, label: String? = nil, menu: UIMenu? = nil, menuOnTap: Bool = false, _ act: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = .label
        cfg.imagePadding = AppSpacing.icon
        if let s = symbol {
            cfg.image = UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            cfg.contentInsets = NSDirectionalEdgeInsets(top: AppSpacing.detail, leading: AppSpacing.icon, bottom: AppSpacing.detail, trailing: AppSpacing.icon)
        } else {
            let word = caption.count > 2
            if word { cfg.image = UIImage(systemName: "text.cursor") }
            cfg.attributedTitle = AttributedString(caption, attributes: AttributeContainer([
                .font: word ? UIFont.systemFont(ofSize: 15, weight: .medium) : UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)]))
            cfg.contentInsets = NSDirectionalEdgeInsets(top: AppSpacing.detail, leading: AppSpacing.icon, bottom: AppSpacing.detail, trailing: AppSpacing.icon)
        }
        let name = label ?? caption
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in
            Haptics.selection()
            act()
        })
        if let m = menu {
            b.menu = m; b.showsMenuAsPrimaryAction = menuOnTap
        } else {
            // long press: what the key does, and doing it from there
            b.menu = UIMenu(children: [UIAction(title: name, image: UIImage(systemName: symbol ?? "text.cursor")) { _ in act() }])
        }
        b.accessibilityLabel = name
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: symbol == nil && caption.count <= 2 ? 38 : 42).isActive = true
        return b
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let pad = UIView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(v)
        NSLayoutConstraint.activate([
            pad.widthAnchor.constraint(equalToConstant: 9), pad.heightAnchor.constraint(equalToConstant: 18),
            v.centerXAnchor.constraint(equalTo: pad.centerXAnchor), v.centerYAnchor.constraint(equalTo: pad.centerYAnchor),
        ])
        return pad
    }

    private func beancountItems() -> [UIView] {
        [
            key(LS("日期"), symbol: "calendar", label: LS("插入今天的日期，长按选其他日子"), menu: dateMenu()) { [weak self] in self?.insertWord(Day.today()) },
            key(LS("新交易"), symbol: "plus.rectangle.on.rectangle", label: LS("新交易：空白或常用交易"), menu: newMenu(), menuOnTap: true) {},
            key(LS("账户"), symbol: "creditcard") { [weak self] in self?.pickAccount() },
            divider(),
            key("*", label: LS("标记为已确认（*）")) { [weak self] in self?.flag("*") },
            key("!", label: LS("标记为待确认（!）")) { [weak self] in self?.flag("!") },
            divider(),
            key("@", label: LS("价格（@）")) { [weak self] in self?.insertWord("@") },
            key("@@", label: LS("总价（@@）")) { [weak self] in self?.insertWord("@@") },
            key("#", label: LS("标签（#）")) { [weak self] in self?.insertWord("#", spaceAfter: false) },
            key("^", label: LS("链接（^）")) { [weak self] in self?.insertWord("^", spaceAfter: false) },
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

    /// 新交易: a blank one, or one of the frequent entries filled in (dated today)
    private func newMenu() -> UIMenu {
        var items: [UIMenuElement] = [
            UIAction(title: LS("空白交易"), image: UIImage(systemName: "doc")) { [weak self] _ in self?.newTransaction(nil) },
        ]
        let list = Array(Store.shared.templateList.prefix(12))
        if !list.isEmpty {
            items.append(UIMenu(title: LS("常用交易"), options: .displayInline, children: list.map { x in
                UIAction(title: x.label + (x.fixed.map { "  " + money($0, x.currency) } ?? ""),
                         subtitle: x.payee.isEmpty || x.narration.isEmpty ? nil : x.narration,
                         image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.newTransaction(x) }
            }))
        }
        return UIMenu(children: items)
    }

    /// long press on 日期: the last week's days
    private func dateMenu() -> UIMenu {
        let today = Day.today()
        let days = (1...6).map { Day.shift(today, -$0) }
        let names = [LS("昨天"), LS("前天")]
        return UIMenu(children: days.enumerated().map { i, d in
            UIAction(title: i < names.count ? "\(names[i])  \(d)" : d, image: UIImage(systemName: "calendar")) { [weak self] _ in self?.insertWord(d) }
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

    /// a frequent entry as text, dated today (its usual amount when it has no fixed one); the cursor goes after
    /// the first posting's amount, to change it
    private func templateText(_ x: Template) -> (text: String, cursor: Int)? {
        let store = Store.shared
        guard let L = store.L, let D = store.D else { return nil }
        var d = store.newDraftFor(x.kind == .income ? .income : .expense)
        d.date = Day.today()
        d.payee = x.payee; d.narration = x.narration; d.account = x.account; d.funding = x.funding; d.currency = x.currency
        guard let a = x.fixed ?? x.amounts.last, a > 0 else { return nil }
        d.amount = jsNumberString(a)
        let t = draftText(d, L, D, explicit: true)
        guard !t.isEmpty else { return nil }
        let lines = t.components(separatedBy: "\n")
        let cursor = lines.count > 1 ? (lines[0] as NSString).length + 1 + (lines[1] as NSString).length : (t as NSString).length
        return (t + "\n", cursor)
    }

    /// a new transaction after the entry the cursor is in (a blank line between): blank (the cursor in its payee)
    /// or a frequent entry's
    private func newTransaction(_ x: Template?) {
        let ns = text as NSString
        let t = x.flatMap(templateText) ?? transactionTemplate(date: Day.today())
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
