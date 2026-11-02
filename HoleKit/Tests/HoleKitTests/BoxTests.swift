import XCTest
@testable import HoleKit

/// Normal-distributed noise from the repeatable `Noise`.
private func gauss(_ r: inout Noise) -> Double {
    (-2 * log(max(1e-12, r.next()))).squareRoot() * cos(2 * .pi * r.next())
}

/// A box seen from above (as the TypeScript tests, tests/box-synth.ts): floor, inner walls, rim,
/// and the table round it, in ARKit's world (m, y up).
private func boxCloud(w: Double, l: Double, h: Double, t: Double, turn: Double, noise: Double, clutter: Int, floorY: Double) -> (pts: [V3], aim: V3) {
    var r = Noise(state: 7)
    var pts: [V3] = []
    let c = cos(turn * .pi / 180), s = sin(turn * .pi / 180)
    let centre = (0.03, -0.42)
    func add(_ x: Double, _ y: Double, _ z: Double) {
        let X = x + gauss(&r) * noise, Y = y + gauss(&r) * noise, Z = z + gauss(&r) * noise
        pts.append(V3(centre.0 + (X * c - Y * s) / 1000, floorY + Z / 1000, centre.1 + (X * s + Y * c) / 1000))
    }
    let hw = w / 2, hl = l / 2
    for x in stride(from: -hw, through: hw, by: 3) { for y in stride(from: -hl, through: hl, by: 3) { add(x, y, 0) } }
    for z in stride(from: 0.0, through: h, by: 3) {
        for x in stride(from: -hw, through: hw, by: 3) {
            add(x, -hl, z)
            add(x, hl, z)
        }
        for y in stride(from: -hl, through: hl, by: 3) {
            add(-hw, y, z)
            add(hw, y, z)
        }
    }
    for x in stride(from: -hw - t, through: hw + t, by: 1.5) {
        for y in stride(from: -hl - t, through: hl + t, by: 1.5) where abs(x) > hw || abs(y) > hl { add(x, y, h) }
    }
    for x in stride(from: -hw - 100, through: hw + 100, by: 4) {
        for y in stride(from: -hl - 100, through: hl + 100, by: 4) where abs(x) > hw + t || abs(y) > hl + t { add(x, y, -2) }
    }
    for _ in 0..<clutter { add((r.next() - 0.5) * w * 0.9, (r.next() - 0.5) * l * 0.9, r.next() * h) }
    let aim = V3(centre.0 + (20 * c + 10 * s) / 1000, floorY, centre.1 + (20 * s - 10 * c) / 1000)
    return (pts, aim)
}

final class BoxTests: XCTestCase {
    func testInsideOfATurnedBox() throws {
        let (pts, aim) = boxCloud(w: 150, l: 100, h: 60, t: 3, turn: 25, noise: 1.5, clutter: 150, floorY: 0.72)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 150, accuracy: 2)
        XCTAssertEqual(fit.length, 100, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(fit.height), 60, accuracy: 2.5)
        XCTAssertEqual(try XCTUnwrap(fit.wall), 3, accuracy: 1.5)
        XCTAssertTrue(fit.allWallsSeen)
        XCTAssertLessThan(fit.spread, 4)
    }

    func testWidthIsAcrossTheView() throws {
        let (pts, aim) = boxCloud(w: 150, l: 100, h: 40, t: 2, turn: -70, noise: 1, clutter: 0, floorY: 0.5)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(0, 0, 1)))
        XCTAssertEqual(fit.width, 150, accuracy: 2)
        XCTAssertEqual(fit.length, 100, accuracy: 2)
    }

    func testSmallDeepBox() throws {
        let (pts, aim) = boxCloud(w: 60, l: 45, h: 70, t: 1.5, turn: 5, noise: 1, clutter: 20, floorY: 0.3)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 60, accuracy: 2)
        XCTAssertEqual(fit.length, 45, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(fit.height), 70, accuracy: 2.5)
    }

    func testNoFloorUnderTheCrossHair() {
        let (pts, _) = boxCloud(w: 100, l: 100, h: 30, t: 2, turn: 0, noise: 1, clutter: 0, floorY: 0.5)
        XCTAssertNil(fitBox(pts, aim: V3(5, 5, 5)))
    }

    func testCloudFromDepthGoesToTheWorld() throws {
        // A flat floor 0.5 m below a camera looking straight down (ARKit: camera −z = world −y).
        let K = Intrinsics(fx: 100, fy: 100, cx: 64, cy: 48)
        let dm = DepthMap(width: 128, height: 96, depth: [Float](repeating: 0.5, count: 128 * 96), confidence: nil)
        let pose = CameraPose(x: V3(1, 0, 0), y: V3(0, 0, -1), z: V3(0, 1, 0), position: V3(0, 1, 0))
        let pts = cloudPoints(dm, intrinsics: K, imageWidth: 128, imageHeight: 96, pose: pose)
        XCTAssertEqual(pts.count, 64 * 48)
        for p in pts { XCTAssertEqual(p.y, 0.5, accuracy: 1e-9) }
        let centre = try XCTUnwrap(pointAt(dm, intrinsics: K, imageWidth: 128, imageHeight: 96, pose: pose, u: 64, v: 48))
        XCTAssertEqual(centre.x, 0, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(centre.z, 0, accuracy: 1e-9)
    }
}
