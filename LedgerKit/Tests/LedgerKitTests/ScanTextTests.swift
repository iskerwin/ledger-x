import XCTest
@testable import LedgerKit

/// pieces read off a screenshot, put back into the screen's rows
final class ScanTextTests: XCTestCase {
    func testRows() {
        let boxes = [
            OCRBox(text: "零钱", x: 0.70, y: 0.402, w: 0.10, h: 0.02),
            OCRBox(text: "-25.00", x: 0.40, y: 0.20, w: 0.20, h: 0.04),
            OCRBox(text: "付款方式", x: 0.06, y: 0.40, w: 0.15, h: 0.02),
            OCRBox(text: "支付时间", x: 0.06, y: 0.44, w: 0.15, h: 0.02),
            OCRBox(text: "2026年10月14日 12:03:11", x: 0.45, y: 0.441, w: 0.45, h: 0.02),
            OCRBox(text: "  ", x: 0.1, y: 0.5, w: 0.1, h: 0.02),
        ]
        XCTAssertEqual(ocrText(boxes), "-25.00\n付款方式\t零钱\n支付时间\t2026年10月14日 12:03:11")
    }
}
