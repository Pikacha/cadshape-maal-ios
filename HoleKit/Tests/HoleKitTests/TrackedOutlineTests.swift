import XCTest
@testable import HoleKit

final class TrackedOutlineTests: XCTestCase {
    let lens = Intrinsics(fx: 1000, fy: 1000, cx: 320, cy: 240)
    let original = CameraPose(x: V3(1, 0, 0), y: V3(0, 1, 0), z: V3(0, 0, 1), position: V3(0, 0, 0))

    func measurement() -> FrameMeasurement {
        FrameMeasurement(outline: [P2(150, 110), P2(170, 110), P2(170, 130), P2(150, 130)],
            outlineMM: [], plane: Plane(normal: V3(0, 0, 1), offset: 0.5), planePoints: 100,
            centroid: P2(160, 120), sizeMM: 20, widthMM: 20, heightMM: 20, source: .picture)
    }

    func testOutlineFollowsCurrentCameraInsteadOfOldImage() {
        var outline = TrackedHoleOutline()
        outline.update(measurement(), intrinsics: lens, scale: 2, pose: original, timestamp: 10)
        var moved = original
        moved.position.x = 0.01
        let points = outline.projected(intrinsics: lens, pose: moved, timestamp: 10.1)
        XCTAssertEqual(points.count, 4)
        // 1 cm translation at 50 cm and fx=1000 moves the image 20 pixels left.
        XCTAssertEqual(points.first?.x ?? 0, 280, accuracy: 0.001)
        XCTAssertEqual(points.first?.y ?? 0, 220, accuracy: 0.001)
    }

    func testSameCameraPreservesFullResolutionPixelCoordinates() {
        var outline = TrackedHoleOutline()
        outline.update(measurement(), intrinsics: lens, scale: 2, pose: original, timestamp: 10)
        let points = outline.projected(intrinsics: lens, pose: original, timestamp: 10)
        XCTAssertEqual(points.first?.x ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(points.last?.y ?? 0, 260, accuracy: 0.001)
    }

    func testOneMissedFrameKeepsTheHoleButALostHoleGoes() {
        var outline = TrackedHoleOutline()
        outline.update(measurement(), intrinsics: lens, scale: 2, pose: original, timestamp: 10)
        outline.update(nil, intrinsics: lens, scale: 2, pose: original, timestamp: 10.12)
        XCTAssertEqual(outline.projected(intrinsics: lens, pose: original, timestamp: 10.12).count, 4, "one blurry frame must not blink the circle off")
        outline.update(nil, intrinsics: lens, scale: 2, pose: original, timestamp: 10.24)
        outline.update(nil, intrinsics: lens, scale: 2, pose: original, timestamp: 10.36)
        XCTAssertTrue(outline.projected(intrinsics: lens, pose: original, timestamp: 10.36).isEmpty)
    }

    func testStalledAnalysisDoesNotLeavePhantomOutline() {
        var outline = TrackedHoleOutline()
        outline.update(measurement(), intrinsics: lens, scale: 2, pose: original, timestamp: 10)
        XCTAssertTrue(outline.projected(intrinsics: lens, pose: original, timestamp: 11).isEmpty)
        XCTAssertTrue(outline.projected(intrinsics: lens, pose: original, timestamp: 9).isEmpty)
    }

    func testOutlineBehindCameraIsHiddenEntirely() {
        var outline = TrackedHoleOutline()
        outline.update(measurement(), intrinsics: lens, scale: 2, pose: original, timestamp: 10)
        var turned = original
        turned.x = V3(-1, 0, 0)
        turned.z = V3(0, 0, -1)
        XCTAssertTrue(outline.projected(intrinsics: lens, pose: turned, timestamp: 10.1).isEmpty)
    }
}
