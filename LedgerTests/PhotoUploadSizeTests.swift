import XCTest
import UIKit
@testable import Ledger

/// A photo is attached at most 2000 pixels on its long side, whatever the screen's scale.
final class PhotoUploadSizeTests: XCTestCase {
    private func photo(width: CGFloat, height: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func pixels(_ data: Data?) throws -> CGSize {
        let image = try XCTUnwrap(data.flatMap(UIImage.init(data:))?.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    func testALargePhotoIsShrunkTo2000PixelsOnItsLongSide() async throws {
        let size = try pixels(await jpegForUpload(photo(width: 4000, height: 3000, scale: 1)))
        XCTAssertEqual(size, CGSize(width: 2000, height: 1500))
    }

    func testAPhotoAtScreenScaleCountsItsPixelsNotPoints() async throws {
        // 1000 × 500 points at 3× is 3000 × 1500 pixels
        let size = try pixels(await jpegForUpload(photo(width: 1000, height: 500, scale: 3)))
        XCTAssertEqual(size, CGSize(width: 2000, height: 1000))
    }

    func testASmallPhotoKeepsItsSize() async throws {
        let size = try pixels(await jpegForUpload(photo(width: 800, height: 600, scale: 1)))
        XCTAssertEqual(size, CGSize(width: 800, height: 600))
    }
}
