import XCTest
@testable import LedgerKit

// Expected values come from the web app (ledger.js + app.js) via ios/tools/golden.mjs.

let TODAY = "2026-10-08"

func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
}

func loadJSON(_ name: String) -> [String: Any] {
    let data = try! Data(contentsOf: fixtureURL(name))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

func loadSet(_ name: String) -> Ledger {
    let dir = fixtureURL(name)
    return loadLedger(root: "main.bean") { path in
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }
}

func r6(_ n: Double?) -> Double? { n.map { jsRound($0 * 1e6) / 1e6 } }

/// compares JSON-ish values; numbers with a small tolerance
func unwrap(_ x: Any?) -> Any? {
    guard let x = x else { return nil }
    let m = Mirror(reflecting: x)
    if m.displayStyle == .optional {
        guard let c = m.children.first else { return nil }
        return unwrap(c.value)
    }
    return x
}

func same(_ a0: Any?, _ b0: Any?) -> Bool {
    let a = unwrap(a0), b = unwrap(b0)
    switch (a, b) {
    case (nil, nil): return true
    case (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull): return true
    case let (x as NSNumber, y as Double): return abs(x.doubleValue - y) < 1e-6
    case let (x as NSNumber, y as Int): return abs(x.doubleValue - Double(y)) < 1e-9
    case let (x as String, y as String): return x == y
    case let (x as [Any], y as [Any]): return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
    case let (x as [String: Any], y as [String: Any]):
        return Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { same(x[$0], y[$0]) }
    default:
        if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) < 1e-6 }
        return false
    }
}

final class GoldenTests: XCTestCase {
    let expected = loadJSON("expected.json")

    func check(_ label: String, _ js: Any?, _ swift: Any?, file: StaticString = #filePath, line: UInt = #line) {
        if !same(js, swift) {
            XCTFail("\(label)\n  js:    \(String(describing: js).prefix(600))\n  swift: \(String(describing: swift).prefix(600))", file: file, line: line)
        }
    }

    func runSet(_ name: String) {
        let L = loadSet(name)
        let D = Derived(L, today: TODAY)
        let e = expected[name] as! [String: Any]
        check("\(name) entries", e["entries"], L.entries.count)
        let jt = e["txns"] as! [[Any]]
        check("\(name) txn count", jt.count, L.txns.count)
        var shown = 0
        for (i, t) in L.txns.enumerated() where i < jt.count && shown < 15 {
            let row: [Any] = [t.date, t.flag, t.payee, t.narration, t.tags, t.links, t.synthetic ? 1 : 0,
                              t.postings.map { p -> [Any?] in [p.account, r6(p.units), p.currency, p.interpolated ? 1 : 0, r6(p.cost?.number), r6(p.price?.number)] }]
            if !same(jt[i], row) { check("\(name) txn \(i)", jt[i], row); shown += 1 }
        }
        check("\(name) errors", e["errors"], L.errors.map { $0.msg })
        check("\(name) balances", e["balanceResults"], L.balanceResults.map { [$0.entry.date, $0.entry.account!, $0.ok ? 1 : 0, r6($0.got)!] as [Any] })
        var fin: [String: Any] = [:]
        for (a, cs) in L.final { fin[a] = cs.mapValues { r6($0)! } }
        check("\(name) final", e["final"], fin)
        var inv: [String: Any] = [:]
        for (a, lots) in L.inventory {
            inv[a] = lots.map { l -> [Any?] in [r6(l.units), l.currency, r6(l.cost?.number), l.cost?.currency, l.cost?.date, l.cost?.label] }
        }
        check("\(name) inventory", e["inventory"], inv)
        var rates: [String: Any] = [:]
        for c in L.rates.keys { rates[c] = r6(toCNY(L, 1, c)) }
        check("\(name) rates", e["rates"], rates)
        check("\(name) monthExp", e["monthExp"], D.monthExp.mapValues { r6($0)! })
        check("\(name) openAccounts", e["openAccounts"], D.openAccounts.sorted())
        check("\(name) currencies", e["currencies"], D.currencies.sorted())
        check("\(name) acctCcy", e["acctCcy"], D.acctCcy)
        check("\(name) payees", e["payeesTop"], Array(D.payees.prefix(5).map { $0.name }))
        let tpl = templates(L, pinned: [], hidden: [], today: TODAY).map { x -> [Any?] in [x.id, x.kind.rawValue, x.fixed, x.monthly ? 1 : 0, x.due ? 1 : 0, x.n, x.funding] }
        check("\(name) templates", e["templates"], tpl)
        check("\(name) classify", e["classify"], L.txns.map { t -> [Any] in let c = classify(t, L); return [c.kind.rawValue, r6(c.amount)!] })
        check("\(name) complex", e["complex"], L.txns.map { isComplex($0) ? 1 : 0 })
    }

