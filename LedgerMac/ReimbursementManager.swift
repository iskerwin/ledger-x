import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import LedgerKit

/// which reimbursement is paid back: the advances waiting (nil) or a ^reimburse-… link still owed
struct PayTarget: Identifiable {
    let link: String?
    var id: String { link ?? "" }
}

/// 登记回款, as the phone's: pick the advances paid back (one currency at a time), or settle what a link still owes; what
/// came back goes into an account, and a difference either way is 报销差额 or stays on the link to be paid later
struct ReimbursementPaySheet: View {
    let ledger: Ledger
    let folder: URL
    let link: String?
    private let derived: Derived
    @State private var date = Day.today()
    @State private var payee: String
    @State private var amount = ""
    @State private var account: String
    @State private var linkText = ""
    @State private var linkTouched = false
    @State private var currency: String
    @State private var picked: Set<ObjectIdentifier>
    @State private var keepOpen = false
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @State private var exporting: ReimbExportTarget?
    @Environment(\.dismiss) private var dismiss

    init(ledger: Ledger, config: LedgerXConfig?, folder: URL, link: String?) {
        self.ledger = ledger
        self.folder = folder
        self.link = link
        let derived = folderDerived(ledger, config: config)
        self.derived = derived
        let currencies = Set(derived.unclaimed.map(\.currency))
        let currency = currencies.contains(ledger.base) ? ledger.base : currencies.sorted().first ?? ledger.base
        _currency = State(initialValue: currency)
        _picked = State(initialValue: Set(derived.unclaimed.filter { $0.currency == currency }.map { ObjectIdentifier($0.t) }))
        let past = ledger.txns.filter { $0.tags.contains("reimbursement") }
        _payee = State(initialValue: past.last { !$0.payee.isEmpty }?.payee ?? "")
        let boost = past.suffix(10).reversed().flatMap { t in t.postings.filter { ($0.units ?? 0) > 0 }.map(\.account) }
        _account = State(initialValue: derived.rankAccounts(["Assets:"], boost: boost).first { !$0.hasPrefix("Assets:Receivable") } ?? "")
    }

    private var writer: FolderWriter { FolderWriter(folder: folder, busy: $busy, message: $message, review: $review) }
    private var open: OpenLink? { link.flatMap { l in derived.openLinks.first { $0.link == l } } }
    private var currencies: [String] { Array(Set(derived.unclaimed.map(\.currency))).sorted() }
    private var pool: [Unclaimed] { link == nil ? derived.unclaimed.filter { $0.currency == currency } : [] }
    private var chosen: [Unclaimed] { pool.filter { picked.contains(ObjectIdentifier($0.t)) } }
    private var owed: Double { open?.amount ?? reimbursementTotal(chosen, currency: currency) ?? 0 }

