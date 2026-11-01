import XCTest
@testable import HoleKit

// The LiDAR measurements on clouds closer to an iPhone's: jittered sampling, noise mostly along the
// (near vertical) rays, side faces seen only where they face the camera, flying pixels at the
// outline, walls hidden from view, a wall right behind a pipe.

/// Normal-distributed noise from the repeatable `Noise`.
private func gaussian(_ r: inout Noise) -> Double {
    (-2 * log(max(1e-12, r.next()))).squareRoot() * cos(2 * .pi * r.next())
}

/// A block w × l × h mm on a table (world y up, table at 0.8 m; plane x → world x, plane y → world z),
/// turned `turn`° about up. The camera is above (0, −80) mm, 350 mm up. Points on a jittered grid,
/// sides only where they face the camera, and `ramp` flying pixels per edge sample between the top
/// edge and the table on the sides facing away.
private func blockCloud(w: Double, l: Double, h: Double, turn: Double, spacing: Double = 2, extent: Double = 250,
                        noiseUp: Double = 1, noiseSide: Double = 1, ramp: Int = 0, seed: UInt64 = 5) -> [V3] {
    var r = Noise(state: seed)
    let c = cos(turn * .pi / 180), s = sin(turn * .pi / 180)
    var pts: [V3] = []
    func add(_ x: Double, _ y: Double, _ z: Double) {
        let nx = gaussian(&r) * noiseSide, ny = gaussian(&r) * noiseSide, nz = gaussian(&r) * noiseUp
        pts.append(V3((x + nx) / 1000, 0.8 + (z + nz) / 1000, (y + ny) / 1000))
    }
    func inside(_ x: Double, _ y: Double) -> Bool {
        let lx = x * c + y * s, ly = -x * s + y * c
        return abs(lx) <= w / 2 && abs(ly) <= l / 2
    }
    var x = -extent
    while x <= extent {
        var y = -extent
        while y <= extent {
            let jx = x + (r.next() - 0.5) * spacing, jy = y + (r.next() - 0.5) * spacing
            add(jx, jy, inside(jx, jy) ? h : 0)
            y += spacing
        }
        x += spacing
    }
    let cam = (x: 0.0, y: -80.0), camH = 350.0
    var edge: [(x: Double, y: Double, nx: Double, ny: Double)] = []
    var t = -w / 2
    while t < w / 2 {
        edge.append((x: t, y: -l / 2, nx: 0, ny: -1))
        edge.append((x: t, y: l / 2, nx: 0, ny: 1))
        t += 1.5
    }
    t = -l / 2
    while t < l / 2 {
        edge.append((x: -w / 2, y: t, nx: -1, ny: 0))
        edge.append((x: w / 2, y: t, nx: 1, ny: 0))
        t += 1.5
    }
    for e in edge {
        let px = e.x * c - e.y * s, py = e.x * s + e.y * c
        let nx = e.nx * c - e.ny * s, ny = e.nx * s + e.ny * c
        if nx * (cam.x - px) + ny * (cam.y - py) > 0 {
            var z = 0.0
            while z < h {
                add(px, py, z)
                z += 2
            }
        } else if ramp > 0 {
            // Along the ray past the top edge, down to the table.
            let dx = px - cam.x, dy = py - cam.y
            for k in 1...ramp {
                let zz = h * (1 - Double(k) / Double(ramp + 1))
                let f = (camH - zz) / (camH - h)
                add(cam.x + dx * f, cam.y + dy * f, zz)
            }
        }
    }
    return pts
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

/// The visible part (±`arc`°) of a pipe and, when `wall` is given, a wall that far behind its
/// axis (m), seen beside the pipe. As BoxTests' pipeCloud otherwise.
private func pipeAndWall(d: Double, turn: Double, tilt: Double, arc: Double, noise: Double, wall: Double?) -> (pts: [V3], aim: V3, axis: V3) {
    var r = Noise(state: 11)
    var pts: [V3] = []
    let tr = turn * .pi / 180, k = tilt * .pi / 180
    let axis = V3(cos(tr) * cos(k), sin(k), sin(tr) * cos(k))
    let side = vnormalized(V3(-axis.z, 0, axis.x))
    let upish = vcross(axis, side)
    let c = V3(0.02, 0.5, -0.3)
    let R = d / 2000
    let a0 = arc * .pi / 180
    var s = -0.08
    while s <= 0.08 {
        var a = -a0
        while a <= a0 {
            let p = c + axis * s + upish * (cos(a) * R) + side * (sin(a) * R)
            pts.append(p + V3(gaussian(&r), gaussian(&r), gaussian(&r)) * (noise / 1000))
            a += 0.04
        }
        s += 0.0015
    }
    if let wall {
        for x in stride(from: -0.1, through: 0.1, by: 0.002) {
            for z in stride(from: -0.1, through: 0.1, by: 0.002) where abs(z) > R {
                pts.append(c - upish * wall + axis * x + side * z + upish * (gaussian(&r) * noise / 1000))
            }
        }
    }
    return (pts, c + upish * R, axis)
}

/// The camera picture (480 × 360, half of 960 × 720) of a w × l × h block on the table, looking down
/// from 0.35 m: `shade(x, y)` is the block's brightness at a point of it (mm, its own frame).
private func blockPicture(w: Double, l: Double, h: Double, table: UInt8, shade: (Double, Double) -> UInt8) -> (gray: GrayImage, K: Intrinsics, pose: CameraPose) {
    let W = 480, Hh = 360
    let scale = 2.0
    let K = Intrinsics(fx: 700, fy: 700, cx: Double(W) * scale / 2, cy: Double(Hh) * scale / 2)
    let pose = CameraPose(x: V3(1, 0, 0), y: V3(0, 0, -1), z: V3(0, 1, 0), position: V3(0.04, 0.8 + 0.35, 0.03))
    let hx = w / 2, hy = l / 2
    func inside(_ x: Double, _ y: Double) -> Bool { abs(x) <= hx && abs(y) <= hy }
    var px = [UInt8](repeating: 0, count: W * Hh)
    let SS = 2
    for j in 0..<Hh {
        for i in 0..<W {
            var sum = 0
            for sj in 0..<SS {
                for si in 0..<SS {
                    let u = (Double(i) + (Double(si) + 0.5) / Double(SS)) * scale
                    let v = (Double(j) + (Double(sj) + 0.5) / Double(SS)) * scale
                    let rx = (u - K.cx) / K.fx, rz = (v - K.cy) / K.fy
                    // Down the ray from the top level to the table: the first point inside the block.
                    var value = Int(table)
                    let t0 = pose.position.y - 0.8 - h / 1000, t1 = pose.position.y - 0.8
                    let xa = (pose.position.x + rx * t0) * 1000, xb = (pose.position.x + rx * t1) * 1000
                    let ya = (pose.position.z + rz * t0) * 1000, yb = (pose.position.z + rz * t1) * 1000
                    let missX: Bool = max(xa, xb) < -hx || min(xa, xb) > hx
                    let missY: Bool = max(ya, yb) < -hy || min(ya, yb) > hy
                    var f = missX || missY ? 2.0 : 0.0
                    while f <= 1.0001 {
                        let yy = 0.8 + h / 1000 * (1 - f)
                        let tt = pose.position.y - yy
                        let x = (pose.position.x + rx * tt) * 1000, y = (pose.position.z + rz * tt) * 1000
                        if inside(x, y) {
                            value = Int(shade(x, y))
                            break
                        }
                        f += 0.1
                    }
                    sum += value
                }
            }
            px[j * W + i] = UInt8(sum / (SS * SS))
        }
    }
    return (GrayImage(width: W, height: Hh, pixels: px), K, pose)
}

/// A thin thing on the table seen from 0.35 m (full picture 1920 × 1440, mask 480 × 360): its
/// foreground mask (top or bottom face under the pixel's centre), the LiDAR cloud round it and the
/// cross-hair on it. `shape(x, y)`: inside, in world mm on the table (x → world x, y → world z).
private func thinScene(h: Double, noise: Double, shape: (Double, Double) -> Bool) -> (mask: [UInt8], K: Intrinsics, pose: CameraPose, points: [V3], aim: P2, aimWorld: V3) {
    let K = Intrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720)
    let pose = CameraPose(x: V3(1, 0, 0), y: V3(0, 0, -1), z: V3(0, 1, 0), position: V3(0.02, 0.8 + 0.35, 0.03))
    let MW = 480, MH = 360, S = 4.0
    var mask = [UInt8](repeating: 0, count: MW * MH)
    for j in 0..<MH {
        for i in 0..<MW {
            let rx = ((Double(i) + 0.5) * S - K.cx) / K.fx, rz = ((Double(j) + 0.5) * S - K.cy) / K.fy
            for level in [0.8, 0.8 + h / 1000] {
                let tt = pose.position.y - level
                if shape((pose.position.x + rx * tt) * 1000, (pose.position.z + rz * tt) * 1000) { mask[j * MW + i] = 255 }
            }
        }
    }
    var r = Noise(state: 21)
    var points: [V3] = []
    for x in stride(from: -200.0, to: 200, by: 2) {
        for y in stride(from: -200.0, to: 200, by: 2) {
            let z = shape(x, y) ? h : 0
            points.append(V3(x / 1000, 0.8 + (z + gaussian(&r) * noise) / 1000, y / 1000))
        }
    }
    let aimWorld = V3(0, 0.8 + h / 1000, 0)
    let aimPx = project(aimWorld, intrinsics: K, pose: pose)! / S
    return (mask, K, pose, points, aimPx, aimWorld)
}

