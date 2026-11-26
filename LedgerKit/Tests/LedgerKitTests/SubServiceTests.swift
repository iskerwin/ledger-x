import XCTest
@testable import LedgerKit

final class SubServiceTests: XCTestCase {
    private func id(_ name: String, _ payee: String = "") -> String? { subService(name: name, payee: payee)?.id }

    func testTheNameFindsIt() {
        XCTAssertEqual(id("Netflix"), "netflix")
        XCTAssertEqual(id("Spotify Premium"), "spotify")
        XCTAssertEqual(id("iCloud+ 200GB"), "icloud")
        XCTAssertEqual(id("ChatGPT Plus"), "chatgpt")
        XCTAssertEqual(id("网易云音乐会员"), "neteasemusic")
        XCTAssertEqual(id("B站大会员"), "bilibili")
        XCTAssertEqual(id("京东PLUS"), "jd")
    }

    func testThePayeeFindsItWhenTheNameDoesNot() {
        XCTAssertEqual(id("云盘", "Apple"), "apple")
        XCTAssertEqual(id("视频会员", "爱奇艺"), "iqiyi")
    }

    /// the more specific service wins over the company behind it
    func testTheSpecificServiceBeforeItsCompany() {
        XCTAssertEqual(id("iCloud", "Apple"), "icloud")
        XCTAssertEqual(id("YouTube Premium", "Google"), "youtube")
        XCTAssertEqual(id("AppleMusic"), "applemusic")
    }

    /// a Latin alias is a whole word: Pineapple is no Apple, a 15-letter word is no GitHub
    func testALatinAliasIsAWholeWord() {
        XCTAssertNil(id("Pineapple Box"))
        XCTAssertNil(id("健身房"))
        XCTAssertNil(id("Gym", "Fitness Co"))
    }
}
