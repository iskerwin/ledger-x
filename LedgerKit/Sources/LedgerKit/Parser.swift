import Foundation

public struct ParseResult {
    public var entries: [Entry] = []
    public var includes: [String] = []
    public var options: [String: [String?]] = [:]
    public var plugins: [(String?, String?)] = []
    public var errors: [LedgerError] = []
}

private func matchKeyword(_ line: [US]) -> String? {
    for kw in ["include", "option", "plugin", "pushtag", "poptag", "pushmeta", "popmeta"] {
        let k = scalars(kw)
        guard line.count >= k.count else { continue }
        var same = true
        for i in 0..<k.count where line[i] != k[i] { same = false; break }
        if same && (line.count == k.count || !isWordChar(line[k.count])) { return kw }
    }
    return nil
}

/// `^([a-z]+)\b` at s[i...]
private func lowerWord(_ s: [US], _ i: Int) -> String? {
    var j = i
    while j < s.count, isaz(s[j]) { j += 1 }
    guard j > i else { return nil }
    if j < s.count, isWordChar(s[j]) { return nil }
    return str(s[i..<j])
}

/// `key: value` metadata line (indented). Returns (key, value text) or nil.
private func metaKV(_ s: [US], requireIndent: Bool, loose: Bool = false) -> (String, String)? {
    var i = 0
    while i < s.count, isWS(s[i]) { i += 1 }
    if requireIndent && i == 0 { return nil }
    guard i < s.count, isaz(s[i]) else { return nil }
    var j = i + 1
    while j < s.count, isWordChar(s[j]) || s[j] == "-" { j += 1 }
    guard j < s.count, s[j] == ":" else { return nil }
    let key = str(s[i..<j])
    let after = j + 1
    if after >= s.count { return (key, "") }
    if !loose && !isWS(s[after]) { return nil }
    return (key, str(s[after...]).trimmingCharacters(in: .whitespaces))
}

