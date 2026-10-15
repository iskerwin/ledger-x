import XCTest
@testable import LedgerKit

/// Every written transaction: Expenses / Income / Equity first, then the accounts that receive, then those that pay.
final class PostingOrderTests: XCTestCase {
    private func accounts(_ ps: [TxPosting]) -> [String] { orderedPostings(ps).map(\.account) }

    func testExpenseAndIncome() {
        XCTAssertEqual(accounts([TxPosting(account: "Assets:Bank", amount: -30, currency: "CNY"),
                                 TxPosting(account: "Expenses:Food", amount: 30, currency: "CNY")]),
                       ["Expenses:Food", "Assets:Bank"])
        XCTAssertEqual(accounts([TxPosting(account: "Assets:Bank", amount: 100, currency: "CNY"),
                                 TxPosting(account: "Income:Salary", amount: -100, currency: "CNY")]),
                       ["Income:Salary", "Assets:Bank"])
    }

    func testRepaymentAndTransfer() {
        // repayment: the card receives, the bank pays
        XCTAssertEqual(accounts([TxPosting(account: "Assets:Bank:BOC", amount: -500, currency: "CNY"),
                                 TxPosting(account: "Liabilities:Card:CEB", amount: 500, currency: "CNY")]),
                       ["Liabilities:Card:CEB", "Assets:Bank:BOC"])
        XCTAssertEqual(accounts([TxPosting(account: "Assets:A", amount: -1, currency: "CNY"),
                                 TxPosting(account: "Assets:B", amount: 1, currency: "CNY")]),
                       ["Assets:B", "Assets:A"])
    }

    func testCategoriesKeepTheirOrder() {
        XCTAssertEqual(accounts([TxPosting(account: "Assets:Bank", amount: -40, currency: "CNY"),
                                 TxPosting(account: "Expenses:B", amount: 10, currency: "CNY"),
                                 TxPosting(account: "Assets:Cash", amount: 5, currency: "CNY"),
                                 TxPosting(account: "Expenses:A", amount: 25, currency: "CNY")]),
                       ["Expenses:B", "Expenses:A", "Assets:Cash", "Assets:Bank"])
    }

    func testBlankAmountTakesItsFilledSign() {
        // the blank cash line pays for the stock and the fee
        let stock = TxPosting(account: "Assets:Broker:NVDA", units: "2", currency: "NVDA", cost: "120 USD")
        XCTAssertEqual(accounts([TxPosting(account: "Assets:Broker:Cash"),
                                 stock,
                                 TxPosting(account: "Expenses:Fee", amount: 1, currency: "USD")]),
                       ["Expenses:Fee", "Assets:Broker:NVDA", "Assets:Broker:Cash"])
        // selling: the blank cash line receives
        let sold = TxPosting(account: "Assets:Broker:NVDA", units: "-2", currency: "NVDA", cost: "{}")
        XCTAssertEqual(accounts([sold, TxPosting(account: "Assets:Broker:Cash", units: "250", currency: "USD"),
                                 TxPosting(account: "Income:Gains")]),
                       ["Income:Gains", "Assets:Broker:Cash", "Assets:Broker:NVDA"])
    }

    func testExchangeAtPrice() {
        // bought USD at a price; the blank CNY line pays
        XCTAssertEqual(accounts([TxPosting(account: "Assets:CNY"),
                                 TxPosting(account: "Assets:USD", units: "100", currency: "USD", price: "@ 7.1 CNY")]),
                       ["Assets:USD", "Assets:CNY"])
        var usd = TxPosting(account: "Assets:USD", units: "-100", currency: "USD")
        usd.priceTotal = 710; usd.priceCcy = "CNY"
        XCTAssertEqual(accounts([usd, TxPosting(account: "Assets:CNY")]), ["Assets:CNY", "Assets:USD"])
    }

    func testUnknownSignsLeaveTheOrder() {
        let expr = [TxPosting(account: "Assets:A", units: "(10 / 3)", currency: "CNY"),
                    TxPosting(account: "Assets:B")]
        XCTAssertEqual(accounts(expr), ["Assets:A", "Assets:B"])
        let twoBlank = [TxPosting(account: "Assets:A"), TxPosting(account: "Expenses:X", amount: 1, currency: "CNY"),
                        TxPosting(account: "Assets:B")]
        XCTAssertEqual(accounts(twoBlank), ["Assets:A", "Expenses:X", "Assets:B"])
    }

    func testMetadataMovesWithItsPosting() {
        var bank = TxPosting(account: "Assets:Bank", amount: -30, currency: "CNY")
        bank.meta = [("note", "x")]
        var tx = TxDraft(date: "2026-10-15")
        tx.narration = "午饭"
        tx.postings = [bank, TxPosting(account: "Expenses:Food", amount: 30, currency: "CNY")]
        let lines = formatTxn(tx).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasPrefix("  Expenses:Food"))
        XCTAssertTrue(lines[2].hasPrefix("  Assets:Bank"))
        XCTAssertEqual(lines[3], "    note: \"x\"")
    }
}