    private var linkValue: String {
        if let link { return link }
        if linkTouched { return linkText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^", with: "") }
        let who = payee.trimmingCharacters(in: .whitespaces)
        return newLink("reimburse", payee: who.isEmpty ? "work" : who, date: date, taken: Set(derived.allLinks))
    }

    private var payment: ReimbursementPayment? {
        let typed = amount.trimmingCharacters(in: .whitespaces)
        guard let got = typed.isEmpty ? owed : evalAmount(typed) else { return nil }
        return ReimbursementPayment(date: date, payee: payee, account: account, link: linkValue, owed: owed, got: got,
                                    currency: open?.currency ?? currency, receivable: derived.receivable, keepOpen: keepOpen)
    }

    var body: some View {
        let text = payment?.text ?? ""
        VStack(spacing: 0) {
            HStack {
                Text(LS("报销回款")).font(.headline)
                Spacer()
                Button(LS("导出报销单…")) {
                    let entries = link.map { derived.byLink[$0] ?? [] } ?? chosen.map(\.t)
                    exporting = ReimbExportTarget(title: link.map { "^" + $0 } ?? LS("待报销 %@", Day.today()), entries: entries.filter { !$0.synthetic })
                }
                .disabled(link == nil && chosen.isEmpty)
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(LS("登记回款")) {
                    guard let payment else { return }
                    writer.prepare(.pay(payment, advances: link == nil ? chosen.map(\.t) : []), step: LS("报销回款")) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || text.isEmpty)
            }
            .padding(16)
            Form {
                if let open {
                    LabeledContent("^" + open.link) { Text(LS("应收 ") + money(open.amount, open.currency)).monospacedDigit() }
                } else if link == nil {
                    advances
                }
                Section(LS("回款信息")) {
                    DateRow(title: LS("回款日期"), day: $date)
                    if link == nil {
                        TextField(LS("关联"), text: Binding(get: { linkValue }, set: { linkText = $0; linkTouched = true }))
                    }
                    TextField(LS("付款方"), text: $payee)
                    TextField(LS("回款金额 ") + (open?.currency ?? currency), text: $amount, prompt: Text(fmtNum(owed)))
                        .monospacedDigit()
                    AccountField(title: LS("收款账户"), prefixes: ["Assets:"], derived: derived, account: $account, excluding: "Assets:Receivable")
                    difference
                }
                if !text.isEmpty {
                    DisclosureGroup(LS("将写入")) {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(busy)
            Text(message)
                .font(.callout).foregroundStyle(Color.loss).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 16)
        }
        .frame(width: 560, height: 640)
        .interactiveDismissDisabled(busy)
        .folderReview(writer, $review, step: LS("报销回款")) { dismiss() }
        .sheet(item: $exporting) { ReimbExportSheet(target: $0, ledger: ledger, derived: derived, folder: folder) }
    }

    /// the advances waiting in one currency, each picked or not
    @ViewBuilder private var advances: some View {
        Section {
            if currencies.count > 1 {
                Picker(LS("回款币种"), selection: Binding(get: { currency }, set: { value in
                    currency = value
                    picked = Set(derived.unclaimed.filter { $0.currency == value }.map { ObjectIdentifier($0.t) })
                    amount = ""
                })) { ForEach(currencies, id: \.self) { Text($0).tag($0) } }
            }
            ForEach(pool, id: \.t.key) { item in
                Toggle(isOn: Binding(get: { picked.contains(ObjectIdentifier(item.t)) }, set: { on in
                    if on { picked.insert(ObjectIdentifier(item.t)) } else { picked.remove(ObjectIdentifier(item.t)) }
                })) {
                    HStack {
                        Text(item.t.date).monospacedDigit().foregroundStyle(.secondary)
                        Text([item.t.payee, item.t.narration].filter { !$0.isEmpty }.joined(separator: " ")).lineLimit(1)
                        Spacer()
                        Text(money(item.amount, item.currency)).monospacedDigit()
                    }
                }
            }
        } header: {
            HStack {
                Text(LS("已选 %@/%@ 笔，合计 ", chosen.count, pool.count) + money(owed, currency))
                Spacer()
                Button(chosen.count == pool.count ? LS("全不选") : LS("全选")) {
                    picked = chosen.count == pool.count ? [] : Set(pool.map { ObjectIdentifier($0.t) })
                }
                .buttonStyle(.link)
            }
        }
    }

    /// more or less than was advanced: where the difference goes
    @ViewBuilder private var difference: some View {
        if let p = payment, p.got > 0, abs(p.got - p.owed) > 0.004 {
            let diff = p.got - p.owed
            if diff < 0 { Toggle(LS("差额以后还会补（挂账）"), isOn: $keepOpen) }
            Text(diff > 0 ? LS("超额 %@，计入 Income:ReimbExcess", money(diff, p.currency))
                 : keepOpen ? LS("短收 %@，留在 ^%@ 上待收，补发后再登记回款", money(-diff, p.currency), p.link)
                 : LS("短收 %@，计入 %@", money(-diff, p.currency), ReimbursementPayment.difference))
                .foregroundStyle(diff < 0 && !keepOpen ? Color.loss : Color.secondary)
        }
    }
}

/// 支出类型 and 凭证类型 of an advance, as the phone's 类型 and 凭证: what the company files it under, and the paper behind it
struct AdvanceFieldsSheet: View {
    let entry: Entry
    let folder: URL
    private let derived: Derived
    private let was: (category: String, voucher: String)
    @State private var category: String
    @State private var voucher: String
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    init(entry: Entry, ledger: Ledger, config: LedgerXConfig?, folder: URL) {
        self.entry = entry
        self.folder = folder
        let derived = folderDerived(ledger, config: config)
        self.derived = derived
        let line = entry.postings.first { $0.account == derived.receivable && ($0.units ?? 0) > 0 }
        let category = line.flatMap(advanceCategory) ?? ""
        let voucher = line?.meta[voucherMeta].map { $0.stringValue ?? $0.display } ?? ""
        was = (category, voucher)
        _category = State(initialValue: category)
        _voucher = State(initialValue: voucher)
    }

    private var writer: FolderWriter { FolderWriter(folder: folder, busy: $busy, message: $message, review: $review) }
    private var step: String { LS("支出类型与凭证") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text([entry.date, entry.payee].filter { !$0.isEmpty }.joined(separator: " ")).font(.headline).lineLimit(1)
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(LS("保存")) {
                    writer.prepare(.fields(entry, category: category.isEmpty ? nil : category, voucher: voucher.isEmpty ? nil : voucher), step: step) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || (category == was.category && voucher == was.voucher))
            }
            .padding(16)
            Form {
                AccountField(title: LS("支出类型"), prefixes: ["Expenses:"], derived: derived, account: $category)
                Picker(LS("凭证类型"), selection: $voucher) {
                    Text(LS("未填")).tag("")
                    if !voucher.isEmpty && !voucherKinds.contains(voucher) { Text(voucher).tag(voucher) }
                    ForEach(voucherKinds, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .disabled(busy)
            Text(message)
                .font(.callout).foregroundStyle(Color.loss).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 16)
        }
        .frame(width: 460, height: 260)
        .folderReview(writer, $review, step: step) { dismiss() }
    }
}

/// what to put on a 报销单: a reimbursement's or petty cash's transactions, or the advances picked
struct ReimbExportTarget: Identifiable {
    let id = UUID()
    let title: String
    let entries: [Entry]
}

/// 导出报销单, as the phone's: a PDF (the list, then every attached receipt), and the xlsx and CSV beside it where you
/// save it
struct ReimbExportSheet: View {
    let target: ReimbExportTarget
    let ledger: Ledger
    let derived: Derived
    let folder: URL
    @State private var withDocs = true
    @State private var withXLSX = true
    @State private var withCSV = true
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    private var report: ReimbReport { reimbReport(target.entries, ledger, receivable: derived.receivable, title: target.title) }

    /// a transaction's own attachments, where they are in the folder
    private func receipts(_ entry: Entry) -> [String] {
        documentItems(ledger).filter { $0.transaction === entry }.compactMap(\.path)
    }

    var body: some View {
        let r = report
        let docs = r.lines.reduce(0) { $0 + receipts($1.entry).count }
        VStack(spacing: 0) {
            HStack {
                Text(LS("导出报销单")).font(.headline)
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LS("导出…")) { export(r) }.keyboardShortcut(.defaultAction).disabled(r.lines.isEmpty)
            }
            .padding(16)
            Form {
                Section {
                    LabeledContent(LS("名称"), value: r.title)
                    if !r.payer.isEmpty { LabeledContent(LS("报销单位"), value: r.payer) }
                    if !r.lines.isEmpty { LabeledContent(LS("期间"), value: r.from == r.to ? r.from : r.from + " – " + r.to) }
                    LabeledContent(LS("笔数"), value: LS("%@ 笔", r.lines.count))
                    ForEach(r.totals.indices, id: \.self) { i in LabeledContent(LS("合计"), value: money(r.totals[i].amount, r.totals[i].currency)) }
                }
                Section {
                    Toggle(LS("附上附件（%@ 个）", docs), isOn: $withDocs).disabled(docs == 0)
                    Toggle(LS("报销模板表格（xlsx，含数据透视）"), isOn: $withXLSX)
                    Toggle(LS("同时导出 CSV 表格"), isOn: $withCSV)
                }
            }
            .formStyle(.grouped)
            Text(message)
                .font(.callout).foregroundStyle(Color.loss).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 16)
        }
        .frame(width: 460, height: 420)
    }

    /// asks where, then writes the PDF there and the tables beside it, and shows them in the Finder
    private func export(_ r: ReimbReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = reimbFileName(r.title) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = url.deletingPathExtension()
        var missing: [String] = []
        var files: [ReimbReceipt] = []
        if withDocs {
            var seen = Set<String>()
            for line in r.lines {
                for path in receipts(line.entry) where seen.insert(path).inserted {
                    if let data = try? Data(contentsOf: folder.appendingPathComponent(path)) {
                        files.append(ReimbReceipt(path: path, data: data, caption: "\(line.date)  \(line.payee)  \(money(line.amount, line.currency))"))
                    } else {
                        missing.append((path as NSString).lastPathComponent)
                    }
                }
            }
        }
        var written: [URL] = []
        do {
            try MacReimbPDF(report: r, receipts: files, docCount: { receipts($0).count }).render().write(to: url)
            written.append(url)
            if withXLSX {
                let x = base.appendingPathExtension("xlsx")
                try reimbXLSX(r).write(to: x)
                written.append(x)
            }
            if withCSV {
                let c = base.appendingPathExtension("csv")
                try Data(reimbCSV(r, docs: { receipts($0).map { ($0 as NSString).lastPathComponent } }).utf8).write(to: c)
                written.append(c)
            }
        } catch {
            message = error.localizedDescription
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(written)
        if missing.isEmpty { dismiss() } else { message = LS("以下附件下载失败，未并入") + "：" + missing.joined(separator: "、") }
    }
}

struct ReimbReceipt {
    let path: String
    let data: Data
    let caption: String
}

/// the 报销单 on A4, as the phone draws it: the list with totals and a place to sign, then the receipts, a page each.
/// Drawn on a flipped context so it reads top down as UIKit's does
struct MacReimbPDF {
    let report: ReimbReport
    let receipts: [ReimbReceipt]
    let docCount: (Entry) -> Int

    private let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private let margin: CGFloat = 40
    private var width: CGFloat { page.width - margin * 2 }
    /// column widths: No., date, merchant, description, paid with, amount, attachments
    private var cols: [CGFloat] { [24, 62, 104, width - 24 - 62 - 104 - 78 - 72 - 34, 78, 72, 34] }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    private func attrs(_ f: NSFont, _ color: NSColor = .black, align: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        return [.font: f, .foregroundColor: color, .paragraphStyle: p]
    }

    private func height(_ s: String, _ a: [NSAttributedString.Key: Any], _ w: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: a).height)
    }

