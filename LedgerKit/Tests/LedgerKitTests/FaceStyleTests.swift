import XCTest
@testable import LedgerKit

final class FaceStyleTests: XCTestCase {
    /// a 4×4 image: `bg` everywhere, `fg` in the middle 2×2
    private func image(bg: [UInt8], fg: [UInt8]) -> [UInt8] {
        (0..<16).flatMap { i -> [UInt8] in
            let x = i % 4, y = i / 4
            return (1...2).contains(x) && (1...2).contains(y) ? fg : bg
        }
    }

    func testAnOpaqueBackgroundIsTakenFromTheCorners() {
        let a = silhouette(rgba: image(bg: [255, 255, 255, 255], fg: [200, 0, 20, 255]), width: 4, height: 4, strength: 0.3)
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a[0], 0, "a corner is background")
        XCTAssertEqual(a[5], 255, "the middle is the shape")
        XCTAssertEqual(a.filter { $0 == 0 }.count, 12)
    }

    func testATransparentBackgroundKeepsItsOwnAlpha() {
        let a = silhouette(rgba: image(bg: [255, 255, 255, 0], fg: [255, 255, 255, 180]), width: 4, height: 4, strength: 0.9)
        XCTAssertEqual(a[0], 0)
        // a white shape on a transparent background is still the shape, whatever the strength
        XCTAssertEqual(a[5], 180)
    }

    /// a pale shape on white: kept at a low strength, lifted with the background at a high one
    func testStrengthDecidesHowCloseToTheBackgroundStillCounts() {
        let rgba = image(bg: [255, 255, 255, 255], fg: [215, 215, 215, 255])
        XCTAssertEqual(silhouette(rgba: rgba, width: 4, height: 4, strength: 0.1)[5], 255)
        XCTAssertEqual(silhouette(rgba: rgba, width: 4, height: 4, strength: 0.6)[5], 0)
    }

    func testABrokenImageGivesNothing() {
        XCTAssertEqual(silhouette(rgba: [0, 0, 0], width: 4, height: 4, strength: 0.3), [])
    }

    func testAnEmptyStyleIsTheAutomaticCardAndReadsBackWhole() throws {
        XCTAssertTrue(FaceStyle().isEmpty)
        var s = FaceStyle()
        s.institution = "hsbc"
        s.pattern = FacePatternKind.dots.rawValue
        s.mark = .text("测")
        s.icon = "a.png"
        s.iconMono = false
        s.size = 1.2
        XCTAssertFalse(s.isEmpty)
        let back = try JSONDecoder().decode(FaceStyle.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(try JSONDecoder().decode(FaceStyle.self, from: Data("{}".utf8)), FaceStyle())
    }

    /// a built-in icon is kept by its institution's id, beside a style saved before there were any
    func testABuiltInIconReadsBackWithOlderStyles() throws {
        var s = FaceStyle()
        s.mark = .symbol("hsbc")
        XCTAssertEqual(try JSONDecoder().decode(FaceStyle.self, from: JSONEncoder().encode(s)).mark, .symbol("hsbc"))
        var old = FaceStyle()
        old.mark = .icon
        old.icon = "a.png"
        let saved = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(FaceStyle.self, from: saved), old)
    }

    func testARenamedAccountKeepsItsCard() {
        var a = FaceStyle(); a.mark = .off
        var b = FaceStyle(); b.pattern = "grid"
        let moved = renamedFaceStyles(["Assets:Bank:Old": a, "Assets:Bank:Old:Sub": b, "Assets:Cash": FaceStyle()], from: "Assets:Bank:Old", to: "Assets:Bank:New")
        XCTAssertEqual(moved["Assets:Bank:New"], a)
        XCTAssertEqual(moved["Assets:Bank:New:Sub"], b)
        XCTAssertNil(moved["Assets:Bank:Old"])
        XCTAssertNotNil(moved["Assets:Cash"])
        // merged into an account that has its own: that one stays
        let merged = renamedFaceStyles(["Assets:Bank:Old": a, "Assets:Bank:New": b], from: "Assets:Bank:Old", to: "Assets:Bank:New")
        XCTAssertEqual(merged, ["Assets:Bank:New": b])
    }
}
