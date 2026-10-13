import Foundation

// MARK: - writing .xlsx without a library: the Open XML parts, zipped (stored, no compression)

/// a ZIP archive of `files` (path → bytes), stored uncompressed, in the given order
func zipStored(_ files: [(String, Data)]) -> Data {
    var out = Data(), central = Data()
    func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
    func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    // 1980-01-01 00:00, a fixed time keeps the bytes the same for the same content
    let time = 0, date = (0 << 9) | (1 << 5) | 1
    for (name, data) in files {
        let n = Data(name.utf8), crc = crc32(data), offset = out.count
        u32(0x04034b50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(time, &out); u16(date, &out)
        u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out); u16(n.count, &out); u16(0, &out)
        out.append(n); out.append(data)
        u32(0x02014b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
        u16(time, &central); u16(date, &central); u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central)
        u16(n.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central)
        u32(UInt32(offset), &central); central.append(n)
    }
    let start = out.count
    out.append(central)
    u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
    u32(UInt32(central.count), &out); u32(UInt32(start), &out); u16(0, &out)
    return out
}

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ d: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

/// text for an XML element or attribute
func xmlEscape(_ s: String) -> String {
    var o = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "&": o += "&amp;"
        case "<": o += "&lt;"
        case ">": o += "&gt;"
        case "\"": o += "&quot;"
        case "'": o += "&apos;"
        // characters XML 1.0 does not allow are left out
        case _ where ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r": continue
        default: o.unicodeScalars.append(ch)
        }
    }
    return o
}

/// "A", "B" … "Z", "AA" for a 0-based column
func colName(_ i: Int) -> String {
    var n = i + 1, s = ""
    while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
    return s
}

/// Excel's day number for "yyyy-mm-dd" (days since 1899-12-30)
func excelSerial(_ day: String) -> Int {
    let p = day.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return 0 }
    // days from civil (Howard Hinnant), then shift to the 1899-12-30 epoch
    let y = p[1] <= 2 ? p[0] - 1 : p[0], m = p[1], d = p[2]
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468 + 25569
}

// MARK: - 报销模板: the company's expense claim sheet, with two pivot tables

