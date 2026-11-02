import XCTest
@testable import HoleKit

final class ScanScaleTests: XCTestCase {
    private func bottle() -> ScanShapes {
        var body = ScanPart(kind: .cylinder, z0: 0, z1: 59.9)
        body.d = 37.9
        body.spread = 0.2
        var cap = ScanPart(kind: .cylinder, z0: 59.9, z1: 77.2)
        cap.d = 39.3
        return ScanShapes(parts: [body, cap], height: 77.2, explained: 1)
    }

    func testOneCaliperMeasureScalesEverything() throws {
        let s = bottle()
        // The calipers say the body is Ø37,4: the scan was 1,3 % too big.
        let f = try XCTUnwrap(scaleFactor(measured: s.parts[0].d, truth: 37.4))
        let t = s.scaled(by: f)
        XCTAssertEqual(t.parts[0].d, 37.4, accuracy: 1e-9)
        XCTAssertEqual(t.parts[1].d, 38.8, accuracy: 0.05)
        XCTAssertEqual(t.parts[0].height, 59.1, accuracy: 0.05)
        XCTAssertEqual(t.height, 76.2, accuracy: 0.05)
    }

    func testTypoIsRefused() {
        XCTAssertNil(scaleFactor(measured: 37.9, truth: 3.74))
        XCTAssertNil(scaleFactor(measured: 37.9, truth: 59))
    }

    func testPlusMinusShrinksWithBetterScale() {
        let p = bottle().parts[0]
        let tracking = p.plusMinus(.diameter, scale: .tracking)
        let measured = p.plusMinus(.diameter, scale: .measured)
        XCTAssertGreaterThan(tracking, 0.5) // 1,5 % of 37,9 ≈ 0,57
        XCTAssertLessThan(measured, 0.25)
        XCTAssertEqual(plusMinusText(0.04), "±0,1")
    }

    func testPhoneScaleIsTheMedianAndIgnoresOneBadCorrection() {
        var ph = PhoneScale()
        ph.add(0.987)
        XCTAssertNil(ph.factor)
        ph.add(0.989)
        ph.add(0.988)
        ph.add(1.05) // a wrong side measured once
        XCTAssertEqual(ph.factor!, 0.9885, accuracy: 0.001)
        XCTAssertLessThan(ph.spread!, 0.01)
        for _ in 0..<20 { ph.add(0.99) }
        XCTAssertEqual(ph.samples.count, 12)
    }
}
