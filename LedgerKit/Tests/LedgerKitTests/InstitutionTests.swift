import XCTest
@testable import LedgerKit

final class InstitutionTests: XCTestCase {
    private func id(_ account: String, _ name: String? = nil) -> String? {
        institution(account: account, name: name)?.id
    }

    func testTheAccountsOwnNameFindsIt() {
        XCTAssertEqual(id("Assets:Bank:CMB"), "cmb")
        XCTAssertEqual(id("Assets:Bank:CN:ICBC:Savings"), "icbc")
        XCTAssertEqual(id("Liabilities:CreditCard:HSBC-Red"), "hsbc")
        XCTAssertEqual(id("Assets:EWallet:WeChat"), "wechat")
        XCTAssertEqual(id("Assets:EWallet:Octopus"), "octopus")
        XCTAssertEqual(id("Assets:Bank:HangSeng"), "hangseng")
        XCTAssertEqual(id("Assets:Bank:StandardChartered"), "sc")
        XCTAssertEqual(id("Liabilities:CreditCard:CGB-2"), "cgb")
        XCTAssertEqual(id("Liabilities:CreditCard:CEB"), "ceb")
        XCTAssertEqual(id("Liabilities:CreditCard:HXB"), "hxb")
        XCTAssertEqual(id("Assets:Bank:IFASTGB"), "ifast")
        XCTAssertEqual(id("Assets:Bank:N26"), "n26")
        // a wallet's own fund goes with its wallet
        XCTAssertEqual(id("Assets:EWallet:YuEBao"), "alipay")
        XCTAssertEqual(id("Assets:EWallet:MiniFund"), "wechat")
    }

    func testTheNameShownFindsItToo() {
        XCTAssertEqual(id("Assets:Bank:Main", "招商银行一卡通"), "cmb")
        XCTAssertEqual(id("Assets:EWallet:Change", "微信零钱"), "wechat")
        XCTAssertEqual(id("Assets:Bank:Salary", "Hang Seng Integrated"), "hangseng")
        XCTAssertEqual(id("Liabilities:CreditCard:Main", "广发信用卡"), "cgb")
        XCTAssertEqual(id("Liabilities:CreditCard:Main", "光大银行信用卡"), "ceb")
    }

    /// names that share a part go to the more specific one
    func testTheMoreSpecificNameWins() {
        XCTAssertEqual(id("Assets:EWallet:AlipayHK"), "alipayhk")
        XCTAssertEqual(id("Assets:EWallet:Alipay"), "alipay")
        XCTAssertEqual(id("Assets:EWallet:Main", "支付宝香港"), "alipayhk")
        XCTAssertEqual(id("Assets:Bank:Main", "中银香港"), "bochk")
        XCTAssertEqual(id("Assets:Bank:Main", "中国银行"), "boc")
        XCTAssertEqual(id("Assets:Bank:Main", "中国农业银行"), "abc")
        XCTAssertEqual(id("Assets:Bank:CITIC"), "citic")
        XCTAssertEqual(id("Assets:Bank:Citi"), "citi")
    }

    /// a Latin alias is a whole word: a name that only contains it is not that bank
    func testPartOfAWordIsNotAMatch() {
        XCTAssertNil(id("Assets:Bank:Moxie"))
        XCTAssertNil(id("Assets:Bank:Zara"))
        XCTAssertNil(id("Assets:Cash:Wallet"))
        // the group is not part of the name: Assets:Bank is not a bank called Bank
        XCTAssertNil(id("Assets:Bank"))
    }
}
