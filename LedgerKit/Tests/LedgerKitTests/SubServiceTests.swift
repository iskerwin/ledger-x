import XCTest
@testable import LedgerKit

final class SubServiceTests: XCTestCase {
    private func id(_ name: String, _ payee: String = "") -> String? { subService(name: name, payee: payee)?.id }

    func testTheNameFindsIt() {
        XCTAssertEqual(id("Apple iCloud+"), "icloud")
        XCTAssertEqual(id("ChatGPT Plus"), "chatgpt")
        XCTAssertEqual(id("Claude Pro"), "claude")
        XCTAssertEqual(id("𝕏 Premium"), "x")
        XCTAssertEqual(id("𝕏"), "x")
        XCTAssertEqual(id("Cloudflare"), "cloudflare")
        XCTAssertEqual(id("示例机场订阅"), "proxy")
    }

    func testThePayeeFindsItWhenTheNameDoesNot() {
        XCTAssertEqual(id("Plus", "OpenAI"), "chatgpt")
        XCTAssertEqual(id("Pro", "Anthropic"), "claude")
        XCTAssertEqual(id("手机月费", "Vodafone"), "vodafone")
    }

    /// the plan's own name wins over where it is bought: a Grok plan paid to 𝕏, a phone plan bought on eBay
    func testTheNameWinsOverThePayee() {
        XCTAssertEqual(id("Grok Bot", "𝕏"), "grok")
        XCTAssertEqual(id("Red Pocket", "eBay"), "redpocket")
        XCTAssertEqual(id("iCloud+", "Apple"), "icloud")
    }

    /// a Latin alias is a whole word, and a plain X is not 𝕏
    func testALatinAliasIsAWholeWord() {
        XCTAssertNil(id("Xbox"))
        XCTAssertNil(id("Box", "X Studio"))
        XCTAssertNil(id("健身房"))
        XCTAssertNil(id("Groceries", "Ebayside Market"))
    }
}