    private func fill(_ rect: CGRect, _ white: CGFloat, _ cg: CGContext) {
        cg.setFillColor(NSColor(white: white, alpha: 1).cgColor)
        cg.fill(rect)
    }

    func render() -> Data {
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: report.title, kCGPDFContextCreator: "Ledger X"] as CFDictionary)
        else { return Data() }
        let saved = NSGraphicsContext.current
        defer { NSGraphicsContext.current = saved }
        var pageNo = 0
        func newPage() -> CGFloat {
            if pageNo > 0 { cg.endPDFPage() }
            cg.beginPDFPage(nil)
            cg.translateBy(x: 0, y: page.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            pageNo += 1
            (LS("第 %@ 页", pageNo) as NSString).draw(in: CGRect(x: margin, y: page.height - 28, width: width, height: 14), withAttributes: attrs(font(8), .gray, align: .center))
            return margin
        }
        var y = newPage()

        // heading
        (LS("报销单") as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 26), withAttributes: attrs(font(18, .bold), align: .center))
        y += 30
        var info: [String] = [report.title]
        if !report.payer.isEmpty { info.append(LS("报销单位：%@", report.payer)) }
        if !report.lines.isEmpty { info.append(LS("期间：%@", report.from == report.to ? report.from : report.from + " – " + report.to)) }
        info.append(LS("笔数：%@　合计：%@", report.lines.count, report.totals.map { money($0.amount, $0.currency) }.joined(separator: " + ")))
        for s in info {
            let a = attrs(font(10), .darkGray)
            let h = height(s, a, width)
            (s as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: h), withAttributes: a)
            y += h + 2
        }
        y += 8

        // the list
        func row(_ cells: [String], bold: Bool, shade: Bool) {
            let a = attrs(font(8.5, bold ? .semibold : .regular))
            let ar = attrs(font(8.5, bold ? .semibold : .regular), align: .right)
            let inner = cells.enumerated().map { height($0.element, $0.offset == 5 ? ar : a, cols[$0.offset] - 6) }.max() ?? 0
            let h = max(16, inner + 6)
            if y + h > page.height - 50 { y = newPage() }
            if shade { fill(CGRect(x: margin, y: y, width: width, height: h), 0.94, cg) }
            var x = margin
            for (i, c) in cells.enumerated() {
                (c as NSString).draw(in: CGRect(x: x + 3, y: y + 3, width: cols[i] - 6, height: h - 6), withAttributes: i == 5 ? ar : a)
                x += cols[i]
            }
            fill(CGRect(x: margin, y: y + h - 0.5, width: width, height: 0.5), 0.8, cg)
            y += h
        }
        row([LS("序号"), LS("日期"), LS("商户"), LS("说明"), LS("付款方式"), LS("金额"), LS("附件")], bold: true, shade: true)
        for (i, l) in report.lines.enumerated() {
            let n = docCount(l.entry)
            row([String(i + 1), l.date, l.payee, l.narration, l.method, money(l.amount, l.currency), n > 0 ? String(n) : LS("无")], bold: false, shade: false)
        }
        for t in report.totals {
            row(["", "", "", LS("合计"), "", money(t.amount, t.currency), ""], bold: true, shade: true)
        }

        // a place to sign
        y += 28
        if y > page.height - 80 { y = newPage() }
        (LS("报销人：＿＿＿＿＿＿　　审核：＿＿＿＿＿＿　　日期：＿＿＿＿＿＿") as NSString)
            .draw(in: CGRect(x: margin, y: y, width: width, height: 16), withAttributes: attrs(font(10)))

        // the receipts
        for (k, f) in receipts.enumerated() {
            let caption = LS("附件 %@：%@", k + 1, f.caption)
            let name = (f.path as NSString).lastPathComponent
            let box = { (top: CGFloat) -> CGRect in CGRect(x: margin, y: top, width: width, height: page.height - top - 50) }
            if f.path.lowercased().hasSuffix(".pdf"), let provider = CGDataProvider(data: f.data as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0 {
                for n in 1...doc.numberOfPages {
                    guard let p = doc.page(at: n) else { continue }
                    let top = newPage()
                    let c = n == 1 ? caption + "　" + name : caption + LS("（第 %@ 页）", n)
                    (c as NSString).draw(in: CGRect(x: margin, y: top, width: width, height: 14), withAttributes: attrs(font(9), .darkGray))
                    drawPDFPage(p, in: box(top + 20), cg)
                }
            } else if let img = uprightImage(f.data) {
                let top = newPage()
                ((caption + "　" + name) as NSString).draw(in: CGRect(x: margin, y: top, width: width, height: 14), withAttributes: attrs(font(9), .darkGray))
                let b = box(top + 20)
                let size = CGSize(width: img.width, height: img.height)
                let s = min(b.width / size.width, b.height / size.height, 1.5)
                let r = CGRect(x: b.midX - size.width * s / 2, y: b.minY, width: size.width * s, height: size.height * s)
                // an image is drawn with y up: turned back over inside its own box
                cg.saveGState()
                cg.translateBy(x: r.minX, y: r.maxY)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(img, in: CGRect(origin: .zero, size: r.size))
                cg.restoreGState()
            } else {
                let top = newPage()
                (LS("%@：%@ 不是图片或 PDF，未能并入", caption, name) as NSString).draw(in: CGRect(x: margin, y: top, width: width, height: 40), withAttributes: attrs(font(10)))
            }
        }
        cg.endPDFPage()
        cg.closePDF()
        return data as Data
    }

    /// a photo turned the way it was taken (its EXIF orientation applied), as UIImage shows it on the phone
    private func uprightImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// a page of another PDF, scaled to fit `rect` (PDF pages are drawn with y up)
    private func drawPDFPage(_ p: CGPDFPage, in rect: CGRect, _ cg: CGContext) {
        let b = p.getBoxRect(.cropBox)
        guard b.width > 0, b.height > 0 else { return }
        let s = min(rect.width / b.width, rect.height / b.height)
        cg.saveGState()
        cg.translateBy(x: rect.midX - b.width * s / 2, y: rect.minY + b.height * s)
        cg.scaleBy(x: s, y: -s)
        cg.translateBy(x: -b.minX, y: -b.minY)
        cg.drawPDFPage(p)
        cg.restoreGState()
    }
}
