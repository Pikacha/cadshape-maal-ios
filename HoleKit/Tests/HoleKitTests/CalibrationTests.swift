import XCTest
@testable import HoleKit

final class CalibrationTests: XCTestCase {
    func testLearnsScaleAndEdgeOffsetFromThePlate() {
        // A phone that measures 3 % too big and finds the edge 0.4 mm too far out on each side.
        let pairs = calibrationHolesMM.map { (measured: ($0 + 0.8) / 0.97, actual: $0) }
        guard case .success(let c) = fitHoleCalibration(pairs) else { return XCTFail("no calibration") }
        XCTAssertEqual(c.samples, 5)
        XCTAssertLessThan(c.rmsMM, 0.01)
        XCTAssertEqual(c.corrected((23 + 0.8) / 0.97), 23, accuracy: 0.01)
        XCTAssertEqual(c.corrected((50 + 0.8) / 0.97), 50, accuracy: 0.01)
    }

    func testCorrectedOutlineMakesTheCircleTheCorrectedDiameter() {
        let c = HoleCalibration(scale: 0.97, offsetMM: -0.8, samples: 5, rmsMM: 0.1)
        let d = 30.0
        let circle = (0..<200).map { k -> P2 in
            let a = Double(k) / 200 * 2 * .pi
            return P2(cos(a), sin(a)) * (d / 2) + P2(3, -2)
        }
        guard let fit = fitCircle(c.corrected(outline: circle)) else { return XCTFail("no circle") }
        XCTAssertEqual(fit.radius * 2, c.corrected(d), accuracy: 1e-6)
        XCTAssertEqual(fit.centre.x, 3, accuracy: 1e-6)
    }

    func testRefusesTooFewHoles() {
        XCTAssertEqual(fitHoleCalibration([(10, 10), (15, 15)]).failureValue, .tooFew)
    }

    func testRefusesAWrongHole() {
        // The 23 mm hole was measured on the 30 mm hole: the points no longer lie on a line.
        let pairs: [(measured: Double, actual: Double)] = [(10.1, 10), (15.1, 15), (30.2, 23), (30.1, 30), (40.2, 40)]
        guard case .failure = fitHoleCalibration(pairs) else { return XCTFail("a wrong hole must be refused") }
    }

    func testRefusesImplausibleScale() {
        let pairs = calibrationHolesMM.map { (measured: $0 * 1.5, actual: $0) }
        guard case .failure(.implausible) = fitHoleCalibration(pairs) else { return XCTFail("50 % off is not a calibration") }
    }

    func testCalibratedFrameIsAppliedOnce() {
        let scene = Scene(tiltDegrees: 0, distance: 0.4, radius: 0.015)
        let input = FrameInput(gray: scene.picture(), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
        guard case .success(let m) = measureFrame(input), let raw = measuredDiameter(m) else { return XCTFail("no hole") }
        let c = HoleCalibration(scale: 1.02, offsetMM: -0.5, samples: 5, rmsMM: 0.1)
        let once = calibrated(m, c)
        let twice = calibrated(once, c)
        XCTAssertTrue(once.calibrated)
        XCTAssertEqual(measuredDiameter(once)!, c.corrected(raw), accuracy: 0.05)
        XCTAssertEqual(measuredDiameter(twice)!, measuredDiameter(once)!, accuracy: 1e-9)
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