    func testFullSyntax() { runSet("full") }
    func testErrors() { runSet("errors") }
    func testRealistic() { runSet("realistic") }

    func testPerformance() {
        let start = Date()
        let L = loadSet("realistic")
        _ = Derived(L, today: TODAY)
        let dt = Date().timeIntervalSince(start)
        print("realistic ledger: \(L.txns.count) txns in \(String(format: "%.2f", dt))s")
        XCTAssertLessThan(dt, 10)
    }
}

final class CaseTests: XCTestCase {
    let cases = loadJSON("cases.json")
    lazy var L = loadSet("realistic")
    lazy var D = Derived(L, today: TODAY)

    func rows(_ k: String) -> [[Any]] { cases[k] as! [[Any]] }

    func testNumbers() {
        for c in rows("numText") { XCTAssertEqual(numText((c[0] as! NSNumber).doubleValue), c[1] as? String, "numText \(c[0])") }
        for c in rows("fmtNum") { XCTAssertEqual(fmtNum((c[0] as! NSNumber).doubleValue, (c[1] as! NSNumber).intValue), c[2] as? String, "fmtNum \(c[0])") }
        for c in rows("money") { XCTAssertEqual(money((c[0] as! NSNumber).doubleValue, c[1] as! String), c[2] as? String) }
        for c in rows("evalAmount") {
            let v = evalAmount(c[0] as! String)
            if let e = c[1] as? NSNumber { XCTAssertEqual(v ?? .nan, e.doubleValue, accuracy: 1e-9, "evalAmount \(c[0])") } else { XCTAssertNil(v, "evalAmount \(c[0])") }
        }
    }