public func parseFile(_ text: String, file: String) -> ParseResult {
    var res = ParseResult()
    var tagStack: [String] = []
    var metaStack: [String: [MetaValue?]] = [:]
    var metaOrder: [String] = []
    var raw = text.components(separatedBy: "\n").map { line -> String in
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
    if raw.isEmpty { raw = [""] }
    let rawScalars = raw.map(scalars)

    // logical lines (join multi-line strings)
    struct LL { var s: [US]; var start: Int; var end: Int }
    var lines: [LL] = []
    var i = 0
    while i < rawScalars.count {
        var s = rawScalars[i]
        let start = i
        while quoteOpen(s) && i + 1 < rawScalars.count {
            i += 1
            s.append("\n")
            s.append(contentsOf: rawScalars[i])
        }
        lines.append(LL(s: s, start: start, end: i))
        i += 1
    }

    var cur: Entry? = nil
    var postIndent = 0
    func flush() {
        if let c = cur {
            c.src = raw[c.startLine...c.endLine].joined(separator: "\n")
            res.entries.append(c)
            cur = nil
            postIndent = 0
        }
    }
    func err(_ ln: LL, _ msg: String) {
        res.errors.append(LedgerError(file: file, line: ln.start + 1, msg: msg))
    }

    for ln in lines {
        let full = ln.s
        if isBlank(full) { flush(); continue }
        let indented = full[0] == " " || full[0] == "\t"
        if !indented {
            flush()
            if ";*#:!&%|".unicodeScalars.contains(full[0]) && dateAt(full, 0) == nil { continue } // comments, org-mode headers
            let line = trimEnd(stripComment(full))
            if isBlank(line) { continue }
            let sc = Scan(line)
            if let kw = matchKeyword(line) {
                sc.i = kw.unicodeScalars.count
                switch kw {
                case "include":
                    if let p = sc.string() { res.includes.append(p) }
                case "option":
                    let k = sc.string(), v = sc.string()
                    if let k = k { res.options[k, default: []].append(v) }
                case "plugin":
                    let n = sc.string(), c = sc.string()
                    res.plugins.append((n, c))
                case "pushtag":
                    if let t = sc.tagOrLink() { tagStack.append(t.value) }
                case "poptag":
                    let t = sc.tagOrLink()
                    if let t = t, let k = tagStack.lastIndex(of: t.value) { tagStack.remove(at: k) } else { err(ln, "poptag 没有对应的 pushtag") }
                case "pushmeta":
                    if let kv = metaKV(Array(sc.s[sc.i...]), requireIndent: false, loose: true) {
                        if metaStack[kv.0] == nil { metaOrder.append(kv.0) }
                        metaStack[kv.0, default: []].append(parseValue(kv.1))
                    }
                case "popmeta":
                    if let kv = metaKV(Array(sc.s[sc.i...]), requireIndent: false, loose: true), var st = metaStack[kv.0], !st.isEmpty {
                        st.removeLast()
                        metaStack[kv.0] = st
                    }
                default: break
                }
                continue
            }
            guard let date = sc.date() else {
                err(ln, "无法识别：" + String(str(line).prefix(60)))
                continue
            }
            sc.ws()
            func base(_ type: EntryType) -> Entry {
                let e = Entry(type: type, date: date, file: file, line: ln.start + 1, startLine: ln.start, endLine: ln.end)
                for k in metaOrder {
                    if let st = metaStack[k], let last = st.last, let v = last { e.meta[k] = v }
                }
                return e
            }
            let word = lowerWord(sc.s, sc.i)
            let flagCh = sc.peek().map { String($0) } ?? ""
            let afterFlag = sc.at(sc.i + 1)
            if word == "txn" || (FLAGS.contains(flagCh) && (afterFlag == nil || isWS(afterFlag!))) {
                let flag = word == "txn" ? "*" : flagCh
                sc.i += word == "txn" ? 3 : 1
                var strs: [String] = []
                while let s = sc.string() { strs.append(s) }
                var tags = tagStack
                var links: [String] = []
                while let t = sc.tagOrLink() { if t.isTag { tags.append(t.value) } else { links.append(t.value) } }
                if !sc.eof() { err(ln, "交易标题行多余内容：" + sc.rest()) }
                let e = base(.txn)
                e.flag = flag
                if strs.count >= 2 { e.payee = strs[0]; e.narration = strs[1] } else if strs.count == 1 { e.narration = strs[0] }
                e.hasPayee = strs.count >= 2
                var seen = Set<String>()
                e.tags = tags.filter { seen.insert($0).inserted }
                e.links = links
                cur = e
                continue
            }
            guard let kind = word else { err(ln, "无法识别的指令"); continue }
            sc.i += kind.unicodeScalars.count
            var e: Entry? = nil
            switch kind {
            case "open":
                let x = base(.open)
                x.account = sc.account()
                while let c = sc.currency() { x.currencies.append(c); if !sc.eat(",") { break } }
                x.booking = sc.string()
                e = x
            case "close":
                let x = base(.close); x.account = sc.account(); e = x
            case "commodity":
                let x = base(.commodity); x.currency = sc.currency(); e = x
            case "balance":
                let account = sc.account()
                let n = sc.number()
                var tolerance: Double? = nil
                if sc.eat("~") { tolerance = sc.number()?.value }
                let currency = sc.currency()
                if tolerance == nil && sc.eat("~") { tolerance = sc.number()?.value }
                guard let a = account, let nn = n, let c = currency else { err(ln, "balance 格式不对"); break }
                let x = base(.balance)
                x.account = a; x.number = nn.value; x.digits = nn.digits; x.tolerance = tolerance; x.currency = c
                e = x
            case "pad":
                let x = base(.pad); x.account = sc.account(); x.source = sc.account(); e = x
            case "note":
                let x = base(.note); x.account = sc.account(); x.comment = sc.string(); e = x
            case "document":
                let x = base(.document)
                x.account = sc.account(); x.path = sc.string()
                while let t = sc.tagOrLink() { if t.isTag { x.tags.append(t.value) } else { x.links.append(t.value) } }
                e = x
            case "event":
                let x = base(.event); x.name = sc.string(); x.eventDescription = sc.string(); e = x
            case "query":
                let x = base(.query); x.name = sc.string(); x.query = sc.string(); e = x
            case "price":
                let c = sc.currency(), n = sc.number(), q = sc.currency()
                guard let cc = c, let nn = n, let qq = q else { err(ln, "price 格式不对"); break }
                let x = base(.price); x.currency = cc; x.number = nn.value; x.quote = qq
                e = x
            case "custom":
                let x = base(.custom)
                x.name = sc.string()
                while !sc.eof() {
                    if let s = sc.string() { x.values.append(.string(s)); continue }
                    if let d = sc.date() { x.values.append(.date(d)); continue }
                    if let a = sc.account() { x.values.append(.raw(a)); continue }
                    if let n = sc.number() {
                        if let c = sc.currency() { x.values.append(.amount(n.value, c)) } else { x.values.append(.number(n.value)) }
                        continue
                    }
                    sc.ws()
                    let r = sc.rest()
                    if r.hasPrefix("TRUE") { sc.i += 4; x.values.append(.bool(true)); continue }
                    if r.hasPrefix("FALSE") { sc.i += 5; x.values.append(.bool(false)); continue }
                    break
                }
                e = x
            default:
                err(ln, "未知指令：" + kind)
            }
            if let x = e {
                if !sc.eof() && x.type != .custom { err(ln, "\(kind) 多余内容：\(sc.rest())") }
                cur = x
            }
            continue
        }

        // indented line
        var k = 0
        while k < full.count, isWS(full[k]) { k += 1 }
        if k < full.count, full[k] == ";" { continue }
        guard let c = cur else { err(ln, "缩进行不属于任何指令"); continue }
        let line = trimEnd(stripComment(full))
        if isBlank(line) { continue }
        c.endLine = ln.end
        var indent = 0
        for ch in line { if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break } }
        if let kv = metaKV(line, requireIndent: true) {
            let key = kv.0
            let value = parseValue(kv.1)
            if c.type == .txn, let last = c.postings.last, indent > postIndent {
                last.meta[key] = value
            } else {
                c.meta[key] = value
            }
            continue
        }
        if c.type != .txn { err(ln, "这里只能写 key: value 元数据"); continue }
        guard let p = parsePosting(line) else {
            c.bad.append(str(line).trimmingCharacters(in: .whitespaces))
            continue
        }
        postIndent = indent
        c.postings.append(p)
    }
    flush()
    return res
}

