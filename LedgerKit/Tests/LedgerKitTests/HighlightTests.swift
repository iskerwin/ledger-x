import XCTest
@testable import LedgerKit

/// syntax colouring: each piece of a line, by kind
final class HighlightTests: XCTestCase {
    /// the text of each span, with its kind
    private func pieces(_ text: String, _ lang: CodeLanguage) -> [String] {
        let ns = text as NSString
        return codeSpans(text, lang).map { "\($0.kind.rawValue):\(ns.substring(with: NSRange(location: $0.location, length: $0.length)))" }
    }

    func testTransaction() {
        let t = """
        2026-10-14 * "丽娜超市" "日用品 #不是标签" #trip-zz ^doc-x
          person: "五姨"
          Expenses:Shopping:Household                         23.00 CNY @ 1.17912 HKD   ; 账单：1CNY=1.17912HKD
          Assets:Bank:HSBC                                   -27.12 HKD
        """
        XCTAssertEqual(pieces(t, .beancount), [
            "date:2026-10-14", "flag:*", "string:\"丽娜超市\"", "string:\"日用品 #不是标签\"", "tag:#trip-zz", "link:^doc-x",
            "metaKey:person:", "string:\"五姨\"",
            "account:Expenses:Shopping:Household", "number:23.00", "currency:CNY", "op:@", "number:1.17912", "currency:HKD",
            "comment:; 账单：1CNY=1.17912HKD",
            "account:Assets:Bank:HSBC", "number:-27.12", "currency:HKD",
        ])
    }

    func testDirectives() {
        XCTAssertEqual(pieces("2026-01-01 open Assets:Bank:BOC CNY\n  name: \"中国银行\"", .beancount),
                       ["date:2026-01-01", "keyword:open", "account:Assets:Bank:BOC", "currency:CNY", "metaKey:name:", "string:\"中国银行\""])
        XCTAssertEqual(pieces("2026-10-14 balance Assets:Cash  400.00 ~ 0.01 CNY", .beancount),
                       ["date:2026-10-14", "keyword:balance", "account:Assets:Cash", "number:400.00", "op:~", "number:0.01", "currency:CNY"])
        XCTAssertEqual(pieces("  Assets:Invest:Stock   1 VOO {{3500.00 CNY}}\n  topup: TRUE", .beancount),
                       ["account:Assets:Invest:Stock", "number:1", "currency:VOO", "op:{{", "number:3500.00", "currency:CNY", "op:}}",
                        "metaKey:topup:", "keyword:TRUE"])
        XCTAssertEqual(pieces("* 2026\n; 备注", .beancount), ["comment:* 2026", "comment:; 备注"])
    }

    func testOnlyTheLinesAsked() {
        let t = "2026-01-01 open Assets:A CNY\n2026-01-02 open Assets:B CNY"
        let second = codeSpans(t, .beancount, in: NSRange(location: 30, length: 1))
        XCTAssertEqual(second.first, CodeSpan(29, 10, .date))
    }

    func testBQL() {
        XCTAssertEqual(pieces("SELECT account, sum(position) WHERE account ~ 'Expenses' AND date >= 2026-01-01 GROUP BY 1 -- 注释", .bql), [
            "keyword:SELECT", "function:sum", "keyword:WHERE", "op:~", "string:'Expenses'", "keyword:AND", "op:>=",
            "date:2026-01-01", "keyword:GROUP", "keyword:BY", "number:1", "comment:-- 注释",
        ])
        XCTAssertEqual(pieces("select payee from #entries limit 10", .bql), ["keyword:select", "keyword:from", "keyword:limit", "number:10"])
    }
}