    func txDraft(_ j: [String: Any]) -> TxDraft {
        var tx = TxDraft(date: j["date"] as! String)
        tx.flag = j["flag"] as? String ?? "*"
        tx.payee = j["payee"] as? String ?? ""
        tx.narration = j["narration"] as? String ?? ""
        tx.tags = j["tags"] as? [String] ?? []
        tx.links = j["links"] as? [String] ?? []
        tx.meta = (j["meta"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        tx.postings = (j["postings"] as! [[String: Any]]).map { p in
            var x = TxPosting(account: p["account"] as! String)
            if let u = p["units"] as? String { x.units = u } else if let u = p["units"] as? NSNumber { x.units = numText(u.doubleValue) }
            x.currency = p["currency"] as? String
            x.flag = p["flag"] as? String
            x.cost = p["cost"] as? String
            x.price = p["price"] as? String
            x.priceTotal = (p["priceTotal"] as? NSNumber)?.doubleValue
            x.priceCcy = p["priceCcy"] as? String
            x.meta = (p["meta"] as? [String: String] ?? [:]).map { ($0.key, $0.value) }
            // keep the JSON key order of posting meta: note before date
            x.meta.sort { ($0.0 == "note" ? 0 : 1) < ($1.0 == "note" ? 0 : 1) }
            return x
        }
        return tx
    }

    func testFormatting() {
        for c in rows("formatTxn") { XCTAssertEqual(formatTxn(txDraft(c[0] as! [String: Any])), c[1] as? String) }
        for c in rows("insertEntry") { XCTAssertEqual(insertEntry(c[0] as! String, c[1] as! String, c[2] as! String), c[3] as? String, "insertEntry \(c[2])") }
        for c in rows("alignText") { XCTAssertEqual(alignText(c[0] as! String), c[1] as? String) }
    }

    func testEdits() {
        for c in rows("removeBlock") { XCTAssertEqual(removeBlock(c[0] as! String, c[1] as! String), c[2] as? String) }
        for c in rows("insertBalance") {
            let j = c[0] as! [String: Any]
            var op = Op(kind: .balance, path: "accounts/balance.bean")
            op.account = j["account"] as? String; op.date = j["date"] as? String; op.currency = j["currency"] as? String
            op.replace = j["replace"] as? Bool; op.line = j["line"] as? String
            let text = try! String(contentsOf: fixtureURL("realistic/accounts/balance.bean"), encoding: .utf8)
            XCTAssertEqual(insertBalance(text, op), c[1] as? String, "insertBalance \(j)")
            XCTAssertEqual(balanceLine(op.date!, op.account!, 0, "CNY").count > 0, true)
        }
        for c in rows("addInclude") { XCTAssertEqual(addInclude(c[0] as! String, c[1] as! String), c[2] as? String) }
        for c in rows("addLinkToHeader") {
            let j = c[1] as! [String: Any]
            var op = Op(kind: .link, path: "x")
            op.headerLine = (j["line"] as? NSNumber)?.intValue; op.header = j["header"] as? String; op.link = j["link"] as? String
            XCTAssertEqual(addLinkToHeader(c[0] as! String, op), c[2] as? String)
        }
    }

    func testCheck() {
        for c in rows("checkText") {
            let r = checkText(c[0] as! String, L)
            XCTAssertEqual(r.ok ? 1 : 0, (c[1] as! NSNumber).intValue, "checkText ok: \(c[0])")
            XCTAssertEqual(r.msg, c[2] as? String, "checkText msg: \(c[0])")
            XCTAssertEqual(r.warnings.count, (c[3] as! NSNumber).intValue, "checkText warnings: \(c[0])")
            XCTAssertEqual(r.entries.count, (c[4] as! NSNumber).intValue, "checkText entries: \(c[0])")
        }
        for c in rows("validate") {
            let v = validateText(c[0] as! String, L, single: true)
            XCTAssertEqual(v.ok ? 1 : 0, (c[1] as! NSNumber).intValue, "validate: \(c[0])")
            XCTAssertEqual(v.msg, c[2] as? String, "validate msg: \(c[0])")
        }
        for c in rows("fileFor") {
            let e = L.entries.first { $0.type.rawValue == c[0] as! String && $0.date == c[1] as! String && ($0.account ?? $0.currency ?? "") == c[2] as! String }
            XCTAssertNotNil(e)
            if let e = e { XCTAssertEqual(fileFor(e, L), c[3] as? String) }
        }
    }

    func testDrafts() {
        for c in rows("drafts") {
            let j = c[0] as! [String: Any]
            var d = Draft()
            d.kind = DraftKind(rawValue: j["kind"] as! String)!
            d.date = TODAY
            d.payee = j["payee"] as? String ?? ""
            d.narration = j["narration"] as? String ?? ""
            d.amount = j["amount"] as? String ?? ""
            d.currency = j["currency"] as? String ?? "CNY"
            d.account = j["account"] as? String ?? ""
            d.funding = j["funding"] as? String ?? ""
            d.to = j["to"] as? String ?? ""
            d.toAmount = j["toAmount"] as? String ?? ""
            d.paid = j["paid"] as? String ?? ""
            d.reimb = j["reimb"] as? Bool ?? false
            d.link = j["link"] as? String ?? ""
            d.tags = j["tags"] as? [String] ?? []
            d.flag = j["flag"] as? String ?? "*"
            d.tagsText = j["tagsText"] as? String ?? ""
            d.rows = (j["rows"] as? [[String: Any]] ?? []).map { r in
                var x = DraftRow(account: r["account"] as? String ?? "", currency: r["currency"] as? String ?? "CNY")
                x.amount = r["amount"] as? String ?? ""; x.cost = r["cost"] as? String ?? ""; x.price = r["price"] as? String ?? ""; x.flag = r["flag"] as? String ?? ""
                return x
            }
            XCTAssertEqual(draftText(d, L, D), c[1] as? String, "draft \(d.kind) \(d.payee)")
        }
        let nd = cases["newDraft"] as! [String]
        let d = newDraft(.expense, D, defaultFunding: nil)
        XCTAssertEqual(d.funding, nd[0])
        XCTAssertEqual(d.currency, nd[1])
    }

    func testRowsFromTxn() {
        for c in rows("rowsFromTxn") {
            let t = L.txns[(c[0] as! NSNumber).intValue]
            let r = rowsFromTxn(t, withAmounts: true).map { [$0.account, $0.amount, $0.currency, $0.cost, $0.price, $0.flag] }
            XCTAssertEqual(r, c[1] as? [[String]])
        }
    }

    func testLayout() {
        XCTAssertEqual(RepoLayout.detect(L).journal, "journals/{year}.bean")
        XCTAssertEqual(RepoLayout.detect(loadSet("full")).journal, "main.bean")
        let lay = RepoLayout(main: "ledger/main.bean", journal: "ledger/txns/{year}.bean")
        var d = newDraft(.expense, D, defaultFunding: "Assets:Bank:CGB")
        d.date = "2027-01-02"; d.payee = "x"; d.amount = "1"; d.account = "Expenses:Food:Drinks"
        guard case .success(let ops) = makeOps(draftText(d, L, D), L, layout: lay, pending: [], fileExists: { _ in false }, single: true) else { return XCTFail() }
        XCTAssertEqual(ops.map { $0.path }, ["ledger/main.bean", "ledger/txns/2027.bean"])
        XCTAssertEqual(ops[0].line, "include \"txns/2027.bean\"")
    }

    func testOpsRoundTrip() {
        // queue an expense, apply it to the journal, re-parse: the ledger must grow by one balanced transaction
        var d = newDraft(.expense, D, defaultFunding: "Assets:Bank:CGB")
        d.date = TODAY; d.payee = "便利店"; d.narration = "香烟"; d.amount = "18"; d.account = "Expenses:Food:Drinks"
        let text = draftText(d, L, D)
        guard case .success(let ops) = makeOps(text, L, pending: [], fileExists: { _ in true }, single: true) else { return XCTFail("makeOps") }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].path, "journals/2026.bean")
        XCTAssertEqual(commitMessage(ops, path: ops[0].path), "记账：2026-10-08 便利店 香烟")
        let dir = fixtureURL("realistic")
        let L2 = loadLedger { path in
            let t = try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
            return try applyOps(t, path: path, ops: ops, strict: true)
        }
        XCTAssertEqual(L2.txns.count, L.txns.count + 1)
        XCTAssertEqual(L2.errors.count, L.errors.count)
        // and remove it again
        var rm = Op(kind: .remove, path: ops[0].path)
        rm.old = ops[0].text
        let L3 = loadLedger { path in
            let t = try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
            return try applyOps(t, path: path, ops: ops + [rm], strict: true)
        }
        XCTAssertEqual(L3.txns.count, L.txns.count)
        // a new year's journal gets an include in main.bean
        d.date = "2027-01-02"
        guard case .success(let ops2) = makeOps(draftText(d, L, D), L, pending: [], fileExists: { $0 != "journals/2027.bean" }, single: true) else { return XCTFail() }
        XCTAssertEqual(ops2.map { $0.kind }, [.include, .insert])
        XCTAssertEqual(ops2[0].line, "include \"journals/2027.bean\"")
    }
}
