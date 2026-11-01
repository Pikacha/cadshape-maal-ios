import XCTest
@testable import HoleKit

final class FlyingPixelTests: XCTestCase {
    /// A row: table at 0.40 m, a thing on it at 0.34 m, and one mixed pixel in between.
    private func row(_ values: [Float]) -> DepthMap {
        DepthMap(width: values.count, height: 1, depth: values, confidence: nil)
    }

    func testMixedPixelBetweenThingAndTableIsDropped() {
        let dm = row([0.34, 0.34, 0.37, 0.40, 0.40])
        XCTAssertTrue(flying(dm, 2, 0, dm.depth[2]))
    }

    func testRealEdgePixelsStay() {
        let dm = row([0.34, 0.34, 0.40, 0.40])
        XCTAssertFalse(flying(dm, 1, 0, dm.depth[1]), "the thing's own edge")
        XCTAssertFalse(flying(dm, 2, 0, dm.depth[2]), "the table next to it")
    }

    func testSlantedWallStays() {
        // A box wall seen at a slant: ~1 cm deeper per pixel.
        let dm = row((0..<8).map { 0.40 + Float($0) * 0.01 })
        for i in 1..<7 { XCTAssertFalse(flying(dm, i, 0, dm.depth[i])) }
    }
}