func parsePosting(_ line: [US]) -> Posting? {
    let sc = Scan(line)
    sc.ws()
    var flag: String? = nil
    if let f = sc.peek(), FLAGS.contains(String(f)), let nx = sc.at(sc.i + 1), isWS(nx) {
        flag = String(f)
        sc.i += 1
    }
    guard let account = sc.account() else { return nil }
    let p = Posting(account: account)
    p.flag = flag
    let n = sc.number()
    if let n = n { p.units = n.value; p.digits = n.digits }
    let c = sc.currency()
    if let c = c { p.currency = c }
    if n != nil && c == nil { return nil }
    sc.ws()
    if sc.peek() == "{" {
        let total = sc.peek2() == "{{"
        sc.i += total ? 2 : 1
        let close: [US] = total ? ["}", "}"] : ["}"]
        var end = -1
        var j = sc.i
        while j + close.count <= sc.s.count {
            if sc.s[j] == close[0] && (close.count == 1 || sc.s[j + 1] == close[1]) { end = j; break }
            j += 1
        }
        if end < 0 { return nil }
        let inner = str(sc.s[sc.i..<end])
        sc.i = end + close.count
        guard let cost = parseCostSpec(inner, totalBraces: total) else { return nil }
        p.cost = cost
    }
    sc.ws()
    if sc.peek() == "@" {
        let total = sc.peek2() == "@@"
        sc.i += total ? 2 : 1
        let pn = sc.number()
        let pc = sc.currency()
        let price = PriceSpec(number: nil, currency: pc, total: total, raw: pn?.value)
        if let pn = pn, let u = p.units { price.number = total ? abs(pn.value / u) : pn.value }
        p.price = price
    }
    if !sc.eof() { return nil }
    return p
}

func parseCostSpec(_ inner: String, totalBraces: Bool) -> CostSpec? {
    let spec = CostSpec(totalBraces: totalBraces, raw: inner.trimmingCharacters(in: .whitespaces))
    if spec.raw.isEmpty { return spec }
    for part in splitTopLevel(inner) {
        let t = part.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t == "*" { spec.merge = true; continue }
        let sc = Scan(t)
        if let s = sc.string() { spec.label = s; continue }
        if let d = sc.date(), sc.eof() { spec.date = d; continue }
        sc.i = 0
        // [number] [# number] currency
        let a = sc.number()
        var b: (value: Double, digits: Int)? = nil
        if sc.eat("#") { b = sc.number() }
        let c = sc.currency()
        if c == nil && a == nil && b == nil { return nil }
        if let c = c { spec.currency = c }
        if totalBraces {
            if let a = a { spec.total = a.value }
        } else {
            if let a = a { spec.perUnit = a.value }
            if let b = b { spec.total = b.value }
        }
        if !sc.eof() { return nil }
    }
    return spec
}

func splitTopLevel(_ s: String) -> [String] {
    var out: [String] = []
    var q = false
    var depth = 0
    var cur = ""
    for ch in s {
        if ch == "\"" { q.toggle() }
        if !q && ch == "(" { depth += 1 }
        if !q && ch == ")" { depth -= 1 }
        if ch == "," && !q && depth == 0 { out.append(cur); cur = "" } else { cur.append(ch) }
    }
    out.append(cur)
    return out
}
