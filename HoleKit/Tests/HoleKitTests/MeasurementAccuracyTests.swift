import XCTest
@testable import HoleKit

final class MeasurementAccuracyTests: XCTestCase {
    func testScatteredDepthMustNotInventAUsableWall() {
        var noise = Noise(state: 7349)
        let points = (0..<240).map { _ in V3((noise.next() - 0.5) * 0.4, (noise.next() - 0.5) * 0.4, 0.3 + noise.next() * 0.8) }
        XCTAssertNil(fitPlane(points), "A small chance consensus is not a measured wall")
    }

    func testCollinearDepthCannotDetermineWallTilt() {
        let points = (0..<100).map { V3(Double($0) / 1000, sin(Double($0)) * 1e-7, 0.5 + cos(Double($0)) * 1e-5) }
        XCTAssertNil(fitPlane(points), "A line cannot determine a surface normal")
    }

    func testSmall23mmHoleAtDifferentAngles() {
        for tilt in [0.0, 20.0, 35.0] {
            let scene = Scene(tiltDegrees: tilt, distance: 0.3, radius: 0.0115)
            let input = FrameInput(gray: scene.picture(), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
            guard case .success(let measurement) = measureFrame(input), let circle = fitCircle(measurement.outlineMM) else {
                return XCTFail("No small-hole measurement at tilt \(tilt)")
            }
            XCTAssertEqual(circle.radius * 2, 23, accuracy: 0.6, "tilt \(tilt)")
        }
    }

    func testSmallPictureHoleCarriesActualResolutionAndPlaneEvidence() {
        var scene = Scene(tiltDegrees: 0, distance: 0.3, radius: 0.0115)
        scene.K.fx = 1500
        scene.K.fy = 1500
        let input = FrameInput(gray: scene.picture(), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
        guard case .success(let m) = measureFrame(input) else { return XCTFail("no measurement") }
        XCTAssertGreaterThan(m.edgePixels, 48)
        XCTAssertGreaterThan(m.edgeResolutionMM, 0.3)
        XCTAssertLessThan(m.edgeResolutionMM, 0.5)
        XCTAssertGreaterThanOrEqual(m.planeInlierRatio, 0.6)
        XCTAssertLessThan(m.planeResidualMM, 3)
        XCTAssertTrue(measurementQuality(Array(repeating: m, count: 8), trackingNormal: true).canAutoLock)
    }

    func testDepthOnlySmallHoleCannotClaimSubMillimetrePrecision() {
        let scene = Scene(tiltDegrees: 0, distance: 0.3, radius: 0.0115)
        let input = FrameInput(gray: scene.picture(hole: 205, wall: 205), scale: 2, intrinsics: scene.K, depth: scene.depth(), fallbackPlane: nil, seed: scene.seed)
        guard case .success(let m) = measureFrame(input) else { return XCTFail("no depth measurement") }
        XCTAssertEqual(m.source, .depth)
        let q = measurementQuality(Array(repeating: m, count: 8), trackingNormal: true)
        XCTAssertFalse(q.canAutoLock)
        XCTAssertGreaterThan(q.uncertaintyMM ?? 0, 1)
    }
}
