import XCTest
@testable import HoleKit

/// STL to and from CadSHAPE, Y up ↔ Z up, a piece of the room's mesh, and the AR clearance check.
final class ARMeshTests: XCTestCase {
    /// A 20 × 10 × 5 mm box, Z up, from 0.
    private func box() -> TriangleMesh {
        let v = [V3(0, 0, 0), V3(20, 0, 0), V3(20, 10, 0), V3(0, 10, 0), V3(0, 0, 5), V3(20, 0, 5), V3(20, 10, 5), V3(0, 10, 5)]
        let f: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return TriangleMesh(vertices: v, faces: f)
    }

    func testBinarySTLRoundTripKeepsSizeAndTriangles() throws {
        let data = binarySTL(box())
        XCTAssertEqual(data.count, 84 + 50 * 12)
        let back = try XCTUnwrap(parseBinarySTL(data))
        XCTAssertEqual(back.triangleCount, 12)
        XCTAssertEqual(back.size.x, 20, accuracy: 1e-4)
        XCTAssertEqual(back.size.y, 10, accuracy: 1e-4)
        XCTAssertEqual(back.size.z, 5, accuracy: 1e-4)
        XCTAssertNil(parseBinarySTL(Data(count: 40)))
    }

    func testDegenerateTrianglesAreLeftOut() {
        let m = TriangleMesh(vertices: [V3(0, 0, 0), V3(1, 0, 0), V3(2, 0, 0), V3(0, 1, 0)], faces: [0, 1, 2, 0, 1, 3])
        XCTAssertEqual(binarySTL(m).count, 84 + 50)
    }

    func testWorldYUpBecomesCadZUpInMillimetres() {
        // 1 cm up and 2 cm away from the camera's start (−Z) in ARKit.
        let p = worldToCad(V3(0.005, 0.01, -0.02))
        XCTAssertEqual(p.x, 5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 20, accuracy: 1e-9)
        XCTAssertEqual(p.z, 10, accuracy: 1e-9)
        let w = cadToWorld(p)
        XCTAssertEqual(w.x, 0.005, accuracy: 1e-12)
        XCTAssertEqual(w.y, 0.01, accuracy: 1e-12)
        XCTAssertEqual(w.z, -0.02, accuracy: 1e-12)
    }

    func testCropKeepsOnlyTrianglesNearTheCentre() {
        var v: [V3] = []
        var f: [UInt32] = []
        for k in 0..<10 {
            let x = Double(k) * 0.1
            let b = UInt32(v.count)
            v += [V3(x, 0, 0), V3(x + 0.01, 0, 0), V3(x, 0.01, 0)]
            f += [b, b + 1, b + 2]
        }
        let piece = crop(TriangleMesh(vertices: v, faces: f), centre: V3(0, 0, 0), radius: 0.25)
        XCTAssertEqual(piece.triangleCount, 3)
        XCTAssertEqual(piece.vertices.count, 9)
    }

    /// A wall 1 m in front of a camera at the origin looking along −Z (ARKit), flat LiDAR depth.
    private func wall(_ metres: Float = 1) -> (DepthMap, Intrinsics, CameraPose) {
        let dm = DepthMap(width: 64, height: 48, depth: [Float](repeating: metres, count: 64 * 48), confidence: nil)
        let K = Intrinsics(fx: 600, fy: 600, cx: 320, cy: 240)
        let pose = CameraPose(x: V3(1, 0, 0), y: V3(0, 1, 0), z: V3(0, 0, 1), position: V3(0, 0, 0))
        return (dm, K, pose)
    }

    func testCameraIsTheInverseOfWorld() {
        let pose = CameraPose(x: V3(0, 1, 0), y: V3(-1, 0, 0), z: V3(0, 0, 1), position: V3(0.2, 0.1, -0.3))
        let c = V3(0.05, -0.02, 0.8)
        let back = pose.camera(pose.world(c))
        XCTAssertEqual(back.x, c.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, c.y, accuracy: 1e-12)
        XCTAssertEqual(back.z, c.z, accuracy: 1e-12)
    }

    func testAPartInFrontOfTheWallHasAir() {
        let (dm, K, pose) = wall()
        let pts = [V3(0, 0, -0.99), V3(0.02, 0.01, -0.985)]
        let r = depthClearance(pts, depth: dm, intrinsics: K, imageWidth: 640, imageHeight: 480, pose: pose)
        XCTAssertEqual(r.checked, 2)
        XCTAssertEqual(r.hitMM, 0)
        XCTAssertEqual(try XCTUnwrap(r.gapMM), 10, accuracy: 0.01)
    }

    func testAPartIntoTheWallIsAHitButSomethingFarBehindIsHidden() {
        let (dm, K, pose) = wall()
        // 4 mm into the wall: a hit. 20 cm behind it: hidden behind the wall, not a hit.
        let pts = [V3(0, 0, -1.004), V3(0.01, 0, -1.2)]
        let r = depthClearance(pts, depth: dm, intrinsics: K, imageWidth: 640, imageHeight: 480, pose: pose)
        XCTAssertEqual(r.hitMM, 4, accuracy: 0.01)
        XCTAssertEqual(r.hits.count, 1)
        // Resting against it (within the LiDAR noise) is air 0, not a hit.
        let resting = depthClearance([V3(0, 0, -1.001)], depth: dm, intrinsics: K, imageWidth: 640, imageHeight: 480, pose: pose)
        XCTAssertEqual(resting.hitMM, 0)
        XCTAssertEqual(try XCTUnwrap(resting.gapMM), 0, accuracy: 0.01)
    }

    func testPointsOutOfViewAreNotChecked() {
        let (dm, K, pose) = wall()
        let r = depthClearance([V3(0, 0, 0.5), V3(5, 0, -1)], depth: dm, intrinsics: K, imageWidth: 640, imageHeight: 480, pose: pose)
        XCTAssertEqual(r.checked, 0)
        XCTAssertNil(r.gapMM)
    }

    func testCornerAngle() {
        XCTAssertEqual(cornerAngle(V3(0, 0, 1), V3(0, 1, 0)), 90, accuracy: 1e-9)
        XCTAssertEqual(cornerAngle(V3(0, 1, 0), V3(0, 1, 0)), 180, accuracy: 1e-9)
        XCTAssertEqual(cornerAngle(V3(0, 1, 0), V3(0, -1, 0)), 0, accuracy: 1e-6)
    }
}
