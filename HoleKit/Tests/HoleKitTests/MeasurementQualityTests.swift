import XCTest
@testable import HoleKit

final class MeasurementQualityTests: XCTestCase {
    private func measurement() -> FrameMeasurement {
        let points = (0..<72).map { P2(11.5 * cos(Double($0) * .pi / 36), 11.5 * sin(Double($0) * .pi / 36)) }
        var m = result(outlineGray: points, mm: points, plane: Plane(normal: V3(0, 0, 1), offset: 0.3), used: 120, source: .picture)
        m.edgeResolutionMM = 0.25
        m.edgePixels = 60
        m.planeResidualMM = 0.4
        m.planeInlierRatio = 0.95
        return m
    }

    func testGoodPictureMeasurementCanLockAfterEnoughFrames() {
        let m = measurement()
        XCTAssertFalse(measurementQuality(Array(repeating: m, count: 3), trackingNormal: true).canAutoLock)
        let q = measurementQuality(Array(repeating: m, count: 8), trackingNormal: true)
        XCTAssertTrue(q.canAutoLock)
        XCTAssertGreaterThanOrEqual(q.uncertaintyMM ?? 0, 0.3)
    }

    func testSteadyDepthBoundaryStillHasCoarseResolution() {
        var m = measurement()
        m.source = .depth
        m.edgeResolutionMM = 2
        let q = measurementQuality(Array(repeating: m, count: 8), trackingNormal: true)
        XCTAssertEqual(q.steadiness, 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(q.uncertaintyMM ?? 0, 4)
        XCTAssertFalse(q.canAutoLock, "Repeated depth pixels are not sub-mm accuracy")
    }

    func testTrackingTiltDistanceAndPixelSupportBlockAutomaticLock() {
        let m = measurement()
        XCTAssertFalse(measurementQuality(Array(repeating: m, count: 8), trackingNormal: false).canAutoLock)
        for change in [0, 1, 2, 3, 4, 5] {
            var bad = m
            switch change {
            case 0: bad.plane = Plane(normal: V3(1, 0, 1), offset: 0.3)
            case 1: bad.plane = Plane(normal: V3(0, 0, 1), offset: 1.4)
            case 2: bad.edgePixels = 14
            case 3: bad.planePoints = 0
            case 4: bad.planeInlierRatio = 0.4
            default: bad.usedSmoothedDepth = true
            }
            XCTAssertFalse(measurementQuality(Array(repeating: bad, count: 8), trackingNormal: true).canAutoLock, "bad measurement \(change)")
        }
    }

    func testEqualAreaButChangingDimensionsIsNotSteady() {
        let m = measurement()
        var changed = m
        changed.widthMM = m.widthMM * 1.4
        changed.heightMM = m.heightMM / 1.4
        let q = measurementQuality([m, changed, m, changed, m, changed, m, changed], trackingNormal: true)
        XCTAssertLessThan(q.steadiness, 0.85)
        XCTAssertFalse(q.canAutoLock)
    }

    func testControlDiameterAcceptsNorwegianDecimalsAndRejectsInvalidSizes() {
        XCTAssertEqual(controlDiameter(" 23,25 "), 23.25)
        XCTAssertEqual(controlDiameter("23.25"), 23.25)
        for value in ["", "0", "-23", "nan", "inf", "1001", "23 mm", "23,2,1"] {
            XCTAssertNil(controlDiameter(value), value)
        }
    }

    func testDiagnosticsSurviveSavingWithoutImagesOrCredentials() throws {
        let m = measurement(), q = measurementQuality(Array(repeating: m, count: 8), trackingNormal: true)
        let d = MeasurementDiagnostics(m, uncertaintyMM: q.uncertaintyMM)
        let decoded = try JSONDecoder().decode(MeasurementDiagnostics.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(decoded.widthMM, 23, accuracy: 1e-9)
        XCTAssertEqual(decoded.edgePixels, 60)
        XCTAssertEqual(decoded.source, "picture")
        XCTAssertEqual(decoded.planePoints, 120)
    }
}
