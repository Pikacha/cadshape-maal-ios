import XCTest
@testable import HoleKit

// The LiDAR box measurement on clouds closer to an iPhone's: noise mostly along the (near vertical)
// rays, walls hidden from view, flying pixels at the rim, clutter on the floor.

/// Normal-distributed noise from the repeatable `Noise`.
private func gaussian(_ r: inout Noise) -> Double {
    (-2 * log(max(1e-12, r.next()))).squareRoot() * cos(2 * .pi * r.next())
}

/// The inside of a box seen from above (as BoxTests' boxCloud): floor, walls, rim and the table
/// round it. `hideNear`: the camera is beyond the near (−y) wall, so its inner face is not seen,
/// and `ramp` rows of flying pixels hang from that rim's inner edge down towards the floor.
/// `block`: a thing this high (mm) on the floor 12–25 mm from the +x wall.
private func seenBox(w: Double, l: Double, h: Double, t: Double, turn: Double, noise: Double, noiseUp: Double,
                     hideNear: Bool = false, ramp: Int = 0, block: Double = 0, floorY: Double = 0.72) -> (pts: [V3], aim: V3) {
    var r = Noise(state: 7)
    var pts: [V3] = []
    let c = cos(turn * .pi / 180), s = sin(turn * .pi / 180)
    let centre = (0.03, -0.42)
    func add(_ x: Double, _ y: Double, _ z: Double) {
        let X = x + gaussian(&r) * noise, Y = y + gaussian(&r) * noise, Z = z + gaussian(&r) * noiseUp
        pts.append(V3(centre.0 + (X * c - Y * s) / 1000, floorY + Z / 1000, centre.1 + (X * s + Y * c) / 1000))
    }
    let hw = w / 2, hl = l / 2
    for x in stride(from: -hw, through: hw, by: 3) { for y in stride(from: -hl, through: hl, by: 3) { add(x, y, 0) } }
    for z in stride(from: 0.0, through: h, by: 3) {
        for x in stride(from: -hw, through: hw, by: 3) {
            add(x, hl, z)
            if !hideNear { add(x, -hl, z) }
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
    if block > 0 {
        for z in stride(from: 0.0, through: block, by: 2) {
            for x in stride(from: hw - 25, through: hw - 12, by: 2) { for y in stride(from: -10.0, through: 10, by: 2) { add(x, y, z) } }
        }
    }
    if ramp > 0 {
        for k in 1...ramp {
            let zz = h * (1 - Double(k) / Double(ramp + 1))
            for x in stride(from: -hw, to: hw, by: 2.5) { add(x, -hl + (h - zz) * 0.4, zz) }
        }
    }
    let aim = V3(centre.0 + (20 * c + 10 * s) / 1000, floorY, centre.1 + (20 * s - 10 * c) / 1000)
    return (pts, aim)
}

final class RealisticSpaceTests: XCTestCase {
    // MARK: The inside of a box

    func testBoxWithNoisyDepth() throws {
        let (pts, aim) = seenBox(w: 150, l: 100, h: 60, t: 3, turn: 25, noise: 1, noiseUp: 4)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 150, accuracy: 2.5)
        XCTAssertEqual(fit.length, 100, accuracy: 2.5)
        XCTAssertEqual(try XCTUnwrap(fit.height), 60, accuracy: 5)
    }

    func testBoxWithOnlyTheFarWallsSeen() throws {
        // From beyond the near wall: its inside is hidden, only its rim shows – and flying pixels
        // hang from that rim towards the floor.
        let (pts, aim) = seenBox(w: 150, l: 100, h: 60, t: 3, turn: 25, noise: 1.5, noiseUp: 1.5, hideNear: true, ramp: 4)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 150, accuracy: 2.5)
        XCTAssertEqual(fit.length, 100, accuracy: 3.5)
        XCTAssertEqual(try XCTUnwrap(fit.height), 60, accuracy: 3)
    }

    func testBoxWithAThingOnItsFloor() throws {
        // 15 mm high, 12 mm from a wall: not the wall.
        let (pts, aim) = seenBox(w: 150, l: 100, h: 60, t: 3, turn: 25, noise: 1.5, noiseUp: 1.5, block: 15)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 150, accuracy: 2)
        XCTAssertEqual(fit.length, 100, accuracy: 2)
    }

    func testShallowTray() throws {
        // Walls lower than 25 mm are still walls.
        let (pts, aim) = seenBox(w: 150, l: 100, h: 20, t: 2, turn: 10, noise: 1, noiseUp: 1)
        let fit = try XCTUnwrap(fitBox(pts, aim: aim, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 150, accuracy: 2)
        XCTAssertEqual(fit.length, 100, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(fit.height), 20, accuracy: 2.5)
    }

    // MARK: Dark and glossy things

    func testConfidentShare() {
        // The left half of the depth map is sure, the right half is not (a dark, glossy thing).
        let w = 64, h = 48
        var conf = [UInt8](repeating: 0, count: w * h)
        for j in 0..<h { for i in 0..<(w / 2) { conf[j * w + i] = 2 } }
        let dm = DepthMap(width: w, height: h, depth: [Float](repeating: 0.4, count: w * h), confidence: conf)
        XCTAssertEqual(confidentShare(dm, aroundPixel: 160, v: 240, imageWidth: 640, imageHeight: 480, radius: 8), 1, accuracy: 1e-9)
        XCTAssertEqual(confidentShare(dm, aroundPixel: 480, v: 240, imageWidth: 640, imageHeight: 480, radius: 8), 0, accuracy: 1e-9)
        XCTAssertEqual(confidentShare(dm, aroundPixel: 320, v: 240, imageWidth: 640, imageHeight: 480, radius: 8), 0.5, accuracy: 0.08)
        // No confidence map: all usable. Out of the picture: nothing.
        let plain = DepthMap(width: w, height: h, depth: [Float](repeating: 0.4, count: w * h), confidence: nil)
        XCTAssertEqual(confidentShare(plain, aroundPixel: 320, v: 240, imageWidth: 640, imageHeight: 480), 1, accuracy: 1e-9)
        XCTAssertEqual(confidentShare(plain, aroundPixel: -5000, v: 240, imageWidth: 640, imageHeight: 480), 0)
    }
}