/// The 报销单 as an .xlsx in the layout of the company's 报销模板: 序号 / 日期 / 收入 / 支出 / 余额 (running) /
/// 备注 / 支出类型 / 凭证类型, a 合计 row, and pivot tables of 支出 by 支出类型 (J:K) and by 凭证类型 (M:N).
/// Formulas carry their computed values and the pivot tables their results, so the numbers show in apps that
/// don't recalculate; Excel refreshes the pivots when the file is opened.
public func reimbXLSX(_ r: ReimbReport) -> Data {
    let sheetName = "报销模板"
    let rows = r.rows
    let n = rows.count
    let last = n + 1                      // last data row
    let total = n + 2                     // 合计 row

    // the two summaries, largest first; a blank value is its own group, like Excel's (空白)
    func groups(_ key: (ReimbLine) -> String) -> [(String, Double)] {
        var sum: [String: Double] = [:], order: [String] = []
        for l in rows where !l.income {
            let k = key(l)
            if sum[k] == nil { order.append(k) }
            sum[k, default: 0] += l.amount
        }
        // money received only: still one (blank) group, so the pivot has an item
        for l in rows where l.income && sum[key(l)] == nil { order.append(key(l)); sum[key(l)] = 0 }
        return order.map { ($0, roundTo(sum[$0]!, 2)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
    let byType = groups { $0.income ? "" : $0.category }
    let byVoucher = groups { $0.income ? "" : $0.voucher }
    let spent = roundTo(rows.filter { !$0.income }.reduce(0) { $0 + $1.amount }, 2)
    let received = roundTo(rows.filter { $0.income }.reduce(0) { $0 + $1.amount }, 2)

    // MARK: worksheet
    var cells: [Int: [String]] = [:]      // row → cell xml
    func put(_ row: Int, _ xml: String) { cells[row, default: []].append(xml) }
    func str(_ ref: String, _ s: String, _ style: Int) -> String {
        s.isEmpty ? "<c r=\"\(ref)\" s=\"\(style)\"/>" : "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(s))</t></is></c>"
    }
    func num(_ ref: String, _ v: Double?, _ style: Int) -> String {
        guard let v = v else { return "<c r=\"\(ref)\" s=\"\(style)\"/>" }
        return "<c r=\"\(ref)\" s=\"\(style)\"><v>\(numText(roundTo(v, 2)))</v></c>"
    }
    func fml(_ ref: String, _ f: String, _ v: Double, _ style: Int) -> String {
        "<c r=\"\(ref)\" s=\"\(style)\"><f>\(xmlEscape(f))</f><v>\(numText(roundTo(v, 2)))</v></c>"
    }
    let heads = ["序号", "日期", "收入", "支出", "余额", "备注/详见报销清单", "支出类型", "凭证类型"]
    for (i, h) in heads.enumerated() { put(1, str(colName(i) + "1", h, 1)) }
    var balance = 0.0
    for (i, l) in rows.enumerated() {
        let row = i + 2
        let inc = l.income ? l.amount : 0, out = l.income ? 0 : l.amount
        balance = roundTo(balance + inc - out, 2)
        put(row, fml("A\(row)", "ROW(B\(row))-1", Double(i + 1), 2))
        put(row, "<c r=\"B\(row)\" s=\"3\"><v>\(excelSerial(l.date))</v></c>")
        put(row, num("C\(row)", l.income ? l.amount : nil, 4))
        put(row, num("D\(row)", l.income ? nil : l.amount, 4))
        put(row, fml("E\(row)", row == 2 ? "C2-D2" : "E\(row - 1)+C\(row)-D\(row)", balance, 4))
        let remark = l.narration.isEmpty ? l.payee : l.narration
        put(row, str("F\(row)", remark, 5))
        put(row, str("G\(row)", l.category, 5))
        put(row, str("H\(row)", l.voucher, 2))
    }
    put(total, str("A\(total)", "合计", 6))
    put(total, "<c r=\"B\(total)\" s=\"6\"/>")
    put(total, fml("C\(total)", "SUM(C2:C\(max(2, last)))", received, 7))
    put(total, fml("D\(total)", "SUM(D2:D\(max(2, last)))", spent, 7))
    put(total, fml("E\(total)", "C\(total)-D\(total)", received - spent, 7))
    for c in ["F", "G", "H"] { put(total, "<c r=\"\(c)\(total)\" s=\"6\"/>") }

    // where the pivot tables put their results (Excel redraws them on refresh)
    func pivotCells(_ col: String, _ valCol: String, _ head: String, _ items: [(String, Double)]) {
        put(1, str("\(col)1", head, 8)); put(1, str("\(valCol)1", "求和项:支出", 8))
        for (i, it) in items.enumerated() {
            put(i + 2, str("\(col)\(i + 2)", it.0.isEmpty ? "(空白)" : it.0, 0))
            put(i + 2, num("\(valCol)\(i + 2)", it.1, 9))
        }
        let g = items.count + 2
        put(g, str("\(col)\(g)", "总计", 8)); put(g, num("\(valCol)\(g)", items.reduce(0) { $0 + $1.1 }, 10))
    }
    pivotCells("J", "K", "支出类型", byType)
    pivotCells("M", "N", "凭证类型", byVoucher)

    var sheet = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
    <dimension ref="A1:N\(max(total, byType.count + 2, byVoucher.count + 2))"/>\
    <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
    <sheetFormatPr defaultRowHeight="16.5"/>\
    <cols><col min="1" max="1" width="4.66" customWidth="1"/><col min="2" max="5" width="12.16" customWidth="1"/>\
    <col min="6" max="6" width="31.66" customWidth="1"/><col min="7" max="7" width="12" customWidth="1"/><col min="8" max="8" width="12.5" customWidth="1"/>\
    <col min="9" max="9" width="2.16" customWidth="1"/><col min="10" max="10" width="11.16" hidden="1" customWidth="1"/>\
    <col min="11" max="11" width="11.66" hidden="1" customWidth="1"/><col min="12" max="12" width="1.5" customWidth="1"/>\
    <col min="13" max="13" width="11.83" customWidth="1"/><col min="14" max="14" width="11.66" customWidth="1"/></cols>\
    <sheetData>
    """
    for row in cells.keys.sorted() {
        // cells in column order
        let xs = cells[row]!.sorted { a, b in colIndex(a) < colIndex(b) }
        sheet += "<row r=\"\(row)\">" + xs.joined() + "</row>"
    }
    sheet += "</sheetData><mergeCells count=\"1\"><mergeCell ref=\"A\(total):B\(total)\"/></mergeCells>"
    sheet += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
    sheet += "<pageSetup paperSize=\"9\" orientation=\"portrait\"/></worksheet>"

    // MARK: pivot cache (one, shared by both pivot tables) over A1:H<last>
    let typeItems = Array(Set(rows.map { $0.income ? "" : $0.category })).sorted()
    let voucherItems = Array(Set(rows.map { $0.income ? "" : $0.voucher })).sorted()
    func shared(_ items: [String]) -> String {
        let blank = items.contains("")
        let attrs = blank ? " containsBlank=\"1\"" : ""
        return "<sharedItems\(attrs) count=\"\(items.count)\">" + items.map { $0.isEmpty ? "<m/>" : "<s v=\"\(xmlEscape($0))\"/>" }.joined() + "</sharedItems>"
    }
    func numShared(_ vs: [Double?]) -> String {
        let xs = vs.compactMap { $0 }
        guard let lo = xs.min(), let hi = xs.max() else { return "<sharedItems containsString=\"0\" containsBlank=\"1\"/>" }
        var a = xs.count < vs.count ? " containsString=\"0\" containsBlank=\"1\"" : " containsSemiMixedTypes=\"0\" containsString=\"0\""
        a += " containsNumber=\"1\""
        if xs.allSatisfy({ $0 == $0.rounded() }) { a += " containsInteger=\"1\"" }
        return "<sharedItems\(a) minValue=\"\(numText(lo))\" maxValue=\"\(numText(hi))\"/>"
    }
    var bal = 0.0
    var balances: [Double] = []
    for l in rows { bal = roundTo(bal + (l.income ? l.amount : -l.amount), 2); balances.append(bal) }
    let dates = rows.map { $0.date }
    let remarks = rows.map { $0.narration.isEmpty ? $0.payee : $0.narration }
    var cacheFields = "<cacheFields count=\"8\">"
    cacheFields += "<cacheField name=\"序号\" numFmtId=\"0\">" + numShared(rows.indices.map { Double($0 + 1) }) + "</cacheField>"
    if let lo = dates.min(), let hi = dates.max() {
        cacheFields += "<cacheField name=\"日期\" numFmtId=\"176\"><sharedItems containsSemiMixedTypes=\"0\" containsNonDate=\"0\" containsDate=\"1\" containsString=\"0\" minDate=\"\(lo)T00:00:00\" maxDate=\"\(hi)T00:00:00\"/></cacheField>"
    } else {
        cacheFields += "<cacheField name=\"日期\" numFmtId=\"0\"><sharedItems/></cacheField>"
    }
    cacheFields += "<cacheField name=\"收入\" numFmtId=\"177\">" + numShared(rows.map { $0.income ? $0.amount : nil }) + "</cacheField>"
    cacheFields += "<cacheField name=\"支出\" numFmtId=\"177\">" + numShared(rows.map { $0.income ? nil : $0.amount }) + "</cacheField>"
    cacheFields += "<cacheField name=\"余额\" numFmtId=\"177\">" + numShared(balances) + "</cacheField>"
    let remarkBlank = remarks.contains("")
    cacheFields += "<cacheField name=\"备注/详见报销清单\" numFmtId=\"0\"><sharedItems\(remarkBlank ? " containsBlank=\"1\"" : "")/></cacheField>"
    cacheFields += "<cacheField name=\"支出类型\" numFmtId=\"0\">" + shared(typeItems) + "</cacheField>"
    cacheFields += "<cacheField name=\"凭证类型\" numFmtId=\"0\">" + shared(voucherItems) + "</cacheField>"
    cacheFields += "</cacheFields>"
    let cacheDef = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotCacheDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    r:id="rId1" refreshOnLoad="1" refreshedBy="Ledger X" refreshedDate="45900" createdVersion="5" refreshedVersion="5" minRefreshableVersion="3" recordCount="\(n)">\
    <cacheSource type="worksheet"><worksheetSource ref="A1:H\(max(2, last))" sheet="\(sheetName)"/></cacheSource>\(cacheFields)</pivotCacheDefinition>
    """
    var records = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<pivotCacheRecords xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" count=\"\(n)\">"
    for (i, l) in rows.enumerated() {
        records += "<r><n v=\"\(i + 1)\"/><d v=\"\(l.date)T00:00:00\"/>"
        records += l.income ? "<n v=\"\(numText(l.amount))\"/><m/>" : "<m/><n v=\"\(numText(l.amount))\"/>"
        records += "<n v=\"\(numText(balances[i]))\"/>"
        records += remarks[i].isEmpty ? "<m/>" : "<s v=\"\(xmlEscape(remarks[i]))\"/>"
        records += "<x v=\"\(typeItems.firstIndex(of: l.income ? "" : l.category)!)\"/>"
        records += "<x v=\"\(voucherItems.firstIndex(of: l.income ? "" : l.voucher)!)\"/></r>"
    }
    records += "</pivotCacheRecords>"

    // MARK: pivot tables
    func pivot(_ name: String, _ col: String, _ valCol: String, field: Int, cacheItems: [String], shown: [(String, Double)]) -> String {
        let end = shown.count + 2
        // items in the order shown (largest first), each pointing at its cache item
        let order = shown.map { s in cacheItems.firstIndex(of: s.0)! }
        var fields = ""
        for f in 0..<8 {
            if f == field {
                fields += "<pivotField axis=\"axisRow\" compact=\"0\" showAll=\"0\"><items count=\"\(order.count + 1)\">"
                    + order.map { "<item x=\"\($0)\"/>" }.joined() + "<item t=\"default\"/></items></pivotField>"
            } else if f == 3 {
                fields += "<pivotField dataField=\"1\" compact=\"0\" showAll=\"0\"/>"
            } else {
                fields += "<pivotField compact=\"0\" showAll=\"0\"/>"
            }
        }
        let rowItems = shown.indices.map { $0 == 0 ? "<i><x/></i>" : "<i><x v=\"\($0)\"/></i>" }.joined() + "<i t=\"grand\"><x/></i>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <pivotTableDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" name="\(name)" cacheId="0" \
        applyNumberFormats="0" applyBorderFormats="0" applyFontFormats="0" applyPatternFormats="0" applyAlignmentFormats="0" \
        applyWidthHeightFormats="1" dataCaption="值" updatedVersion="5" minRefreshableVersion="3" createdVersion="5" \
        useAutoFormatting="1" compact="0" indent="0" outline="1" compactData="0" outlineData="1" multipleFieldFilters="0">\
        <location ref="\(col)1:\(valCol)\(end)" firstHeaderRow="1" firstDataRow="1" firstDataCol="1"/>\
        <pivotFields count="8">\(fields)</pivotFields>\
        <rowFields count="1"><field x="\(field)"/></rowFields>\
        <rowItems count="\(shown.count + 1)">\(rowItems)</rowItems>\
        <colItems count="1"><i/></colItems>\
        <dataFields count="1"><dataField name="求和项:支出" fld="3" baseField="0" baseItem="0" numFmtId="178"/></dataFields>\
        <pivotTableStyleInfo name="PivotStyleLight16" showRowHeaders="1" showColHeaders="1" showRowStripes="0" showColStripes="0" showLastColumn="1"/>\
        </pivotTableDefinition>
        """
    }
    let pt1 = pivot("数据透视表1", "J", "K", field: 6, cacheItems: typeItems, shown: byType)
    let pt2 = pivot("数据透视表2", "M", "N", field: 7, cacheItems: voucherItems, shown: byVoucher)

    // MARK: package
    let ct = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
    <Override PartName="/xl/pivotCache/pivotCacheDefinition1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml"/>\
    <Override PartName="/xl/pivotCache/pivotCacheRecords1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheRecords+xml"/>\
    <Override PartName="/xl/pivotTables/pivotTable1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml"/>\
    <Override PartName="/xl/pivotTables/pivotTable2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
    </Types>
    """
    let rels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """
    let core = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscape(r.title))</dc:title><dc:creator>Ledger X</dc:creator></cp:coreProperties>
    """
    let app = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Ledger X</Application></Properties>
    """
    let workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
    <bookViews><workbookView/></bookViews><sheets><sheet name="\(sheetName)" sheetId="1" r:id="rId1"/></sheets>\
    <calcPr calcId="191029" fullCalcOnLoad="1"/><pivotCaches><pivotCache cacheId="0" r:id="rId3"/></pivotCaches></workbook>
    """
    let wbRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotCacheDefinition" Target="pivotCache/pivotCacheDefinition1.xml"/>\
    </Relationships>
    """
    let sheetRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotTable" Target="../pivotTables/pivotTable1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotTable" Target="../pivotTables/pivotTable2.xml"/>\
    </Relationships>
    """
    let ptRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotCacheDefinition" Target="../pivotCache/pivotCacheDefinition1.xml"/>\
    </Relationships>
    """
    let cacheRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotCacheRecords" Target="pivotCacheRecords1.xml"/>\
    </Relationships>
    """
    // styles: 0 plain · 1 header · 2 centred with border · 3 date · 4 money · 5 text · 6 total label · 7 total money
    //         8 pivot header · 9 pivot money · 10 pivot total money
    let money = "_ &quot;￥&quot;* #,##0.00_ ;_ &quot;￥&quot;* \\-#,##0.00_ ;_ &quot;￥&quot;* &quot;-&quot;??_ ;_ @_ "
    let pmoney = "&quot;￥&quot;#,##0.00_);[Red]\\(&quot;￥&quot;#,##0.00\\)"
    let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="3"><numFmt numFmtId="176" formatCode="yyyy/m/d;@"/><numFmt numFmtId="177" formatCode="\(money)"/><numFmt numFmtId="178" formatCode="\(pmoney)"/></numFmts>\
    <fonts count="2"><font><sz val="11"/><name val="等线"/><family val="2"/><charset val="134"/></font>\
    <font><b/><sz val="11"/><name val="等线"/><family val="2"/><charset val="134"/></font></fonts>\
    <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill></fills>\
    <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>\
    <border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right><top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="11">\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>\
    <xf numFmtId="176" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>\
    <xf numFmtId="177" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>\
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>\
    <xf numFmtId="177" fontId="1" fillId="2" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    <xf numFmtId="178" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="178" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>\
    </cellXfs><cellStyles count="1"><cellStyle name="常规" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """
    let parts: [(String, String)] = [
        ("[Content_Types].xml", ct), ("_rels/.rels", rels), ("docProps/core.xml", core), ("docProps/app.xml", app),
        ("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", wbRels), ("xl/styles.xml", styles),
        ("xl/worksheets/sheet1.xml", sheet), ("xl/worksheets/_rels/sheet1.xml.rels", sheetRels),
        ("xl/pivotCache/pivotCacheDefinition1.xml", cacheDef), ("xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels", cacheRels),
        ("xl/pivotCache/pivotCacheRecords1.xml", records),
        ("xl/pivotTables/pivotTable1.xml", pt1), ("xl/pivotTables/_rels/pivotTable1.xml.rels", ptRels),
        ("xl/pivotTables/pivotTable2.xml", pt2), ("xl/pivotTables/_rels/pivotTable2.xml.rels", ptRels),
    ]
    return zipStored(parts.map { ($0.0, Data($0.1.utf8)) })
}

/// the column of a cell's xml (`<c r="K12" …`), for ordering the cells of a row
private func colIndex(_ xml: String) -> Int {
    guard let r = xml.range(of: "r=\"") else { return 0 }
    var n = 0
    for ch in xml[r.upperBound...] {
        guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
        n = n * 26 + Int(a - 64)
    }
    return n
}
