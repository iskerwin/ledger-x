import SwiftUI
import UIKit
import LedgerKit

/// what to put on a 报销单: the transactions of a reimbursement, petty cash, a selection or an event
struct ReimbExportTarget: Identifiable {
    let id = UUID()
    let title: String
    let entries: [Entry]
}

/// 导出报销单: a PDF (the list, then every attached receipt) and a CSV, handed to the share sheet
struct ReimbExportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: ReimbExportTarget
    @State private var withDocs = true
    @State private var withCSV = true
    @State private var withXLSX = true
    @State private var working = false
    @State private var progress = ""
    @State private var files: [URL] = []
    @State private var failed: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(report(L, D)) } else { ProgressView() }
            }
            .navigationTitle(LS("导出报销单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("关闭"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
        }
    }

    private func report(_ L: Ledger, _ D: Derived) -> ReimbReport {
        reimbReport(target.entries, L, receivable: D.receivable, title: target.title)
    }

    private func form(_ r: ReimbReport) -> some View {
        let docs = r.lines.reduce(0) { $0 + store.receiptPaths(for: $1.entry).count }
        let missing = r.lines.filter { store.receiptPaths(for: $0.entry).isEmpty }.count
        return Form {
            Section {
                LabeledContent(LS("名称"), value: r.title)
                if !r.payer.isEmpty { LabeledContent(LS("报销单位"), value: r.payer) }
                if !r.lines.isEmpty { LabeledContent(LS("期间"), value: r.from == r.to ? r.from : r.from + " – " + r.to) }
                LabeledContent(LS("笔数"), value: LS("%@ 笔", r.lines.count))
                ForEach(r.totals.indices, id: \.self) { i in LabeledContent(LS("合计")) { Amount(n: r.totals[i].amount, c: r.totals[i].currency) } }
            } footer: {
                if r.lines.isEmpty { Text(LS("这里没有报销垫付（记在报销应收、金额为正的交易）。")) }
            }
            Section {
                Toggle(LS("附上附件（%@ 个）", docs), isOn: $withDocs).tint(.jade).disabled(docs == 0)
                Toggle(LS("报销模板表格（xlsx，含数据透视）"), isOn: $withXLSX).tint(.jade)
                Toggle(LS("同时导出 CSV 表格"), isOn: $withCSV).tint(.jade)
            } footer: {
                Text(missing > 0 ? LS("PDF 第一页是明细表，之后按顺序附上每笔的附件（图片一页一张，PDF 原样并入）；有 %@ 笔没有附件，表中标「无」。附件要从仓库下载，需要联网。", missing)
                     : LS("PDF 第一页是明细表，之后按顺序附上每笔的附件（图片一页一张，PDF 原样并入）。附件要从仓库下载，需要联网。"))
            }
            if !failed.isEmpty {
                Section {
                    ForEach(failed, id: \.self) { Text($0).font(.footnote) }
                } header: {
                    Text(LS("以下附件下载失败，未并入"))
                }
            }
            Section {
                // the same shape as 记一笔: icon and text centred between flexible spacers, the row itself borderless
                if files.isEmpty {
                    Button {
                        Task { await make(r) }
                    } label: {
                        HStack(spacing: AppSpacing.icon) {
                            Spacer(minLength: 0)
                            if working {
                                ProgressView()
                                Text(progress).font(.footnote)
                            } else {
                                Image(systemName: "doc.richtext")
                                Text(LS("生成"))
                            }
                            Spacer(minLength: 0)
                        }
                        .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large)
                    .disabled(working || r.lines.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    ShareLink(items: files) {
                        HStack(spacing: AppSpacing.icon) {
                            Spacer(minLength: 0)
                            Image(systemName: "square.and.arrow.up")
                            Text(LS("分享 %@ 个文件", files.count))
                            Spacer(minLength: 0)
                        }
                        .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .onChange(of: withDocs) { _, _ in files = [] }
            .onChange(of: withCSV) { _, _ in files = [] }
            .onChange(of: withXLSX) { _, _ in files = [] }
        }
    }

    private func make(_ r: ReimbReport) async {
        working = true
        defer { working = false }
        failed = []
        // the receipts, in the order of the list, each file once
        var receipts: [ReceiptFile] = []
        if withDocs {
            var seen = Set<String>()
            let all = r.lines.flatMap { l in store.receiptPaths(for: l.entry).map { (l, $0) } }.filter { seen.insert($0.1).inserted }
            for (i, x) in all.enumerated() {
                progress = LS("下载附件 %@/%@", i + 1, all.count)
                do {
                    let d = try await store.backend.readData(x.1)
                    receipts.append(ReceiptFile(path: x.1, data: d, caption: "\(x.0.date)  \(x.0.payee)  \(money(x.0.amount, x.0.currency))"))
                } catch {
                    failed.append((x.1 as NSString).lastPathComponent + "：" + error.localizedDescription)
                }
            }
        }
        progress = LS("生成 PDF…")
        let name = safeFileName(r.title)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reimb-" + String(UUID().uuidString.prefix(6)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        let docNames: (Entry) -> [String] = { t in store.receiptPaths(for: t).map { ($0 as NSString).lastPathComponent } }
        let pdf = ReimbPDF(report: r, receipts: receipts, docNames: docNames).render()
        let pu = dir.appendingPathComponent(name + ".pdf")
        if (try? pdf.write(to: pu)) != nil { out.append(pu) }
        if withXLSX {
            let xu = dir.appendingPathComponent(name + ".xlsx")
            if (try? reimbXLSX(r).write(to: xu)) != nil { out.append(xu) }
        }
        if withCSV {
            let cu = dir.appendingPathComponent(name + ".csv")
            if (try? reimbCSV(r, docs: docNames).data(using: .utf8)?.write(to: cu)) != nil { out.append(cu) }
        }
        files = out
        if out.isEmpty { store.show(LS("生成失败")) }
    }

    private func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>^")
        let t = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined().trimmingCharacters(in: .whitespaces)
        return LS("报销单") + "-" + (t.isEmpty ? Day.today() : t)
    }
}

struct ReceiptFile {
    let path: String
    let data: Data
    let caption: String
}

extension Store {
    /// repository paths of the receipts attached to this transaction (its own document links, not ones shared
    /// by a whole reimbursement or petty cash)
    func receiptPaths(for t: Entry) -> [String] {
        documents(for: t).compactMap(documentRepoPath)
    }
}

/// draws the 报销单: A4, the list with totals and a place to sign, then the receipts
struct ReimbPDF {
    let report: ReimbReport
    let receipts: [ReceiptFile]
    let docNames: (Entry) -> [String]

    private let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private let margin: CGFloat = 40
    private var width: CGFloat { page.width - margin * 2 }
    /// column widths: No., date, merchant, description, paid with, amount, attachments
    private var cols: [CGFloat] { [24, 62, 104, width - 24 - 62 - 104 - 78 - 72 - 34, 78, 72, 34] }

    private func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { .systemFont(ofSize: size, weight: weight) }

    private func attrs(_ f: UIFont, _ color: UIColor = .black, align: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        return [.font: f, .foregroundColor: color, .paragraphStyle: p]
    }

    private func height(_ s: String, _ a: [NSAttributedString.Key: Any], _ w: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: a, context: nil).height)
    }

    func render() -> Data {
        let fmt = UIGraphicsPDFRendererFormat()
        fmt.documentInfo = [kCGPDFContextTitle as String: report.title, kCGPDFContextCreator as String: "Ledger X"]
        let r = UIGraphicsPDFRenderer(bounds: page, format: fmt)
        return r.pdfData { ctx in
            var pageNo = 0
            func newPage() -> CGFloat {
                ctx.beginPage()
                pageNo += 1
                let foot = LS("第 %@ 页", pageNo)
                (foot as NSString).draw(in: CGRect(x: margin, y: page.height - 28, width: width, height: 14), withAttributes: attrs(font(8), .gray, align: .center))
                return margin
            }
            var y = newPage()

            // heading
            let title = LS("报销单")
            (title as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 26), withAttributes: attrs(font(18, .bold), align: .center))
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
            let heads = [LS("序号"), LS("日期"), LS("商户"), LS("说明"), LS("付款方式"), LS("金额"), LS("附件")]
            func row(_ cells: [String], bold: Bool, shade: Bool) {
                let a = attrs(font(8.5, bold ? .semibold : .regular))
                let ar = attrs(font(8.5, bold ? .semibold : .regular), align: .right)
                let inner = cells.enumerated().map { height($0.element, $0.offset == 5 ? ar : a, cols[$0.offset] - 6) }.max() ?? 0
                let h = max(16, inner + 6)
                if y + h > page.height - 50 { y = newPage() }
                if shade {
                    UIColor(white: 0.94, alpha: 1).setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: width, height: h))
                }
                var x = margin
                for (i, c) in cells.enumerated() {
                    (c as NSString).draw(in: CGRect(x: x + 3, y: y + 3, width: cols[i] - 6, height: h - 6), withAttributes: i == 5 ? ar : a)
                    x += cols[i]
                }
                UIColor(white: 0.8, alpha: 1).setFill()
                UIRectFill(CGRect(x: margin, y: y + h - 0.5, width: width, height: 0.5))
                y += h
            }
            row(heads, bold: true, shade: true)
            for (i, l) in report.lines.enumerated() {
                let n = docNames(l.entry).count
                row([String(i + 1), l.date, l.payee, l.narration, l.method, money(l.amount, l.currency), n > 0 ? String(n) : LS("无")], bold: false, shade: false)
            }
            for t in report.totals {
                row(["", "", "", LS("合计"), "", money(t.amount, t.currency), ""], bold: true, shade: true)
            }

            // a place to sign
            y += 28
            if y > page.height - 80 { y = newPage() }
            let sign = LS("报销人：＿＿＿＿＿＿　　审核：＿＿＿＿＿＿　　日期：＿＿＿＿＿＿")
            (sign as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 16), withAttributes: attrs(font(10)))

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
                        drawPDFPage(p, in: box(top + 20), ctx.cgContext)
                    }
                } else if let img = UIImage(data: f.data) {
                    let top = newPage()
                    ((caption + "　" + name) as NSString).draw(in: CGRect(x: margin, y: top, width: width, height: 14), withAttributes: attrs(font(9), .darkGray))
                    let b = box(top + 20)
                    let s = min(b.width / img.size.width, b.height / img.size.height, 1.5)
                    let sz = CGSize(width: img.size.width * s, height: img.size.height * s)
                    img.draw(in: CGRect(x: b.midX - sz.width / 2, y: b.minY, width: sz.width, height: sz.height))
                } else {
                    let top = newPage()
                    (LS("%@：%@ 不是图片或 PDF，未能并入", caption, name) as NSString).draw(in: CGRect(x: margin, y: top, width: width, height: 40), withAttributes: attrs(font(10)))
                }
            }
        }
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