final class RealisticSpaceTests: XCTestCase {
    // MARK: Something on a table

    func testObjectSizeDoesNotTurnWithThePhone() throws {
        // Dense points (as several frames together), so what is left is the method, not the sampling.
        var sizes: [(Double, Double)] = []
        for turn in [0.0, 10, 30] {
            let pts = blockCloud(w: 100, l: 50, h: 20, turn: turn, spacing: 1, extent: 150)
            let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.82, 0), right: V3(1, 0, 0)))
            XCTAssertEqual(fit.width, 100, accuracy: 3)
            XCTAssertEqual(fit.length, 50, accuracy: 3)
            // The frame follows the thing: x along its long side.
            let long = V3(cos(turn * .pi / 180), 0, sin(turn * .pi / 180))
            XCTAssertGreaterThan(abs(vdot(fit.xAxis, long)), 0.99)
            sizes.append((fit.width, fit.length))
        }
        for s in sizes.dropFirst() {
            XCTAssertEqual(s.0, sizes[0].0, accuracy: 1)
            XCTAssertEqual(s.1, sizes[0].1, accuracy: 1)
        }
    }

    func testObjectWithNoisyDepth() throws {
        // 4 mm noise along the rays (the depth), 1 mm across.
        let pts = blockCloud(w: 100, l: 50, h: 30, turn: 15, noiseUp: 4, noiseSide: 1)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.83, 0), right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 100, accuracy: 4)
        XCTAssertEqual(fit.length, 50, accuracy: 4)
        // The height comes out high by about the noise (it is near the top of the points).
        XCTAssertEqual(fit.height, 32, accuracy: 6)
    }

    func testFlyingPixelsDoNotGrowTheFootprintMuch() throws {
        let pts = blockCloud(w: 100, l: 50, h: 20, turn: 10, ramp: 2)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.82, 0), right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 100, accuracy: 5)
        XCTAssertEqual(fit.length, 50, accuracy: 5)
    }

    func testFiveMillimetreThing() throws {
        let pts = blockCloud(w: 100, l: 50, h: 5, turn: 20)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.805, 0), right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 100, accuracy: 3.5)
        XCTAssertEqual(fit.length, 50, accuracy: 3.5)
        XCTAssertEqual(fit.height, 5, accuracy: 2.5)
    }

    func testSharperEdgeTakesTheStepNearestTheLidarEdge() throws {
        let pts = blockCloud(w: 80, l: 40, h: 12, turn: 0)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.812, 0), right: V3(1, 0, 0)))
        // A bright band printed 3 mm inside the edge steps harder than the edge itself.
        let pic = blockPicture(w: 80, l: 40, h: 12, table: 170) { x, y in
            let inner = min(40 - abs(x), 20 - abs(y))
            return inner > 3 && inner < 4.5 ? 235 : 40
        }
        let sharp = try XCTUnwrap(refineOutline(fit, gray: pic.gray, scale: 2, intrinsics: pic.K, pose: pic.pose))
        XCTAssertEqual(sharp.width, 80, accuracy: 1.5)
        XCTAssertEqual(sharp.length, 40, accuracy: 1.5)
    }

    func testSharperEdgeGivesUpOnMixedSteps() throws {
        let pts = blockCloud(w: 80, l: 40, h: 12, turn: 0)
        let fit = try XCTUnwrap(fitObject(pts, aim: V3(0.01, 0.812, 0), right: V3(1, 0, 0)))
        // Half darker, half lighter than the table: no one kind of step all round.
        let pic = blockPicture(w: 80, l: 40, h: 12, table: 140) { x, _ in x < 0 ? 30 : 250 }
        XCTAssertNil(refineOutline(fit, gray: pic.gray, scale: 2, intrinsics: pic.K, pose: pic.pose))
    }

    // MARK: Thin things from the picture's mask

    func testRulerFromTheMask() throws {
        let c = cos(20 * Double.pi / 180), s = sin(20 * Double.pi / 180)
        let scene = thinScene(h: 3, noise: 1.5) { x, y in abs(x * c + y * s) <= 75 && abs(-x * s + y * c) <= 12.5 }
        let fit = try XCTUnwrap(objectFromMask(scene.mask, width: 480, height: 360, aim: scene.aim, maskToImage: 4,
                                               intrinsics: scene.K, pose: scene.pose, points: scene.points,
                                               aimWorld: scene.aimWorld, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 150, accuracy: 3)
        XCTAssertEqual(fit.length, 25, accuracy: 2.5)
        XCTAssertGreaterThanOrEqual(fit.height, 1)
        XCTAssertEqual(fit.height, 3, accuracy: 2)
        XCTAssertGreaterThan(abs(vdot(fit.xAxis, V3(c, 0, s))), 0.99)
        XCTAssertEqual(fit.centre.x, 0, accuracy: 0.003)
        XCTAssertEqual(fit.centre.z, 0, accuracy: 0.003)
        XCTAssertEqual(fit.outline.count, fit.outlineWorld.count)
    }

    func testSpannerFromTheMask() throws {
        // A 5 mm thick bar 120 × 14 with a round head (r 15) on its end: 135 × 30 over all.
        let scene = thinScene(h: 5, noise: 1.5) { x, y in
            (abs(x) <= 60 && abs(y) <= 7) || (x - 60) * (x - 60) + y * y <= 15 * 15
        }
        let fit = try XCTUnwrap(objectFromMask(scene.mask, width: 480, height: 360, aim: scene.aim, maskToImage: 4,
                                               intrinsics: scene.K, pose: scene.pose, points: scene.points,
                                               aimWorld: scene.aimWorld, right: V3(1, 0, 0)))
        XCTAssertEqual(fit.width, 135, accuracy: 2.5)
        XCTAssertEqual(fit.length, 30, accuracy: 2)
        XCTAssertEqual(fit.height, 5, accuracy: 2)
        // Bar plus head, less the piece of the bar inside the head.
        let overlap = 7 * (225.0 - 49).squareRoot() + 225 * asin(7.0 / 15)
        let want = 120.0 * 14 + Double.pi * 225 - overlap
        XCTAssertLessThan(abs(loopArea(fit.outline) - want) / want, 0.12)
    }

    func testMaskWithNothingUnderTheCrossHair() {
        let scene = thinScene(h: 3, noise: 1) { x, y in abs(x - 150) <= 10 && abs(y) <= 10 }
        XCTAssertNil(objectFromMask(scene.mask, width: 480, height: 360, aim: P2(240, 180), maskToImage: 4,
                                    intrinsics: scene.K, pose: scene.pose, points: scene.points, aimWorld: V3(0, 0.8, 0)))
        // A mask that is everything (the table) is no thing either.
        let all = [UInt8](repeating: 255, count: 480 * 360)
        XCTAssertNil(objectFromMask(all, width: 480, height: 360, aim: P2(240, 180), maskToImage: 4,
                                    intrinsics: scene.K, pose: scene.pose, points: scene.points, aimWorld: V3(0, 0.8, 0)))
    }

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

    // MARK: A pipe

    func testPipeArcWithAWallBehind() throws {
        // Only ±55° of the round seen (the flanks are lost), a wall 2 cm behind the axis.
        let (pts, aim, axis) = pipeAndWall(d: 32, turn: 30, tilt: 0, arc: 55, noise: 1.5, wall: 0.02)
        let fit = try XCTUnwrap(fitCylinder(pts, aim: aim))
        XCTAssertEqual(fit.diameter, 32, accuracy: 1.5)
        XCTAssertGreaterThan(abs(vdot(fit.axis, axis)), 0.995)
        XCTAssertEqual(fit.coverage, 115, accuracy: 30)
    }

    func testPipeSeenRoundItsSideCoversHalf() throws {
        let (pts, aim, _) = pipeAndWall(d: 40, turn: -20, tilt: 10, arc: 85, noise: 1, wall: nil)
        let fit = try XCTUnwrap(fitCylinder(pts, aim: aim))
        XCTAssertEqual(fit.diameter, 40, accuracy: 1.5)
        XCTAssertEqual(fit.coverage, 170, accuracy: 25)
    }

    func testThinRodIsRefused() {
        let (pts, aim, _) = pipeAndWall(d: 8, turn: 20, tilt: 0, arc: 80, noise: 1, wall: nil)
        XCTAssertNil(fitCylinder(pts, aim: aim))
    }

    func testPipeFitIsQuick() throws {
        let (pts, aim, _) = pipeAndWall(d: 50, turn: 40, tilt: 5, arc: 70, noise: 1.5, wall: 0.04)
        let start = Date()
        let fit = try XCTUnwrap(fitCylinder(pts, aim: aim, reach: 0.06))
        let took = Date().timeIntervalSince(start)
        XCTAssertEqual(fit.diameter, 50, accuracy: 2)
        // ~1500 points; well under 50 ms in a release build, this allows for a debug build on CI.
        XCTAssertLessThan(took, 1.0)
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
