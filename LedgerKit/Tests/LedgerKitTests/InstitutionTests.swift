import XCTest
@testable import LedgerKit

final class InstitutionTests: XCTestCase {
    private func id(_ account: String, _ name: String? = nil) -> String? {
        institution(account: account, name: name)?.id
    }

    func testTheAccountsOwnNameFindsIt() {
        XCTAssertEqual(id("Assets:Bank:CMB"), "cmb")
        XCTAssertEqual(id("Liabilities:CreditCard:HSBC-Red"), "hsbc")
        XCTAssertEqual(id("Assets:EWallet:WeChat"), "wechat")
        XCTAssertEqual(id("Assets:EWallet:Octopus"), "octopus")
        XCTAssertEqual(id("Liabilities:CreditCard:CGB-2"), "cgb")
        XCTAssertEqual(id("Liabilities:CreditCard:CEB"), "ceb")
        XCTAssertEqual(id("Liabilities:CreditCard:HXB"), "hxb")
        XCTAssertEqual(id("Assets:Bank:IFASTGB"), "ifast")
        XCTAssertEqual(id("Assets:Bank:N26"), "n26")
        // a wallet's own fund goes with its wallet
        XCTAssertEqual(id("Assets:EWallet:YuEBao"), "alipay")
        XCTAssertEqual(id("Assets:EWallet:MiniFund"), "wechat")
        // brokers, crypto and public funds, by the words of their own names
        XCTAssertEqual(id("Assets:Brokerage:IBKR:Stock"), "ibkr")
        XCTAssertEqual(id("Assets:Brokerage:Schwab:Cash"), "schwab")
        XCTAssertEqual(id("Assets:Brokerage:FSMone:Cash"), "fsmone")
        XCTAssertEqual(id("Assets:Crypto:OKX"), "okx")
        XCTAssertEqual(id("Assets:Crypto:PlasmaOne"), "plasma")
        XCTAssertEqual(id("Assets:Government:HousingFund"), "housingfund")
        XCTAssertEqual(id("Assets:Government:MedicalInsurance"), "medical")
        XCTAssertEqual(id("Assets:Government:Pension"), "pension")
    }

    func testTheNameShownFindsItToo() {
        XCTAssertEqual(id("Assets:Bank:Main", "招商银行一卡通"), "cmb")
        XCTAssertEqual(id("Assets:EWallet:Change", "微信零钱"), "wechat")
        XCTAssertEqual(id("Liabilities:CreditCard:Main", "广发信用卡"), "cgb")
        XCTAssertEqual(id("Liabilities:CreditCard:Main", "光大银行信用卡"), "ceb")
        XCTAssertEqual(id("Assets:Government:Fund", "住房公积金"), "housingfund")
    }

    /// names that share a part go to the more specific one
    func testTheMoreSpecificNameWins() {
        XCTAssertEqual(id("Assets:EWallet:Alipay"), "alipay")
        XCTAssertEqual(id("Assets:Bank:Main", "中银香港"), "bochk")
        XCTAssertEqual(id("Assets:Bank:Main", "中国银行"), "boc")
        XCTAssertEqual(id("Assets:Bank:CITIC"), "citic")
        // the banks no longer recognised (a card in its group's colour)
        XCTAssertNil(id("Assets:Bank:ICBC"))
        XCTAssertNil(id("Assets:EWallet:Revolut"))
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
