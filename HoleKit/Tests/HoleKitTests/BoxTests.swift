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

/// An oval lying on a table, a second thing further away, and optionally a tab on the far side
/// (world −z: away from a camera that looks along −z).
private func objectCloud(a: Double, b: Double, h: Double, noise: Double, tab: Bool = false) -> [V3] {
    var r = Noise(state: 3)
    var pts: [V3] = []
    func add(_ x: Double, _ y: Double, _ z: Double) {
        pts.append(V3((x + gauss(&r) * noise) / 1000, 0.8 + (z + gauss(&r) * noise) / 1000, (y + gauss(&r) * noise) / 1000))
    }
    func inside(_ x: Double, _ y: Double) -> Bool {
        pow(x / (a / 2), 2) + pow(y / (b / 2), 2) <= 1 || (tab && x > 5 && x < 25 && y < 0 && y > -b / 2 - 15)
    }
    for x in stride(from: -250.0, through: 250, by: 2) {
        for y in stride(from: -250.0, through: 250, by: 2) {
            if inside(x, y) { add(x, y, h) } else if abs(x - 120) < 15 && abs(y - 60) < 15 { add(x, y, 20) } else { add(x, y, 0) }
        }
    }
    for t in stride(from: 0.0, to: 2 * .pi, by: 0.01) {
        for z in stride(from: 0.0, to: h, by: 2) { add(cos(t) * a / 2, sin(t) * b / 2, z) }
    }
    return pts
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

    func testObjectOnATable() throws {
        let pts = objectCloud(a: 80, b: 40, h: 12, noise: 1)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.812, 0), right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 80, accuracy: 4)
        XCTAssertEqual(fit.length, 40, accuracy: 4)
        XCTAssertEqual(fit.height, 12, accuracy: 2)
        let want = Double.pi * 40 * 20
        XCTAssertLessThan(abs(loopArea(fit.outline) - want) / want, 0.12)
        XCTAssertEqual(fit.outline.count, fit.outlineWorld.count)
    }

    func testObjectTheRightWayRound() throws {
        let pts = objectCloud(a: 80, b: 40, h: 12, noise: 1, tab: true)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0, 0.812, 0), right: V3(1, 0, 0)))
        let far = try XCTUnwrap(fit.outline.max { $0.y < $1.y })
        XCTAssertGreaterThan(far.y, 10)
        XCTAssertGreaterThan(far.x, 0)
        XCTAssertGreaterThan(fit.length, 50)
    }

    func testNothingUnderTheCrossHair() {
        let pts = objectCloud(a: 80, b: 40, h: 12, noise: 1)
        XCTAssertNil(fitObject(pts, aim: V3(-0.15, 0.8, -0.15)))
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

/// The visible half of a pipe and a wall 3 cm behind it (as tests/box-synth.ts pipeCloud).
private func pipeCloud(d: Double, turn: Double, tilt: Double, noise: Double, wall: Bool) -> (pts: [V3], aim: V3) {
    var r = Noise(state: 11)
    var pts: [V3] = []
    let t = turn * .pi / 180, k = tilt * .pi / 180
    let axis = V3(cos(t) * cos(k), sin(k), sin(t) * cos(k))
    let side = vnormalized(V3(-axis.z, 0, axis.x))
    let upish = vcross(axis, side)
    let c = V3(0.02, 0.5, -0.3)
    let R = d / 2000
    var s = -0.08
    while s <= 0.08 {
        var a = -Double.pi * 0.45
        while a <= Double.pi * 0.45 {
            let p = c + axis * s + upish * (cos(a) * R) + side * (sin(a) * R)
            pts.append(p + V3(gauss(&r), gauss(&r), gauss(&r)) * (noise / 1000))
            a += 0.04
        }
        s += 0.0015
    }
    if wall {
        for x in stride(from: -0.1, through: 0.1, by: 0.003) {
            for z in stride(from: -0.1, through: 0.1, by: 0.003) { pts.append(V3(c.x + x, c.y - R - 0.03 + gauss(&r) * noise / 1000, c.z + z)) }
        }
    }
    return (pts, c + upish * R)
}

/// The camera picture of the oval on the table, looking down from `height` m (as objectPicture).
private func objectPicture(a: Double, b: Double, h: Double, height: Double, offset: (Double, Double)) -> (gray: GrayImage, K: Intrinsics, pose: CameraPose) {
    let W = 480, Hh = 360
    let scale = 2.0
    let K = Intrinsics(fx: 700, fy: 700, cx: Double(W) * scale / 2, cy: Double(Hh) * scale / 2)
    let pose = CameraPose(x: V3(1, 0, 0), y: V3(0, 0, -1), z: V3(0, 1, 0), position: V3(offset.0, 0.8 + height, offset.1))
    func inside(_ x: Double, _ z: Double) -> Bool { pow(x / (a / 2000), 2) + pow(z / (b / 2000), 2) <= 1 }
    var px = [UInt8](repeating: 0, count: W * Hh)
    let SS = 3
    for j in 0..<Hh {
        for i in 0..<W {
            var sum = 0
            for sj in 0..<SS {
                for si in 0..<SS {
                    let u = (Double(i) + (Double(si) + 0.5) / Double(SS)) * scale
                    let v = (Double(j) + (Double(sj) + 0.5) / Double(SS)) * scale
                    let rx = (u - K.cx) / K.fx, rz = (v - K.cy) / K.fy
                    func at(_ yy: Double) -> (Double, Double) {
                        let tt = pose.position.y - yy
                        return (pose.position.x + rx * tt, pose.position.z + rz * tt)
                    }
                    let top = at(0.8 + h / 1000), floor = at(0.8)
                    var dark = inside(top.0, top.1)
                    var f = 0.0
                    while !dark && f <= 1 {
                        dark = inside(top.0 + (floor.0 - top.0) * f, top.1 + (floor.1 - top.1) * f)
                        f += 0.1
                    }
                    sum += dark ? 55 : 205
                }
            }
            px[j * W + i] = UInt8(sum / (SS * SS))
        }
    }
    return (GrayImage(width: W, height: Hh, pixels: px), K, pose)
}

final class SpaceMoreTests: XCTestCase {
    func testPipeDiameters() throws {
        for (d, turn, tilt) in [(32.0, 30.0, 0.0), (20, -60, 15), (110, 10, 5)] {
            let (pts, aim) = pipeCloud(d: d, turn: turn, tilt: tilt, noise: 1, wall: true)
            let fit = try XCTUnwrap(fitCylinder(pts, aim: aim, reach: d > 60 ? 0.07 : 0.05))
            XCTAssertEqual(fit.diameter, d, accuracy: d > 60 ? 3 : 1.5)
            let t = turn * .pi / 180, k = tilt * .pi / 180
            let axis = V3(cos(t) * cos(k), sin(k), sin(t) * cos(k))
            XCTAssertGreaterThan(abs(vdot(fit.axis, axis)), 0.99)
        }
    }

    func testGapBetweenTwoSurfaces() throws {
        // A floor, and a board 6 mm above it tilted 3° (as under a furniture foot).
        var pts: [V3] = []
        var r = Noise(state: 5)
        for x in stride(from: -0.05, through: 0.05, by: 0.004) {
            for z in stride(from: -0.05, through: 0.05, by: 0.004) {
                pts.append(V3(x, 0.3 + gauss(&r) * 0.0005, z))
                pts.append(V3(x + 0.3, 0.306 + x * tan(3 * .pi / 180) + gauss(&r) * 0.0005, z))
            }
        }
        let a = try XCTUnwrap(surfaceNear(pts, at: V3(0, 0.3, 0)))
        let b = try XCTUnwrap(surfaceNear(pts, at: V3(0.3, 0.306, 0)))
        let g = gapBetween(a, b)
        XCTAssertEqual(g.gapMM, 6, accuracy: 0.3)
        XCTAssertEqual(g.angle, 3, accuracy: 0.5)
    }

    func testSurfaceNormalAtADistantGapPoint() throws {
        // The selected floor patch is small; a 300 mm extrapolation must not turn
        // sub-mm depth noise into avoidable tilt error. The whole-cloud fit is
        // the reference: even it retains finite sample noise.
        var pts: [V3] = []
        var r = Noise(state: 5)
        for x in stride(from: -0.05, through: 0.05, by: 0.004) {
            for z in stride(from: -0.05, through: 0.05, by: 0.004) {
                pts.append(V3(x, 0.3 + gauss(&r) * 0.0005, z))
                _ = gauss(&r) // Match the noise sequence of the two-surface regression.
            }
        }
        let a = try XCTUnwrap(surfaceNear(pts, at: V3(0, 0.3, 0)))
        let b = (plane: Plane(normal: V3(0, 1, 0), offset: 0.306), point: V3(0.3, 0.306, 0))
        let reference = (plane: try XCTUnwrap(leastSquaresPlane(pts)), point: V3(0, 0.3, 0))
        XCTAssertEqual(gapBetween(a, b).gapMM, gapBetween(reference, b).gapMM, accuracy: 0.1)
    }

    func testSurfaceExpansionDoesNotBlendAnAdjacentStep() throws {
        var pts: [V3] = []
        var r = Noise(state: 17)
        for x in stride(from: -0.06, through: 0.06, by: 0.002) {
            for z in stride(from: -0.06, through: 0.06, by: 0.002) {
                pts.append(V3(x, (x > 0.02 ? 0.306 : 0.3) + gauss(&r) * 0.0003, z))
            }
        }
        let a = try XCTUnwrap(surfaceNear(pts, at: V3(0, 0.3, 0), reach: 0.015))
        let b = (plane: Plane(normal: V3(0, 1, 0), offset: 0.306), point: V3(0.03, 0.306, 0))
        XCTAssertEqual(gapBetween(a, b).gapMM, 6, accuracy: 0.2)
    }

    func testSharperEdgeFromThePicture() throws {
        let pts = objectCloud(a: 80, b: 40, h: 12, noise: 1.5)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.812, 0), right: V3(1, 0, 0)))
        let pic = objectPicture(a: 80, b: 40, h: 12, height: 0.35, offset: (0.04, 0.03))
        let sharp = try XCTUnwrap(refineOutline(fit, gray: pic.gray, scale: 2, intrinsics: pic.K, pose: pic.pose))
        XCTAssertTrue(sharp.sharpened)
        XCTAssertEqual(sharp.width, 80, accuracy: 1)
        XCTAssertEqual(sharp.length, 40, accuracy: 1)
        let want = Double.pi * 40 * 20
        XCTAssertLessThan(abs(loopArea(sharp.outline) - want) / want, 0.05)
    }
}
